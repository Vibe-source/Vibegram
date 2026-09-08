defmodule VibeContracts.Outputs do
  @moduledoc """
  Finalized-output builders and batch stamping (`docs/agent-turn-contract.md`).
  `finalize_batch/2` ports the core's `standalone_agent.ex` `finalize_batch/2`.
  """

  alias VibeContracts.Internal

  @doc "Text output: `{\"type\":\"text\",\"text\":…,\"mediaUrl\":nil,\"metadata\":…}`."
  @spec text_output(binary(), map()) :: map()
  def text_output(text, metadata \\ %{}) do
    %{"type" => "text", "text" => text || "", "mediaUrl" => nil, "metadata" => metadata || %{}}
  end

  @doc "Image output at `url`."
  @spec image_output(binary(), map()) :: map()
  def image_output(url, metadata \\ %{}) do
    %{"type" => "image", "text" => "", "mediaUrl" => url, "metadata" => metadata || %{}}
  end

  @doc "File output at `url`; `name`/`mime` are merged into metadata."
  @spec file_output(binary(), binary(), binary(), map()) :: map()
  def file_output(url, name, mime, metadata \\ %{}) do
    %{
      "type" => "file",
      "text" => "",
      "mediaUrl" => url,
      "metadata" => Map.merge(%{"name" => name, "mime" => mime}, metadata || %{})
    }
  end

  @doc "Question output for a `run.ask` / `ask_user` turn awaiting the user's answer."
  @spec question_output(binary(), [map()], binary() | nil) :: map()
  def question_output(request_id, questions, fallback_text \\ nil) do
    text = fallback_text || "Your input is needed to continue."

    %{
      "type" => "question",
      "text" => text,
      "mediaUrl" => nil,
      "requestId" => request_id,
      "status" => "waiting_for_user",
      "questions" => questions,
      "metadata" => %{
        "requestId" => request_id,
        "status" => "waiting_for_user",
        "questions" => questions
      }
    }
  end

  @doc """
  Stamps `agentTurnId agentBatchId agentPartId agentPartIndex agentPartCount
  agentPartKind agentFinalized` onto each output. `opts`: `agent_turn_id:`, `agent_batch_id:`, `base_timestamp:`.
  """
  @spec finalize_batch([map()], keyword()) :: [map()]
  def finalize_batch(outputs, opts \\ []) do
    agent_turn_id = Keyword.get(opts, :agent_turn_id) || Internal.uuid4()
    agent_batch_id = Keyword.get(opts, :agent_batch_id) || Internal.uuid4()
    base_timestamp = Keyword.get(opts, :base_timestamp) || System.system_time(:millisecond)
    outputs = List.wrap(outputs)
    part_count = length(outputs)

    outputs
    |> Enum.with_index()
    |> Enum.map(fn {output, part_index} ->
      kind = output_type(output)

      batch_metadata = %{
        "agentTurnId" => agent_turn_id,
        "agentBatchId" => agent_batch_id,
        "agentPartId" => Internal.uuid4(),
        "agentPartIndex" => part_index,
        "agentPartCount" => part_count,
        "agentPartKind" => kind,
        "agentFinalized" => true
      }

      output
      |> Map.drop([:metadata, "metadata", :timestamp, "timestamp"])
      |> Map.put(:metadata, Map.merge(output_metadata(output), batch_metadata))
      |> Map.put(:timestamp, base_timestamp + part_index)
    end)
  end

  defp output_type(output) when is_map(output) do
    (Map.get(output, :type) || Map.get(output, "type")) |> to_string_or_default("text")
  end

  defp output_type(_output), do: "text"

  defp to_string_or_default(value, _default) when is_binary(value), do: value
  defp to_string_or_default(_value, default), do: default

  defp output_metadata(output) when is_map(output) do
    case Map.get(output, :metadata) || Map.get(output, "metadata") do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp output_metadata(_output), do: %{}
end
