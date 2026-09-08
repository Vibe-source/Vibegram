defmodule Vibe.AI.Tools.ConnectedApp do
  @moduledoc false

  require Logger

  alias Vibe.Agent, as: AgentSchema
  alias Vibe.AgentIntegration
  alias Vibe.Agents

  @default_timeout_ms 10_000
  @max_timeout_ms 30_000

  def invoke(input, agent_id, requester_user_id) do
    action = normalize_identifier(input["action"])
    params = normalize_params(input["params"])

    with {:ok, %AgentSchema{} = agent} <- resolve_owned_agent(agent_id, requester_user_id),
         true <- is_binary(action) || {:error, :missing_action},
         {:ok, selection} <- resolve_connected_app(agent, input, action),
         :ok <- ensure_action_allowed(selection, action),
         {:ok, secret} <- Agents.integration_secret(selection.integration),
         {:ok, _uri} <- Vibe.Net.SafeURL.validate(selection.endpoint_url),
         {:ok, result} <-
           dispatch_action(selection, agent, requester_user_id, action, params, secret) do
      result
    else
      {:error, reason} -> error_payload(reason)
      false -> error_payload(:missing_action)
    end
  end

  def prompt_guidance(%AgentSchema{} = agent) do
    integrations =
      list_connected_apps(agent)
      |> Enum.filter(fn selection -> selection.allowed_actions != [] end)

    case integrations do
      [] ->
        nil

      items ->
        joined =
          Enum.map_join(items, "\n", &integration_prompt_guidance/1)

        """
        Connected app access is configured for this agent.
        Use the `call_connected_app` tool for website, business, admin, or app-side questions and actions instead of guessing.
        Preserve explicit user filters and timeframes in `params`; do not replace a requested query window with an inbox or report delivery cadence.
        Only use the configured actions and parameter guidance below:
        #{joined}
        If the user asks for connected app data and none of these actions fit, say the connected app has not exposed that action yet.
        """
    end
  end

  defp dispatch_action(selection, agent, requester_user_id, action, params, secret) do
    body = %{
      "action" => action,
      "params" => Map.merge(params, selection.static_params),
      "context" => %{
        "agent_id" => agent.id,
        "agent_name" => agent.display_name,
        "agent_user_id" => agent.agent_user_id,
        "owner_user_id" => agent.owner_user_id,
        "requester_user_id" => requester_user_id,
        "integration_id" => selection.integration.id,
        "integration_name" => selection.integration.name,
        "source_type" => selection.integration.source_type,
        "requested_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"x-vibe-integration-secret", secret},
      {"x-vibe-agent-id", agent.id},
      {"x-vibe-integration-id", selection.integration.id}
    ]

    request = Finch.build(:post, selection.endpoint_url, headers, Jason.encode!(body))

    case Finch.request(request, Vibe.Finch, receive_timeout: selection.timeout_ms) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        decoded = decode_response_body(response_body)

        {:ok,
         %{
           "ok" => true,
           "action" => action,
           "integration_id" => selection.integration.id,
           "integration_name" => selection.integration.name,
           "source_type" => selection.integration.source_type,
           "data" => decoded,
           "summary" => response_summary(decoded)
         }}

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        Logger.warning(
          "[ConnectedApp] non-success response integration=#{selection.integration.id} status=#{status}"
        )

        {:error, {:remote_error, status, summarize_body(response_body)}}

      {:error, reason} ->
        Logger.warning(
          "[ConnectedApp] request failed integration=#{selection.integration.id} reason=#{inspect(reason)}"
        )

        {:error, {:request_failed, reason}}
    end
  end

  defp resolve_owned_agent(agent_id, requester_user_id)
       when is_binary(agent_id) and is_binary(requester_user_id) do
    case Agents.get_agent(agent_id, requester_user_id) do
      %AgentSchema{} = agent -> {:ok, agent}
      nil -> {:error, :agent_not_available}
    end
  end

  defp resolve_owned_agent(_agent_id, _requester_user_id), do: {:error, :owner_lookup_required}

  defp resolve_connected_app(agent, input, action) do
    requested_id = normalize_string(input["integration_id"] || input["integrationId"])
    requested_name = normalize_identifier(input["integration_name"] || input["integrationName"])
    requested_source_type = normalize_identifier(input["source_type"] || input["sourceType"])

    candidates =
      list_connected_apps(agent)
      |> maybe_filter_candidates(requested_id, requested_name, requested_source_type)
      |> maybe_filter_by_action(action)

    case candidates do
      [] ->
        case list_connected_apps(agent) do
          [] ->
            {:error, :no_connected_app}

          available ->
            {:error, {:integration_not_found, Enum.map(available, & &1.integration.name)}}
        end

      [selection] ->
        {:ok, selection}

      many ->
        {:error, {:multiple_connected_apps, Enum.map(many, & &1.integration.name)}}
    end
  end

  defp maybe_filter_candidates(candidates, nil, nil, nil), do: candidates

  defp maybe_filter_candidates(candidates, requested_id, requested_name, requested_source_type) do
    Enum.filter(candidates, fn selection ->
      integration = selection.integration

      cond do
        is_binary(requested_id) ->
          integration.id == requested_id

        is_binary(requested_name) ->
          String.downcase(integration.name || "") == requested_name

        is_binary(requested_source_type) ->
          String.downcase(integration.source_type || "") == requested_source_type

        true ->
          true
      end
    end)
  end

  defp maybe_filter_by_action(candidates, nil), do: candidates

  defp maybe_filter_by_action(candidates, action) do
    filtered =
      Enum.filter(candidates, fn selection ->
        action in selection.allowed_actions
      end)

    if filtered == [], do: candidates, else: filtered
  end

  defp ensure_action_allowed(selection, action) do
    if action in selection.allowed_actions do
      :ok
    else
      {:error, {:action_not_allowed, selection.allowed_actions}}
    end
  end

  defp list_connected_apps(%AgentSchema{} = agent) do
    agent
    |> Agents.list_integrations()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(fn integration ->
      case connected_app_config(integration) do
        nil -> nil
        config -> Map.put(config, :integration, integration)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp connected_app_config(%AgentIntegration{} = integration) do
    config =
      get_nested_map(integration.routing_rules || %{}, ["connected_app"]) ||
        get_nested_map(integration.routing_rules || %{}, ["connectedApp"])

    endpoint_url =
      normalize_endpoint_url(map_get(config, "endpoint_url") || map_get(config, "endpointUrl"))

    action_specs =
      normalize_action_specs(map_get(config, "action_specs") || map_get(config, "actionSpecs"))

    allowed_actions =
      normalize_string_list(
        map_get(config, "allowed_actions") || map_get(config, "allowedActions") ||
          map_get(config, "actions")
      )
      |> Kernel.++(Map.keys(action_specs))
      |> Enum.uniq()

    static_params =
      normalize_params(map_get(config, "static_params") || map_get(config, "staticParams"))

    timeout_ms = normalize_timeout(map_get(config, "timeout_ms") || map_get(config, "timeoutMs"))

    if is_binary(endpoint_url) and allowed_actions != [] do
      %{
        endpoint_url: endpoint_url,
        allowed_actions: allowed_actions,
        action_specs: Map.take(action_specs, allowed_actions),
        static_params: static_params,
        timeout_ms: timeout_ms
      }
    end
  end

  defp integration_prompt_guidance(selection) do
    actions =
      Enum.map_join(selection.allowed_actions, "\n", fn action ->
        case Map.get(selection.action_specs, action) do
          nil ->
            "  - #{action}"

          spec ->
            description =
              case spec.description do
                nil -> ""
                value -> ": #{value}"
              end

            params =
              case spec.params do
                params when map_size(params) > 0 ->
                  formatted =
                    params
                    |> Enum.sort_by(fn {name, _hint} -> name end)
                    |> Enum.map_join("; ", fn {name, hint} -> "#{name}=#{hint}" end)

                  " Params: #{formatted}."

                _ ->
                  ""
              end

            "  - #{action}#{description}#{params}"
        end
      end)

    "- #{selection.integration.name} (#{selection.integration.source_type}):\n#{actions}"
  end

  defp get_nested_map(map, [key]) when is_map(map) do
    case map_get(map, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp get_nested_map(_map, _keys), do: nil

  defp map_get(map, key) when is_map(map) do
    variants = [key, camelize_lower(key)]

    Enum.find_value(variants, fn variant ->
      Map.get(map, variant) ||
        case safe_existing_atom(variant) do
          nil -> nil
          atom_key -> Map.get(map, atom_key)
        end
    end)
  end

  defp map_get(_map, _key), do: nil

  defp normalize_endpoint_url(value) do
    with trimmed when is_binary(trimmed) <- normalize_string(value),
         %URI{scheme: scheme, host: host} <- URI.parse(trimmed),
         true <- allowed_scheme_host?(scheme, host, trimmed) do
      trimmed
    else
      _ -> nil
    end
  end

  defp allowed_scheme_host?("https", host, _url) when is_binary(host) and host != "", do: true
  defp allowed_scheme_host?("http", "localhost", _url), do: true
  defp allowed_scheme_host?("http", "127.0.0.1", _url), do: true
  defp allowed_scheme_host?("http", "::1", _url), do: true
  defp allowed_scheme_host?(_, _, _), do: false

  defp normalize_params(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, item} -> {to_string(key), item} end)
  end

  defp normalize_params(_), do: %{}

  defp normalize_timeout(value) when is_integer(value) do
    value
    |> max(1_000)
    |> min(@max_timeout_ms)
  end

  defp normalize_timeout(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> normalize_timeout(parsed)
      :error -> @default_timeout_ms
    end
  end

  defp normalize_timeout(_), do: @default_timeout_ms

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_), do: nil

  defp normalize_string_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&normalize_identifier/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_action_specs(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {action, raw_spec}, specs ->
      case normalize_action_spec(action, raw_spec) do
        nil -> specs
        {id, spec} -> Map.put(specs, id, spec)
      end
    end)
  end

  defp normalize_action_specs(value) when is_list(value) do
    Enum.reduce(value, %{}, fn
      raw_spec, specs when is_map(raw_spec) ->
        action =
          map_get(raw_spec, "id") || map_get(raw_spec, "action") || map_get(raw_spec, "name")

        case normalize_action_spec(action, raw_spec) do
          nil -> specs
          {id, spec} -> Map.put(specs, id, spec)
        end

      _, specs ->
        specs
    end)
  end

  defp normalize_action_specs(_), do: %{}

  defp normalize_action_spec(action, raw_spec) do
    with id when is_binary(id) <- normalize_identifier(action) do
      description =
        case raw_spec do
          value when is_binary(value) -> normalize_prompt_hint(value, 320)
          value when is_map(value) -> normalize_prompt_hint(map_get(value, "description"), 320)
          _ -> nil
        end

      params =
        case raw_spec do
          value when is_map(value) ->
            normalize_action_params(map_get(value, "params") || map_get(value, "parameters"))

          _ ->
            %{}
        end

      {id, %{description: description, params: params}}
    else
      _ -> nil
    end
  end

  defp normalize_action_params(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {name, hint}, params ->
      with normalized_name when is_binary(normalized_name) <-
             normalize_prompt_hint(to_string(name), 80),
           normalized_hint when is_binary(normalized_hint) <-
             normalize_prompt_hint(hint, 240) do
        Map.put(params, normalized_name, normalized_hint)
      else
        _ -> params
      end
    end)
    |> Enum.take(12)
    |> Map.new()
  end

  defp normalize_action_params(_), do: %{}

  defp normalize_prompt_hint(value, max_length) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max_length)
    end
  end

  defp normalize_prompt_hint(_, _), do: nil

  defp normalize_identifier(value) when is_binary(value) do
    case normalize_string(value) do
      nil -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_identifier(_), do: nil

  defp camelize_lower(value) when is_binary(value) do
    case Macro.camelize(value) do
      "" -> value
      <<first::utf8, rest::binary>> -> String.downcase(<<first::utf8>>) <> rest
    end
  end

  defp safe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp decode_response_body(""), do: %{}

  defp decode_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"raw" => body}
    end
  end

  defp decode_response_body(other), do: other

  defp response_summary(%{"summary" => summary}) when is_binary(summary) and summary != "",
    do: summary

  defp response_summary(%{"message" => message}) when is_binary(message) and message != "",
    do: message

  defp response_summary(%{"ok" => ok, "count" => count}) when is_boolean(ok) and is_number(count),
    do: "Result count: #{count}"

  defp response_summary(_), do: nil

  defp summarize_body(body) when is_binary(body) do
    body
    |> String.trim()
    |> case do
      "" -> "Empty response body"
      trimmed -> String.slice(trimmed, 0, 300)
    end
  end

  defp summarize_body(other), do: inspect(other)

  defp error_payload(:missing_action) do
    %{"ok" => false, "error" => "Connected app action is required."}
  end

  defp error_payload(:no_connected_app) do
    %{"ok" => false, "error" => "No connected app integration is configured for this agent."}
  end

  defp error_payload(:agent_not_available) do
    %{"ok" => false, "error" => "This connected app is not available in the current chat."}
  end

  defp error_payload(:owner_lookup_required) do
    %{"ok" => false, "error" => "Owner lookup is required for connected app actions."}
  end

  defp error_payload({:integration_not_found, names}) do
    %{
      "ok" => false,
      "error" => "Connected app integration not found.",
      "available_integrations" => names
    }
  end

  defp error_payload({:multiple_connected_apps, names}) do
    %{
      "ok" => false,
      "error" =>
        "Multiple connected app integrations match. Specify integration_name or integration_id.",
      "available_integrations" => names
    }
  end

  defp error_payload({:action_not_allowed, actions}) do
    %{
      "ok" => false,
      "error" => "That connected app action is not allowed for this integration.",
      "available_actions" => actions
    }
  end

  defp error_payload({:remote_error, status, body}) do
    %{
      "ok" => false,
      "error" => "Connected app request failed with status #{status}.",
      "status" => status,
      "details" => body
    }
  end

  defp error_payload({:request_failed, reason}) do
    %{
      "ok" => false,
      "error" => "Connected app request failed.",
      "details" => inspect(reason)
    }
  end

  defp error_payload(reason)
       when reason in [:invalid_scheme, :missing_host, :host_not_found, :blocked_address, :invalid_url] do
    %{"ok" => false, "error" => "The connected app endpoint is not a publicly routable URL."}
  end

  defp error_payload(reason) do
    %{"ok" => false, "error" => inspect(reason)}
  end
end
