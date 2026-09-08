defmodule VibeAgents.LLM.Loop do
  @moduledoc """
  Ported from `server/lib/vibe/ai/agent_runtime.ex` (Vibe.AI.AgentRuntime): Claude primary,
  OpenAI Responses fallback, same `Config` struct, same `run/2` semantics, same callback
  event shapes (`:text`, `:thinking`, `:progress`, `:tool_result`). No core dependency — the
  model registry lookups are replaced by a small static table (`@thinking_levels`) below.
  """

  require Logger

  @claude_api "https://api.anthropic.com/v1/messages"
  @openai_responses_api "https://api.openai.com/v1/responses"
  @default_openai_fallback_model "gpt-5.6-luna"
  @default_openai_reasoning_effort "medium"
  @adaptive_claude_models ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-5"]

  # Standalone substitute for Vibe.AI.ModelRegistry.thinking_levels/2.
  @thinking_levels %{
    {"anthropic", "claude-fable-5"} => ["low", "medium", "high", "xhigh", "max"],
    {"anthropic", "claude-opus-4-8"} => ["low", "medium", "high", "xhigh", "max"],
    {"anthropic", "claude-sonnet-5"} => ["low", "medium", "high", "xhigh"],
    {"anthropic", "claude-haiku-4-5"} => ["medium"],
    {"openai", "gpt-5.6-sol"} => ["low", "medium", "high", "xhigh", "max"],
    {"openai", "gpt-5.6-terra"} => ["low", "medium", "high"],
    {"openai", "gpt-5.6-luna"} => ["low", "medium", "high"]
  }

  defmodule Config do
    @enforce_keys [:model, :system_prompt, :tools, :execute_tools]
    defstruct provider: "anthropic",
              model: nil,
              thinking_level: "medium",
              max_tokens: 1600,
              max_depth: 3,
              system_prompt: nil,
              tools: [],
              execute_tools: nil,
              state: %{},
              callback: nil,
              stream_text?: true,
              claude_api_url: "https://api.anthropic.com/v1/messages",
              openai_responses_url: "https://api.openai.com/v1/responses",
              openai_fallback_model: "gpt-5.6-luna",
              openai_reasoning_effort: "medium",
              missing_api_key_error: "ANTHROPIC_API_KEY not configured",
              depth_error: "Max tool depth reached",
              request_label: "VibeAgents.LLM.Loop"
  end

  def run(messages, opts) when is_list(messages) do
    config = opts |> normalize_config() |> apply_openai_environment()

    provider_state = %{
      selected: if(config.provider in [:openai, "openai"], do: :openai, else: nil),
      claude_api_key: System.get_env("ANTHROPIC_API_KEY") || System.get_env("CLAUDE_API_KEY"),
      openai_api_key: System.get_env("OPENAI_API_KEY")
    }

    case provider_state do
      %{selected: :openai, openai_api_key: nil} ->
        {:error, "OPENAI_API_KEY not configured for selected OpenAI agent model"}

      %{claude_api_key: nil, openai_api_key: nil} ->
        {:error, "#{config.missing_api_key_error}; OPENAI_API_KEY not configured"}

      _ ->
        do_run(messages, config, provider_state, 0, "")
    end
  end

  defp do_run(
         _messages,
         %Config{max_depth: max_depth} = config,
         _provider_state,
         depth,
         accumulated_text
       )
       when depth > max_depth do
    Logger.warning("[#{config.request_label}] Max tool depth #{max_depth} reached")

    case String.trim(to_string(accumulated_text)) do
      "" -> {:error, config.depth_error}
      _text -> {:ok, accumulated_text, Map.put(config.state, :terminal_status, "depth_exhausted")}
    end
  end

  defp do_run(messages, %Config{} = config, provider_state, depth, accumulated_text) do
    {result, next_provider_state} = request_completion_stream(messages, config, provider_state)

    case result do
      {:ok, reply} ->
        {:ok, join_beats(accumulated_text, reply), served_by(config, next_provider_state)}

      {:tool_use, tool_calls, partial_response, partial_text} ->
        callback = config.callback || fn _event -> :ok end
        state_with_snapshot = Map.put(config.state, :current_messages, messages)
        {tool_results, next_state} = config.execute_tools.(tool_calls, state_with_snapshot, callback)

        if Map.get(next_state, :terminal_status) == "waiting_for_user" do
          {:ok, accumulated_text <> partial_text, served_by(%{config | state: next_state}, next_provider_state)}
        else
          do_run(
            messages ++
              [
                %{role: "assistant", content: partial_response},
                %{role: "user", content: tool_results}
              ],
            %{config | state: next_state},
            next_provider_state,
            depth + 1,
            join_beats(accumulated_text, partial_text)
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp served_by(%Config{} = config, provider_state) do
    {provider, model} =
      case Map.get(provider_state, :selected) do
        :openai -> {"openai", Map.get(provider_state, :served_model) || openai_model(config)}
        _ -> {"anthropic", config.model}
      end

    config.state
    |> Map.put(:served_provider, provider)
    |> Map.put(:served_model, model)
    |> Map.put(:requested_model, config.model)
    |> Map.put(:substituted?, model != config.model)
  end

  defp request_completion_stream(messages, %Config{} = config, %{selected: :openai} = state) do
    {request_openai_completion_stream(messages, config, state.openai_api_key),
     Map.put(state, :served_model, openai_model(config))}
  end

  defp request_completion_stream(messages, %Config{} = config, provider_state) do
    cond do
      is_nil(provider_state.claude_api_key) ->
        fallback_to_openai(messages, config, provider_state, "Claude API key is not configured")

      true ->
        case request_claude_completion_stream(messages, config, provider_state.claude_api_key) do
          {:error, reason, %{emitted_text?: false}} ->
            fallback_to_openai(messages, config, provider_state, reason)

          {:error, reason, %{emitted_text?: true}} ->
            Logger.error(
              "[#{config.request_label}] Claude failed after streaming visible text; " <>
                "OpenAI fallback suppressed to avoid mixing two responses"
            )

            {{:error, reason}, %{provider_state | selected: :claude}}

          result ->
            {result, %{provider_state | selected: :claude}}
        end
    end
  end

  defp fallback_to_openai(messages, %Config{} = config, provider_state, claude_reason) do
    if is_nil(provider_state.openai_api_key) do
      Logger.error(
        "[#{config.request_label}] Claude request failed and OPENAI_API_KEY is not configured: " <>
          inspect(claude_reason)
      )

      {{:error, claude_reason}, provider_state}
    else
      config = preserve_effort_across_fallback(config)

      Logger.warning(
        "[#{config.request_label}] Claude unavailable; falling back to " <>
          "#{config.openai_fallback_model} at effort=#{config.openai_reasoning_effort}: " <>
          inspect(claude_reason)
      )

      result = request_openai_completion_stream(messages, config, provider_state.openai_api_key)

      {result,
       provider_state
       |> Map.put(:selected, :openai)
       |> Map.put(:served_model, config.openai_fallback_model)}
    end
  end

  defp preserve_effort_across_fallback(%Config{} = config) do
    model =
      case nonblank_environment("OPENAI_AGENT_FALLBACK_MODEL") do
        pinned when is_binary(pinned) -> config.openai_fallback_model
        _ -> equivalent_openai_model(config.model) || config.openai_fallback_model
      end

    effort =
      case nonblank_environment("OPENAI_AGENT_FALLBACK_REASONING_EFFORT") do
        pinned when is_binary(pinned) -> config.openai_reasoning_effort
        _ -> supported_effort("openai", model, config.thinking_level) || config.openai_reasoning_effort
      end

    %{config | openai_fallback_model: model, openai_reasoning_effort: effort}
  end

  defp equivalent_openai_model(claude_model) when is_binary(claude_model) do
    case claude_model do
      "claude-fable-5" -> "gpt-5.6-sol"
      "claude-opus-4-8" -> "gpt-5.6-sol"
      "claude-sonnet-5" -> "gpt-5.6-terra"
      _ -> "gpt-5.6-luna"
    end
  end

  defp equivalent_openai_model(_claude_model), do: nil

  defp supported_effort(provider, model, requested) when is_binary(requested) do
    case Map.get(@thinking_levels, {provider, model}) do
      levels when is_list(levels) -> if requested in levels, do: requested, else: List.last(levels)
      _ -> nil
    end
  end

  defp supported_effort(_provider, _model, _requested), do: nil

  defp request_claude_completion_stream(messages, %Config{} = config, api_key) do
    body = messages |> claude_request_payload(config) |> Jason.encode!()

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"}
    ]

    request = Finch.build(:post, config.claude_api_url || @claude_api, headers, body)
    callback = config.callback || fn _event -> :ok end

    emitted_text_key = {__MODULE__, :claude_emitted_text, make_ref()}
    Process.put(emitted_text_key, false)

    result =
      try do
        Finch.stream(
          request,
          VibeAgents.Finch,
          %{
            text: "",
            tool_calls: [],
            current_tool_index: -1,
            stop_reason: nil,
            buffer: "",
            thinking_active: nil,
            thinking_blocks: []
          },
          fn
            {:status, status}, acc ->
              Map.put(acc, :status, status)

            {:headers, resp_headers}, acc ->
              Map.put(acc, :headers, resp_headers)

            {:data, data}, acc ->
              acc = maybe_keep_error_body(acc, data)
              {events, buffer} = parse_sse_events((acc.buffer || "") <> data)
              acc = Map.put(acc, :buffer, buffer)

              Enum.reduce(events, acc, fn event, inner_acc ->
                case event do
                  %{
                    "type" => "content_block_delta",
                    "delta" => %{"type" => "text_delta", "text" => text}
                  } ->
                    if config.stream_text? do
                      Process.put(emitted_text_key, true)
                      callback.(%{type: :text, content: text})
                    end

                    Map.update(inner_acc, :text, text, &(&1 <> text))

                  %{
                    "type" => "content_block_start",
                    "content_block" => %{"type" => "tool_use"} = tool
                  } ->
                    new_tool = Map.put(tool, "input_json", "")
                    new_index = length(inner_acc.tool_calls)

                    inner_acc
                    |> Map.update(:tool_calls, [new_tool], &(&1 ++ [new_tool]))
                    |> Map.put(:current_tool_index, new_index)

                  %{
                    "type" => "content_block_start",
                    "index" => index,
                    "content_block" => %{"type" => "thinking"}
                  } ->
                    callback.(%{type: :thinking, status: "running", content: "", tokens: 0})
                    Map.put(inner_acc, :thinking_active, %{index: index, text: "", signature: nil})

                  %{
                    "type" => "content_block_delta",
                    "delta" => %{"type" => "thinking_delta", "thinking" => chunk}
                  }
                  when is_binary(chunk) ->
                    active = inner_acc.thinking_active || %{index: nil, text: "", signature: nil}
                    text = active.text <> chunk

                    callback.(%{
                      type: :thinking,
                      status: "running",
                      content: chunk,
                      text: text,
                      tokens: estimated_tokens(text)
                    })

                    Map.put(inner_acc, :thinking_active, %{active | text: text})

                  %{
                    "type" => "content_block_delta",
                    "delta" => %{"type" => "signature_delta", "signature" => signature}
                  } ->
                    case inner_acc.thinking_active do
                      nil -> inner_acc
                      active -> Map.put(inner_acc, :thinking_active, %{active | signature: signature})
                    end

                  %{"type" => "content_block_stop", "index" => index} ->
                    case inner_acc.thinking_active do
                      %{index: ^index} = active ->
                        callback.(%{
                          type: :thinking,
                          status: "done",
                          content: "",
                          text: active.text,
                          tokens: estimated_tokens(active.text)
                        })

                        inner_acc
                        |> Map.put(:thinking_active, nil)
                        |> Map.update(:thinking_blocks, [active], &(&1 ++ [active]))

                      _ ->
                        inner_acc
                    end

                  %{
                    "type" => "content_block_delta",
                    "delta" => %{"type" => "input_json_delta", "partial_json" => json}
                  } ->
                    idx = inner_acc.current_tool_index

                    if idx >= 0 do
                      updated_tools =
                        List.update_at(inner_acc.tool_calls, idx, fn tool ->
                          Map.update(tool, "input_json", json, &(&1 <> json))
                        end)

                      Map.put(inner_acc, :tool_calls, updated_tools)
                    else
                      inner_acc
                    end

                  %{"type" => "message_delta", "delta" => %{"stop_reason" => reason}} ->
                    Map.put(inner_acc, :stop_reason, reason)

                  _ ->
                    inner_acc
                end
              end)
          end
        )
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    emitted_text? = Process.get(emitted_text_key, false)
    Process.delete(emitted_text_key)

    case result do
      {:ok, final_acc} ->
        case final_acc.status do
          status when is_integer(status) and status != 200 ->
            Logger.error(
              "[#{config.request_label}] Claude streaming request failed with status #{status}" <>
                error_body_suffix(final_acc)
            )

            {:error, "API error: #{status}", %{emitted_text?: emitted_text?}}

          _ ->
            case final_acc.stop_reason do
              "tool_use" ->
                tools_with_input =
                  Enum.map(final_acc.tool_calls, fn tool ->
                    input =
                      case Jason.decode(tool["input_json"] || "{}") do
                        {:ok, parsed} -> parsed
                        _ -> %{}
                      end

                    Map.put(tool, "input", input)
                  end)

                {:tool_use, tools_with_input, build_content_blocks(final_acc), final_acc.text}

              _ ->
                {:ok, final_acc.text}
            end
        end

      {:error, reason} ->
        Logger.error("[#{config.request_label}] Claude streaming request failed: #{inspect(reason)}")
        {:error, "AI request failed.", %{emitted_text?: emitted_text?}}

      {:error, reason, _partial_acc} ->
        Logger.error(
          "[#{config.request_label}] Claude streaming request errored mid-stream: #{inspect(reason)}"
        )

        {:error, "AI request failed.", %{emitted_text?: emitted_text?}}
    end
  end

  defp request_openai_completion_stream(messages, %Config{} = config, api_key) do
    body = messages |> openai_request_payload(config) |> Jason.encode!()

    headers = [{"content-type", "application/json"}, {"authorization", "Bearer #{api_key}"}]
    request = Finch.build(:post, config.openai_responses_url || @openai_responses_api, headers, body)
    callback = config.callback || fn _event -> :ok end

    result =
      try do
        Finch.stream(
          request,
          VibeAgents.Finch,
          %{
            status: nil,
            text: "",
            tool_calls: %{},
            tool_order: [],
            completed?: false,
            error: nil,
            buffer: ""
          },
          fn
            {:status, status}, acc ->
              Map.put(acc, :status, status)

            {:headers, response_headers}, acc ->
              Map.put(acc, :headers, response_headers)

            {:data, data}, acc ->
              acc = maybe_keep_error_body(acc, data)
              {events, buffer} = parse_sse_events((acc.buffer || "") <> data)
              acc = Map.put(acc, :buffer, buffer)

              Enum.reduce(events, acc, fn event, inner_acc ->
                {next_acc, text_delta} = reduce_openai_stream_event(inner_acc, event)

                if config.stream_text? and is_binary(text_delta) and text_delta != "" do
                  callback.(%{type: :text, content: text_delta})
                end

                drain_thinking(next_acc, callback)
              end)
          end
        )
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, final_acc} ->
        cond do
          is_integer(final_acc.status) and final_acc.status != 200 ->
            Logger.error(
              "[#{config.request_label}] OpenAI Responses request failed with status " <>
                "#{final_acc.status}" <> error_body_suffix(final_acc)
            )

            {:error, "OpenAI API error: #{final_acc.status}"}

          is_binary(final_acc.error) ->
            Logger.error("[#{config.request_label}] OpenAI Responses stream failed: #{final_acc.error}")
            {:error, "OpenAI response failed."}

          not final_acc.completed? ->
            Logger.error("[#{config.request_label}] OpenAI Responses stream ended before completion")
            {:error, "OpenAI response ended before completion."}

          true ->
            finalize_openai_response(final_acc)
        end

      {:error, reason} ->
        Logger.error("[#{config.request_label}] OpenAI Responses request failed: #{inspect(reason)}")
        {:error, "AI request failed."}
    end
  end

  @doc false
  def claude_request_payload(messages, %Config{} = config) do
    payload = %{
      "model" => config.model,
      "max_tokens" => config.max_tokens,
      "system" => cache_system(resolve_system_prompt(config.system_prompt, config.state)),
      "tools" => cache_tools(config.tools),
      "messages" => cache_messages(messages),
      "stream" => true
    }

    if adaptive_thinking_model?(config.model) do
      payload
      |> Map.put("thinking", %{"type" => "adaptive"})
      |> Map.put("output_config", %{"effort" => config.thinking_level})
    else
      payload
    end
  end

  defp adaptive_thinking_model?(model) when is_binary(model) do
    case Map.get(@thinking_levels, {"anthropic", model}) do
      levels when is_list(levels) and length(levels) > 1 -> true
      levels when is_list(levels) -> false
      _ -> model in @adaptive_claude_models
    end
  end

  defp adaptive_thinking_model?(_model), do: false


  @cache_control %{"type" => "ephemeral"}

  defp prompt_cache?, do: Application.get_env(:vibe_agents, :prompt_cache, true)

  defp cache_system(prompt) when is_binary(prompt) and prompt != "" do
    if prompt_cache?() do
      [%{"type" => "text", "text" => prompt, "cache_control" => @cache_control}]
    else
      prompt
    end
  end

  defp cache_system(prompt), do: prompt

  defp cache_tools(tools) when is_list(tools) and tools != [] do
    if prompt_cache?(), do: mark_last(tools, &Map.put(&1, "cache_control", @cache_control)), else: tools
  end

  defp cache_tools(tools), do: tools

  defp cache_messages(messages) when is_list(messages) and messages != [] do
    if prompt_cache?(), do: mark_last(messages, &mark_message/1), else: messages
  end

  defp cache_messages(messages), do: messages

  defp mark_last(list, fun) do
    case List.last(list) do
      %{} = last -> List.replace_at(list, length(list) - 1, fun.(last))
      _ -> list
    end
  end

  defp mark_message(message) do
    {key, content} =
      cond do
        is_map_key(message, "content") -> {"content", message["content"]}
        is_map_key(message, :content) -> {:content, message.content}
        true -> {nil, nil}
      end

    case {key, content} do
      {nil, _} ->
        message

      {_, text} when is_binary(text) and text != "" ->
        Map.put(message, key, [
          %{"type" => "text", "text" => text, "cache_control" => @cache_control}
        ])

      {_, blocks} when is_list(blocks) and blocks != [] ->
        Map.put(message, key, mark_last(blocks, &Map.put(&1, "cache_control", @cache_control)))

      _ ->
        message
    end
  end

  @doc false
  def openai_request_payload(messages, %Config{} = config) do
    %{
      "model" => openai_model(config),
      "instructions" => resolve_system_prompt(config.system_prompt, config.state),
      "input" => openai_input(messages),
      "tools" => openai_tools(config.tools),
      "max_output_tokens" => config.max_tokens,
      "reasoning" => %{"effort" => openai_reasoning_effort(config), "summary" => "auto"},
      "stream" => true,
      "store" => false
    }
  end

  @doc false
  def openai_input(messages) when is_list(messages), do: Enum.flat_map(messages, &openai_input_message/1)

  @doc false
  def openai_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "name" => value(tool, :name),
        "description" => value(tool, :description),
        "parameters" => value(tool, :input_schema) || value(tool, :parameters) || %{}
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
  end

  @doc false
  def reduce_openai_stream_event(acc, event) when is_map(acc) and is_map(event) do
    case event do
      %{"type" => "response.output_text.delta", "delta" => delta} when is_binary(delta) ->
        {Map.update(acc, :text, delta, &(&1 <> delta)), delta}

      %{"type" => "response.reasoning_summary_part.added"} ->
        {queue_thinking(acc, "", :running), nil}

      %{"type" => "response.reasoning_summary_text.delta", "delta" => delta} when is_binary(delta) ->
        {queue_thinking(acc, delta, :running), nil}

      %{"type" => "response.reasoning_summary_text.done", "text" => text} when is_binary(text) ->
        {acc |> put_thinking_text(text) |> queue_thinking("", :done), nil}

      %{"type" => type, "item" => %{"type" => "function_call"} = item}
      when type in ["response.output_item.added", "response.output_item.done"] ->
        {put_openai_tool_call(acc, event, item), nil}

      %{"type" => "response.function_call_arguments.delta", "delta" => delta} when is_binary(delta) ->
        {append_openai_tool_arguments(acc, event, delta), nil}

      %{"type" => "response.function_call_arguments.done", "arguments" => arguments}
      when is_binary(arguments) ->
        {set_openai_tool_arguments(acc, event, arguments), nil}

      %{"type" => "response.completed"} ->
        {%{acc | completed?: true}, nil}

      %{"type" => "response.failed"} = failed_event ->
        {Map.put(acc, :error, openai_event_error(failed_event, "OpenAI response failed")), nil}

      %{"type" => "response.incomplete"} = incomplete_event ->
        {Map.put(acc, :error, openai_event_error(incomplete_event, "OpenAI response incomplete")), nil}

      %{"type" => "error"} = error_event ->
        {Map.put(acc, :error, openai_event_error(error_event, "OpenAI stream error")), nil}

      _ ->
        {acc, nil}
    end
  end

  @doc false
  def finalize_openai_response(acc) do
    with {:ok, tool_calls} <- decoded_openai_tool_calls(acc) do
      if tool_calls == [] do
        {:ok, acc.text}
      else
        partial_response =
          if(acc.text == "", do: [], else: [%{"type" => "text", "text" => acc.text}]) ++
            Enum.map(tool_calls, fn tool ->
              %{"type" => "tool_use", "id" => tool["id"], "name" => tool["name"], "input" => tool["input"]}
            end)

        {:tool_use, tool_calls, partial_response, acc.text}
      end
    end
  end

  defp decoded_openai_tool_calls(acc) do
    Enum.reduce_while(acc.tool_order, {:ok, []}, fn key, {:ok, decoded} ->
      tool = Map.fetch!(acc.tool_calls, key)

      case Jason.decode(tool["input_json"] || "{}") do
        {:ok, input} when is_map(input) ->
          parsed = %{"id" => tool["id"], "name" => tool["name"], "input" => input}
          {:cont, {:ok, decoded ++ [parsed]}}

        _ ->
          {:halt, {:error, "OpenAI returned invalid arguments for #{tool["name"]}."}}
      end
    end)
  end

  defp put_openai_tool_call(acc, event, item) do
    key = openai_tool_key(event, item)
    existing = Map.get(acc.tool_calls, key, %{})

    tool = %{
      "id" => item["call_id"] || existing["id"] || item["id"],
      "name" => item["name"] || existing["name"],
      "input_json" => item["arguments"] || existing["input_json"] || ""
    }

    acc |> Map.update!(:tool_calls, &Map.put(&1, key, tool)) |> remember_openai_tool(key)
  end

  defp append_openai_tool_arguments(acc, event, delta) do
    key = openai_tool_key(event, %{})
    existing = Map.get(acc.tool_calls, key, %{})

    tool =
      existing
      |> Map.put_new("id", event["call_id"] || event["item_id"])
      |> Map.put_new("name", event["name"])
      |> Map.update("input_json", delta, &(&1 <> delta))

    acc |> Map.update!(:tool_calls, &Map.put(&1, key, tool)) |> remember_openai_tool(key)
  end

  defp set_openai_tool_arguments(acc, event, arguments) do
    key = openai_tool_key(event, %{})
    existing = Map.get(acc.tool_calls, key, %{})

    tool =
      existing
      |> Map.put_new("id", event["call_id"] || event["item_id"])
      |> Map.put_new("name", event["name"])
      |> Map.put("input_json", arguments)

    acc |> Map.update!(:tool_calls, &Map.put(&1, key, tool)) |> remember_openai_tool(key)
  end

  defp remember_openai_tool(acc, key) do
    Map.update!(acc, :tool_order, fn order -> if key in order, do: order, else: order ++ [key] end)
  end

  defp openai_tool_key(event, item), do: item["id"] || event["item_id"] || "output:#{event["output_index"] || 0}"

  defp openai_event_error(event, fallback) do
    get_in(event, ["response", "error", "message"]) ||
      get_in(event, ["response", "incomplete_details", "reason"]) ||
      get_in(event, ["error", "message"]) || event["message"] || fallback
  end

  defp openai_input_message(message) do
    role = message |> value(:role) |> to_string()
    content = value(message, :content)

    cond do
      is_binary(content) ->
        [%{"role" => role, "content" => content}]

      is_list(content) and role == "assistant" ->
        Enum.flat_map(content, &openai_assistant_content_item/1)

      is_list(content) and Enum.any?(content, &(value(&1, :type) == "tool_result")) ->
        Enum.flat_map(content, &openai_tool_result_item/1)

      is_list(content) ->
        converted = Enum.flat_map(content, &openai_user_content_item/1)
        if converted == [], do: [], else: [%{"role" => role, "content" => converted}]

      true ->
        []
    end
  end

  defp openai_assistant_content_item(item) do
    case value(item, :type) do
      "text" ->
        [%{"role" => "assistant", "content" => value(item, :text) || ""}]

      "tool_use" ->
        [
          %{
            "type" => "function_call",
            "call_id" => value(item, :id),
            "name" => value(item, :name),
            "arguments" => Jason.encode!(value(item, :input) || %{})
          }
        ]

      _ ->
        []
    end
  end

  defp openai_tool_result_item(item) do
    if value(item, :type) == "tool_result" do
      [
        %{
          "type" => "function_call_output",
          "call_id" => value(item, :tool_use_id),
          "output" => value(item, :content) || ""
        }
      ]
    else
      openai_user_content_item(item)
    end
  end

  defp openai_user_content_item(item) do
    case value(item, :type) do
      "text" ->
        [%{"type" => "input_text", "text" => value(item, :text) || ""}]

      "image" ->
        case item |> value(:source) |> value(:url) do
          url when is_binary(url) -> [%{"type" => "input_image", "image_url" => url}]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_value, _key), do: nil

  defp apply_openai_environment(%Config{} = config) do
    configured_model = nonblank_environment("OPENAI_AGENT_FALLBACK_MODEL") || config.openai_fallback_model

    model =
      if modern_gpt_family?(configured_model) do
        configured_model
      else
        Logger.warning(
          "[#{config.request_label}] Ignoring OpenAI fallback model #{inspect(configured_model)}; " <>
            "Vibe fallback requires the GPT-5.5 or GPT-5.6 family"
        )

        @default_openai_fallback_model
      end

    reasoning_effort =
      case nonblank_environment("OPENAI_AGENT_FALLBACK_REASONING_EFFORT") do
        effort when effort in ["none", "low", "medium", "high", "xhigh", "max"] -> effort
        nil -> config.openai_reasoning_effort
        _unsupported -> @default_openai_reasoning_effort
      end

    %{config | openai_fallback_model: model, openai_reasoning_effort: reasoning_effort}
  end

  defp openai_model(%Config{provider: provider, model: model}) when provider in [:openai, "openai"], do: model
  defp openai_model(%Config{} = config), do: config.openai_fallback_model

  defp openai_reasoning_effort(%Config{provider: provider, thinking_level: thinking_level})
       when provider in [:openai, "openai"],
       do: thinking_level

  defp openai_reasoning_effort(%Config{} = config), do: config.openai_reasoning_effort

  defp modern_gpt_family?(model) when is_binary(model) do
    String.starts_with?(model, "gpt-5.5") or String.starts_with?(model, "gpt-5.6")
  end

  defp nonblank_environment(name) do
    case System.get_env(name) do
      value when is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
      _ -> nil
    end
  end

  defp normalize_config(%Config{} = config), do: config
  defp normalize_config(opts) when is_list(opts), do: opts |> Enum.into(%{}) |> normalize_config()
  defp normalize_config(opts) when is_map(opts), do: struct!(Config, opts)

  defp resolve_system_prompt(system_prompt, state) when is_function(system_prompt, 1), do: system_prompt.(state)
  defp resolve_system_prompt(system_prompt, _state) when is_binary(system_prompt), do: system_prompt

  defp queue_thinking(acc, chunk, status) do
    text = Map.get(acc, :thinking_text, "") <> chunk

    acc
    |> Map.put(:thinking_text, text)
    |> Map.put(:thinking_pending, %{
      status: if(status == :done, do: "done", else: "running"),
      content: chunk,
      text: text,
      tokens: estimated_tokens(text)
    })
  end

  defp put_thinking_text(acc, text), do: Map.put(acc, :thinking_text, text)

  defp drain_thinking(acc, callback) do
    case Map.get(acc, :thinking_pending) do
      nil -> acc
      pending ->
        callback.(Map.put(pending, :type, :thinking))
        Map.put(acc, :thinking_pending, nil)
    end
  end

  defp estimated_tokens(text), do: text |> to_string() |> String.length() |> div(4) |> max(0)

  defp join_beats(accumulated, next) do
    left = to_string(accumulated)
    right = to_string(next)

    cond do
      String.trim(left) == "" -> right
      String.trim(right) == "" -> left
      String.ends_with?(left, ["\n", " "]) -> left <> right
      String.starts_with?(right, ["\n", " "]) -> left <> right
      true -> left <> "\n\n" <> right
    end
  end

  @error_body_limit 600

  defp maybe_keep_error_body(acc, data) do
    case Map.get(acc, :status) do
      status when is_integer(status) and status != 200 ->
        kept = Map.get(acc, :error_body) || ""

        if String.length(kept) >= @error_body_limit do
          acc
        else
          Map.put(acc, :error_body, String.slice(kept <> to_string(data), 0, @error_body_limit))
        end

      _ ->
        acc
    end
  end

  defp error_body_suffix(acc) do
    case Map.get(acc, :error_body) do
      body when is_binary(body) ->
        trimmed = body |> String.replace(~r/\s+/, " ") |> String.trim()
        if trimmed == "", do: "", else: ": #{trimmed}"

      _ ->
        ""
    end
  end

  defp parse_sse_events(data) do
    data = data |> to_string() |> String.replace("\r\n", "\n")
    chunks = String.split(data, "\n\n", trim: false)

    {complete_chunks, remaining} =
      if String.ends_with?(data, "\n\n") do
        {Enum.reject(chunks, &(&1 == "")), ""}
      else
        case Enum.split(chunks, max(length(chunks) - 1, 0)) do
          {complete, [tail]} -> {Enum.reject(complete, &(&1 == "")), tail}
          {complete, []} -> {Enum.reject(complete, &(&1 == "")), ""}
        end
      end

    events = complete_chunks |> Enum.map(&parse_sse_event_block/1) |> Enum.reject(&is_nil/1)
    {events, remaining}
  end

  defp parse_sse_event_block(chunk) do
    payload =
      chunk
      |> String.split("\n", trim: false)
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn line -> line |> String.replace_prefix("data:", "") |> String.trim_leading() end)
      |> Enum.join("\n")

    cond do
      payload == "" -> nil
      payload == "[DONE]" -> nil
      true ->
        case Jason.decode(payload) do
          {:ok, parsed} -> parsed
          _ -> nil
        end
    end
  end

  defp build_content_blocks(acc) do
    thinking_blocks =
      acc
      |> Map.get(:thinking_blocks, [])
      |> Enum.filter(&(is_binary(&1.signature) and &1.text != ""))
      |> Enum.map(&%{"type" => "thinking", "thinking" => &1.text, "signature" => &1.signature})

    blocks = if acc.text != "", do: thinking_blocks ++ [%{"type" => "text", "text" => acc.text}], else: thinking_blocks

    acc.tool_calls
    |> Enum.reduce(blocks, fn tool, acc_blocks ->
      input =
        case Jason.decode(tool["input_json"] || "{}") do
          {:ok, parsed} -> parsed
          _ -> %{}
        end

      acc_blocks ++ [%{"type" => "tool_use", "id" => tool["id"], "name" => tool["name"], "input" => input}]
    end)
  end
end
