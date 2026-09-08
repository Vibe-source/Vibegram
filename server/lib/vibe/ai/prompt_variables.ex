defmodule Vibe.AI.PromptVariables do
  @moduledoc """
  Prompt arguments for agents.
  """

  @placeholder ~r/\{\{\s*([a-zA-Z0-9_\.]+)\s*\}\}/

  @doc """
  Normalize raw input (from the API/agent) into the canonical list of variable definition maps
  with string keys: `name`, `description`, `value`.
  """
  def normalize(raw) do
    raw
    |> List.wrap()
    |> Enum.map(&normalize_one/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce({[], MapSet.new()}, fn var, {acc, seen} ->
      name = var["name"]

      if MapSet.member?(seen, name) do
        {Enum.reject(acc, &(&1["name"] == name)) ++ [var], seen}
      else
        {acc ++ [var], MapSet.put(seen, name)}
      end
    end)
    |> elem(0)
  end

  defp normalize_one(map) when is_map(map) do
    name =
      (get(map, "name") || get(map, "key"))
      |> normalize_name()

    if is_nil(name) do
      nil
    else
      %{
        "name" => name,
        "description" => trim_string(get(map, "description")) || "",
        "value" => to_value_string(get(map, "value") || get(map, "default")),
        "secret" => truthy?(get(map, "secret"))
      }
    end
  end

  defp normalize_one(_), do: nil

  @doc """
  Definitions enriched with the resolved effective value and a `locked` flag for config
  display.
  """
  def definitions(agent) do
    overrides = overrides_for(agent)
    stored = normalize(Map.get(agent, :prompt_variables) || [])

    enriched =
      Enum.map(stored, fn var ->
        case Map.fetch(overrides, var["name"]) do
          {:ok, pinned} ->
            Map.merge(var, %{"value" => to_value_string(pinned), "locked" => true})

          :error ->
            Map.put(var, "locked", false)
        end
      end)

    stored_names = MapSet.new(Enum.map(stored, & &1["name"]))

    extra =
      overrides
      |> Enum.reject(fn {name, _} -> MapSet.member?(stored_names, name) end)
      |> Enum.map(fn {name, value} ->
        %{"name" => name, "description" => "Pinned in code", "value" => to_value_string(value), "locked" => true}
      end)

    enriched ++ extra
  end

  @doc """
  Map of `name => effective value` used for rendering.
  """
  def effective_values(agent, opts \\ []) do
    admin_mode = Keyword.get(opts, :admin_mode, true)

    agent
    |> definitions()
    |> Enum.into(%{}, fn var ->
      value = if not admin_mode and var["secret"], do: "", else: var["value"]
      {var["name"], value}
    end)
  end

  @doc """
  Replace `{{name}}` placeholders in `text` with effective values.
  """
  def render(text, agent, opts \\ [])

  def render(text, agent, opts) when is_binary(text) do
    values = effective_values(agent, opts)

    Regex.replace(@placeholder, text, fn whole, name ->
      Map.get(values, name, whole)
    end)
  end

  def render(text, _agent, _opts), do: text

  @doc "The code-pinned overrides for an agent as a `name => value` map."
  def overrides_for(agent) do
    table = Application.get_env(:vibe, :prompt_variable_overrides, %{})
    username = agent_username(agent)
    id = Map.get(agent, :id)

    (Map.get(table, username) || Map.get(table, id) || %{})
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp agent_username(agent) do
    case Map.get(agent, :agent_user) do
      %{username: username} when is_binary(username) -> username
      _ -> nil
    end
  end

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\.]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp normalize_name(_), do: nil

  defp trim_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_string(_), do: nil

  defp to_value_string(nil), do: ""
  defp to_value_string(value) when is_binary(value), do: value
  defp to_value_string(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp to_value_string(value), do: inspect(value)

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp get(map, key), do: Map.get(map, key) || Map.get(map, safe_atom(key))

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
