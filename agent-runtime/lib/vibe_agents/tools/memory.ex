defmodule VibeAgents.Tools.Memory do
  @moduledoc "remember/recall over agent_memories: a small per-agent key/value+search store."
  import Ecto.Query
  alias VibeAgents.Repo
  alias VibeAgents.Schemas.AgentMemory

  @max_results 20
  @max_value_length 4_000

  def remember(run, input) when is_map(input) do
    key = trimmed(input["key"])
    value = trimmed(input["value"])

    cond do
      is_nil(key) -> %{"ok" => false, "error" => "key is required"}
      is_nil(value) -> %{"ok" => false, "error" => "value is required"}
      true -> upsert(run, key, String.slice(value, 0, @max_value_length))
    end
  end

  def remember(_run, _input), do: %{"ok" => false, "error" => "key and value are required"}

  defp upsert(run, key, value) do
    attrs = %{agent_id: run.agent_id, key: key, value: value, created_by_run_id: run.id}

    %AgentMemory{}
    |> AgentMemory.changeset(attrs)
    |> Repo.insert(
      on_conflict: [set: [value: value, created_by_run_id: run.id, updated_at: DateTime.utc_now()]],
      conflict_target: [:agent_id, :key]
    )
    |> case do
      {:ok, _memory} -> %{"ok" => true, "key" => key}
      {:error, changeset} -> %{"ok" => false, "error" => "could not save: #{inspect(changeset.errors)}"}
    end
  end

  def recall(run, input) when is_map(input) do
    query = trimmed(input["query"])

    memories =
      AgentMemory
      |> where([m], m.agent_id == ^run.agent_id)
      |> maybe_filter(query)
      |> order_by(desc: :updated_at)
      |> limit(@max_results)
      |> Repo.all()

    %{"ok" => true, "count" => length(memories), "memories" => Enum.map(memories, &%{"key" => &1.key, "value" => &1.value})}
  end

  def recall(_run, _input), do: %{"ok" => false, "error" => "query is required"}

  defp maybe_filter(query, nil), do: query

  defp maybe_filter(query, text) do
    pattern = "%" <> text <> "%"
    where(query, [m], ilike(m.key, ^pattern) or ilike(m.value, ^pattern))
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil
end
