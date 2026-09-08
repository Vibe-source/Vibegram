defmodule Vibe.AI.SubagentRegistry do
  @moduledoc false

  alias Vibe.AI.Agent, as: ChatAgent
  alias Vibe.AI.AgentBuilder

  # Specialists are OPTIONAL.
  @subagents %{
    "builder_assistant" => %{
      id: "builder_assistant",
      label: "Builder Assistant",
      description:
        "Multi-step agent creation, complex reconfiguration, publish/delete workflows — not simple one-field edits."
    },
    "integration_advisor" => %{
      id: "integration_advisor",
      label: "Integration Advisor",
      description:
        "Deep integration setup (invoke/events URLs, secrets, multi-room attach) when direct config tools are not enough."
    },
    "music_specialist" => %{
      id: "music_specialist",
      label: "Music Specialist",
      description:
        "Complex multi-track / playlist-scale music research only. Single songs and share URLs stay on the primary agent."
    },
    "document_specialist" => %{
      id: "document_specialist",
      label: "Document Specialist",
      description:
        "Multi-document or multi-source research synthesis only. One web lookup or one file stays on the primary agent."
    }
  }

  def specs do
    @subagents
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  def ids do
    Enum.map(specs(), & &1.id)
  end

  def get(id) when is_binary(id), do: Map.get(@subagents, id)
  def get(_id), do: nil

  def progress_label(id, task) do
    request = task |> to_string() |> String.trim()

    cond do
      request == "" ->
        fallback_progress_label(id)

      true ->
        request
        |> summarize_task_label()
        |> case do
          nil -> fallback_progress_label(id)
          label -> label
        end
    end
  end

  def run(id, task, opts \\ []) do
    request =
      task
      |> to_string()
      |> String.trim()

    callback = Keyword.get(opts, :callback)
    user_id = Keyword.get(opts, :user_id)
    requester_user_id = Keyword.get(opts, :requester_user_id)
    chat_id = Keyword.get(opts, :chat_id)
    active_agent_id = Keyword.get(opts, :active_agent_id)
    delegate_user_id = requester_user_id || user_id

    with %{} = spec <- get(id),
         true <- request != "" do
      job_label = progress_label(id, request)

      emit(callback, %{
        type: :subagent,
        event: "started",
        subagent: spec.id,
        label: spec.label,
        detail: job_label,
        status: "running"
      })

      emit(callback, %{
        type: :subagent,
        event: "progress",
        subagent: spec.id,
        label: spec.label,
        detail: job_label,
        status: "running"
      })

      result =
        case id do
          "builder_assistant" ->
            AgentBuilder.delegate_task(
              delegate_user_id,
              request,
              active_agent_id: active_agent_id,
              callback: wrap_callback(spec, callback)
            )

          "integration_advisor" ->
            AgentBuilder.delegate_task(
              delegate_user_id,
              "Help with agent integration details, endpoints, ids, auth, and attached vibe chat ids. #{request}",
              active_agent_id: active_agent_id,
              callback: wrap_callback(spec, callback)
            )

          "music_specialist" ->
            run_chat_subagent(
              request,
              spec,
              wrap_callback(spec, callback),
              user_id,
              chat_id,
              "You are the music specialist for Vibe AI, used only for complex multi-track or playlist-scale work. Use search_music directly. Keep replies minimal; the UI renders playable cells.",
              ["search_music"]
            )

          "document_specialist" ->
            run_chat_subagent(
              request,
              spec,
              wrap_callback(spec, callback),
              user_id,
              chat_id,
              "You are the document/research specialist for Vibe AI, used only for multi-source synthesis. Prefer the fewest tool calls needed. One lookup tasks should already have been handled by the primary agent.",
              ["search_google", "analyze_image", "analyze_document"]
            )
        end

      finalize_result(result, spec, callback)
    else
      nil -> {:error, :unknown_subagent}
      false -> {:error, :missing_task}
    end
  end

  defp run_chat_subagent(task, spec, callback, user_id, chat_id, system_prompt, enabled_tools) do
    case ChatAgent.stream_response(
           task,
           callback,
           user_id: user_id,
           chat_id: chat_id,
           system_prompt: system_prompt,
           enabled_tools: enabled_tools,
           max_tokens: 1024,
           max_depth: 1
         ) do
      {:ok, reply, _state} ->
        {:ok, %{reply: reply, metadata: %{"subagent" => spec.id}}}

      {:ok, reply} ->
        {:ok, %{reply: reply, metadata: %{"subagent" => spec.id}}}

      error ->
        error
    end
  end

  defp finalize_result({:ok, %{reply: reply} = result}, spec, callback) do
    emit(callback, %{
      type: :subagent,
      event: "finished",
      subagent: spec.id,
      label: spec.label,
      status: "complete"
    })

    {:ok,
     %{
       "ok" => true,
       "subagent_id" => spec.id,
       "label" => spec.label,
       "response" => to_string(reply || "") |> String.trim(),
       "metadata" => Map.get(result, :metadata) || Map.get(result, "metadata") || %{}
     }}
  end

  defp finalize_result({:error, reason}, spec, callback) do
    emit(callback, %{
      type: :subagent,
      event: "finished",
      subagent: spec.id,
      label: spec.label,
      status: "error",
      error: inspect(reason)
    })

    {:ok,
     %{
       "ok" => false,
       "subagent_id" => spec.id,
       "label" => spec.label,
       "error" => inspect(reason)
     }}
  end

  defp wrap_callback(spec, callback) when is_function(callback, 1) do
    fn
      %{type: :progress, label: label} = event ->
        callback.(%{
          type: :subagent,
          event: "progress",
          subagent: spec.id,
          label: spec.label,
          detail: label,
          tool: Map.get(event, :tool),
          status: Map.get(event, :status)
        })

      %{type: :tool_result, tool: tool_name} ->
        callback.(%{
          type: :subagent,
          event: "tool_result",
          subagent: spec.id,
          label: spec.label,
          tool: tool_name
        })

      %{type: :agent_cards} = event ->
        callback.(event)

      %{type: :state} = event ->
        callback.(event)

      %{type: :ui_request} = event ->
        callback.(event)

      %{type: :review_ready} = event ->
        callback.(event)

      %{type: :text, content: content} ->
        callback.(%{
          type: :subagent,
          event: "text",
          subagent: spec.id,
          label: spec.label,
          content: content
        })

      _ ->
        :ok
    end
  end

  defp wrap_callback(_spec, _callback), do: fn _event -> :ok end

  defp emit(callback, payload) when is_function(callback, 1), do: callback.(payload)
  defp emit(_callback, _payload), do: :ok

  defp summarize_task_label(task) do
    trimmed =
      task
      |> String.trim()
      |> String.replace(~r/\s+/, " ")
      |> String.trim_trailing(".")

    case Regex.run(~r/^\s*(check|find|get|read|list|review|show|look up|inspect|prepare|create|update|publish|rotate|generate|explain|analyze|search)\b\s*(.*)$/i, trimmed) do
      [_, verb, rest] ->
        job =
          case String.downcase(verb) do
            "check" -> "Checking"
            "find" -> "Finding"
            "get" -> "Getting"
            "read" -> "Reading"
            "list" -> "Listing"
            "review" -> "Reviewing"
            "show" -> "Reviewing"
            "look up" -> "Looking up"
            "inspect" -> "Inspecting"
            "prepare" -> "Preparing"
            "create" -> "Creating"
            "update" -> "Updating"
            "publish" -> "Publishing"
            "rotate" -> "Rotating"
            "generate" -> "Generating"
            "explain" -> "Gathering"
            "analyze" -> "Analyzing"
            "search" -> "Searching"
            _ -> nil
          end

        detail = String.trim(rest)

        cond do
          is_nil(job) -> fallback_sentence(trimmed)
          detail == "" -> "#{job}…"
          true -> "#{job} #{truncate_detail(detail)}…"
        end

      _ ->
        fallback_sentence(trimmed)
    end
  end

  defp fallback_sentence(""), do: nil
  defp fallback_sentence(text), do: "#{truncate_detail(text)}…"

  @progress_detail_limit 20

  defp truncate_detail(detail) do
    detail
    |> String.trim_leading("whether ")
    |> String.trim_leading("if ")
    |> String.trim()
    |> shorten_to_words(@progress_detail_limit)
  end

  defp shorten_to_words(text, limit) do
    if String.length(text) <= limit do
      text
    else
      cut = text |> String.slice(0, limit) |> String.trim()
      on_word = cut |> String.replace(~r/\s+\S*$/u, "") |> String.trim()

      if String.length(on_word) >= div(limit * 3, 5), do: on_word, else: cut
    end
  end

  defp fallback_progress_label("builder_assistant"), do: "Reviewing agent setup…"
  defp fallback_progress_label("integration_advisor"), do: "Checking integration…"
  defp fallback_progress_label("music_specialist"), do: "Checking music…"
  defp fallback_progress_label("document_specialist"), do: "Reviewing documents…"
  defp fallback_progress_label(_id), do: "Working on it…"
end
