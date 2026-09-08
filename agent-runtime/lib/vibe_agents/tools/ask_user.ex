defmodule VibeAgents.Tools.AskUser do
  @moduledoc """
  Terminal, exactly like the core: creates the decision row itself (kind "ask"), emits
  `run.ask`, and returns a `status: "waiting_for_user"` result so the ported LLM loop ends
  the turn. `VibeAgents.Runs.Loop.finish/3` turns that into a question output + waiting_ask.
  """
  alias VibeAgents.Runs.{Decisions, Events}

  def ask_user(run, input) when is_map(input) do
    questions = input |> Map.get("questions", []) |> VibeContracts.AskQuestion.normalize()

    if questions == [] do
      %{"ok" => false, "error" => "At least one valid question is required."}
    else
      {:ok, decision} = Decisions.create(%{run_id: run.id, kind: "ask", request: %{"questions" => questions}})
      Events.emit(run, "run.ask", %{"decisionId" => decision.id, "questions" => questions})

      %{
        "ok" => true,
        "requestId" => decision.id,
        "status" => "waiting_for_user",
        "fallbackText" => Enum.map_join(questions, "\n", & &1["question"]),
        "questions" => questions
      }
    end
  end

  def ask_user(_run, _input), do: %{"ok" => false, "error" => "At least one valid question is required."}
end
