defmodule VibeContracts.AskQuestionTest do
  use ExUnit.Case, async: true
  alias VibeContracts.AskQuestion

  test "normalizes a well-formed question" do
    raw = [
      %{
        "question" => "  Which room?  ",
        "header" => "Room",
        "multiSelect" => true,
        "options" => [
          %{"label" => "General", "description" => "The main room"},
          %{"label" => "Alerts", "description" => "Only alerts"}
        ]
      }
    ]

    assert [
             %{
               "question" => "Which room?",
               "header" => "Room",
               "multiSelect" => true,
               "options" => [
                 %{"label" => "General", "description" => "The main room"},
                 %{"label" => "Alerts", "description" => "Only alerts"}
               ]
             }
           ] = AskQuestion.normalize(raw)
  end

  test "accepts atom keys the same as string keys" do
    raw = [%{question: "Q?", header: "H", options: [%{label: "A"}, %{label: "B"}]}]
    assert [%{"question" => "Q?", "header" => "H"}] = AskQuestion.normalize(raw)
  end

  test "truncates header to 12 chars and question to 500 chars" do
    [q] =
      AskQuestion.normalize([
        %{
          "question" => String.duplicate("q", 600),
          "header" => "a very long header indeed",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        }
      ])

    assert String.length(q["header"]) == 12
    assert String.length(q["question"]) == 500
  end

  test "truncates option label to 80 chars and description to 240 chars" do
    [q] =
      AskQuestion.normalize([
        %{
          "question" => "Q",
          "header" => "H",
          "options" => [
            %{"label" => String.duplicate("l", 100), "description" => String.duplicate("d", 300)},
            %{"label" => "B"}
          ]
        }
      ])

    [opt1, _opt2] = q["options"]
    assert String.length(opt1["label"]) == 80
    assert String.length(opt1["description"]) == 240
  end

  test "drops a question with fewer than 2 valid options" do
    assert [] =
             AskQuestion.normalize([
               %{"question" => "Q", "header" => "H", "options" => [%{"label" => "only one"}]}
             ])

    assert [] = AskQuestion.normalize([%{"question" => "Q", "header" => "H", "options" => []}])
  end

  test "drops a question missing question text or header" do
    assert [] =
             AskQuestion.normalize([
               %{"header" => "H", "options" => [%{"label" => "A"}, %{"label" => "B"}]}
             ])

    assert [] =
             AskQuestion.normalize([
               %{"question" => "Q", "options" => [%{"label" => "A"}, %{"label" => "B"}]}
             ])
  end

  test "caps options at 4 when more than 4 unique labels are given" do
    options = for i <- 1..6, do: %{"label" => "opt#{i}"}
    [q] = AskQuestion.normalize([%{"question" => "Q", "header" => "H", "options" => options}])
    assert length(q["options"]) == 4
  end

  test "dedupes options by label, keeping the first occurrence" do
    options = [
      %{"label" => "A", "description" => "first"},
      %{"label" => "B"},
      %{"label" => "A", "description" => "second"}
    ]

    [q] = AskQuestion.normalize([%{"question" => "Q", "header" => "H", "options" => options}])
    labels = Enum.map(q["options"], & &1["label"])
    assert labels == Enum.uniq(labels)
    assert Enum.find(q["options"], &(&1["label"] == "A"))["description"] == "first"
  end

  test "caps the overall list at 4 questions" do
    valid = %{
      "question" => "Q",
      "header" => "H",
      "options" => [%{"label" => "A"}, %{"label" => "B"}]
    }

    assert length(AskQuestion.normalize(List.duplicate(valid, 6))) == 4
  end

  test "multiSelect normalizes truthy representations, defaults to false" do
    base = %{
      "question" => "Q",
      "header" => "H",
      "options" => [%{"label" => "A"}, %{"label" => "B"}]
    }

    assert [%{"multiSelect" => true}] =
             AskQuestion.normalize([Map.put(base, "multiSelect", "true")])

    assert [%{"multiSelect" => true}] = AskQuestion.normalize([Map.put(base, "multiSelect", 1)])
    assert [%{"multiSelect" => false}] = AskQuestion.normalize([base])

    assert [%{"multiSelect" => false}] =
             AskQuestion.normalize([Map.put(base, "multiSelect", "nope")])
  end

  test "a missing description defaults to an empty string" do
    base = %{
      "question" => "Q",
      "header" => "H",
      "options" => [%{"label" => "A"}, %{"label" => "B"}]
    }

    [q] = AskQuestion.normalize([base])
    assert Enum.all?(q["options"], &(&1["description"] == ""))
  end

  test "non-list input returns an empty list" do
    assert AskQuestion.normalize(nil) == []
    assert AskQuestion.normalize(%{}) == []
  end
end
