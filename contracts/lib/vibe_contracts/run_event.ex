defmodule VibeContracts.RunEvent do
  @moduledoc """
  `vibe.agentic.v1` run-stream event: builds and validates the frozen
  `contract runId agentId agentUserId chatId seq ts kind payload` shape.
  """

  @kinds ~w(
    run.queued run.started run.text.delta run.thinking run.progress
    run.tool.started run.tool.completed run.approval.requested run.approval.resolved
    run.ask run.permission.requested run.preview run.handoff
    run.computer.state run.computer.control
    run.cancelled run.completed run.failed
  )

  @terminal_kinds ~w(run.cancelled run.completed run.failed)

  # Required payload keys per kind (spec §3.4).
  @payload_schemas %{
    "run.queued" => ~w(source model),
    "run.started" => ~w(source model),
    "run.text.delta" => ~w(text),
    "run.thinking" => ~w(tokens label),
    "run.progress" => ~w(label status),
    "run.tool.started" => ~w(toolCallId tool label input),
    "run.tool.completed" => ~w(toolCallId tool label status summary),
    "run.approval.requested" => ~w(decisionId kind title risk actions),
    "run.approval.resolved" => ~w(decisionId outcome actorUserId),
    "run.ask" => ~w(decisionId questions),
    "run.permission.requested" => ~w(decisionId capability scope reason),
    "run.preview" => ~w(imageBase64 mime width height label),
    "run.handoff" => ~w(toAgentUsername note childRunId),
    "run.computer.state" => ~w(url title live),
    "run.computer.control" => ~w(holder),
    "run.cancelled" => ~w(reason),
    "run.completed" => ~w(summary usage costCents),
    "run.failed" => ~w(error code)
  }

  @type t :: %{required(binary()) => term()}

  @doc "All frozen `RunEvent` kinds."
  @spec kinds() :: [binary()]
  def kinds, do: @kinds

  @doc "True for the 3 terminal kinds: run.cancelled, run.completed, run.failed."
  @spec terminal?(binary()) :: boolean()
  def terminal?(kind), do: kind in @terminal_kinds

  @doc "Required payload keys for a kind (extra keys allowed); unknown kind → []."
  @spec payload_schema(binary()) :: [binary()]
  def payload_schema(kind), do: Map.get(@payload_schemas, kind, [])

  @doc """
  Builds a new event, defaulting `contract` to `vibe.agentic.v1`, `ts` to now
  (ms), and `payload` to `%{}`. Accepts atom or string keys.
  """
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) do
    attrs
    |> stringify_keys()
    |> Map.put_new_lazy("contract", &VibeContracts.agentic_contract/0)
    |> Map.put_new_lazy("ts", fn -> System.system_time(:millisecond) end)
    |> Map.put_new("payload", %{})
    |> validate_fields()
  end

  @doc "Validates an incoming event map (atom or string keys); returns a normalized string-key map."
  @spec validate(map()) :: {:ok, t()} | {:error, atom()}
  def validate(attrs) do
    attrs
    |> stringify_keys()
    |> Map.put_new("payload", %{})
    |> validate_fields()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp validate_fields(event) do
    with {:ok, run_id} <- require_id(event, "runId", :invalid_run_id),
         {:ok, agent_id} <- require_id(event, "agentId", :invalid_agent_id),
         {:ok, agent_user_id} <- require_id(event, "agentUserId", :invalid_agent_user_id),
         {:ok, chat_id} <- require_id(event, "chatId", :invalid_chat_id),
         {:ok, kind} <- require_kind(event),
         {:ok, seq} <- require_seq(event),
         {:ok, ts} <- require_ts(event),
         {:ok, payload} <- require_payload(event, kind) do
      {:ok,
       %{
         "contract" => Map.get(event, "contract") || VibeContracts.agentic_contract(),
         "runId" => run_id,
         "agentId" => agent_id,
         "agentUserId" => agent_user_id,
         "chatId" => chat_id,
         "seq" => seq,
         "ts" => ts,
         "kind" => kind,
         "payload" => payload
       }}
    end
  end

  defp require_id(event, field, error) do
    case Map.get(event, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp require_kind(event) do
    case Map.get(event, "kind") do
      kind when kind in @kinds -> {:ok, kind}
      _ -> {:error, :invalid_kind}
    end
  end

  defp require_seq(event) do
    case Map.get(event, "seq") do
      seq when is_integer(seq) and seq >= 0 -> {:ok, seq}
      _ -> {:error, :invalid_seq}
    end
  end

  defp require_ts(event) do
    case Map.get(event, "ts") do
      ts when is_integer(ts) and ts >= 0 -> {:ok, ts}
      _ -> {:error, :invalid_ts}
    end
  end

  defp require_payload(event, kind) do
    case Map.get(event, "payload") do
      payload when is_map(payload) ->
        normalized = stringify_keys(payload)

        if Enum.all?(payload_schema(kind), &Map.has_key?(normalized, &1)) do
          {:ok, normalized}
        else
          {:error, :invalid_payload}
        end

      _ ->
        {:error, :invalid_payload}
    end
  end
end
