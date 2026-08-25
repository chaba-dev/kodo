defmodule Kodo.Agent.EvaluationRunnerTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.EvaluationRunner

  test "search scoring is deterministic and penalizes irrelevant files" do
    expected = %{
      "relevant_files" => ["lib/a.ex"],
      "evidence" => [%{"path" => "lib/a.ex", "line" => 2, "contains" => "needle"}]
    }

    metrics =
      EvaluationRunner.score_search("lib/a.ex:2 needle; see README.md", expected, [
        "lib/a.ex",
        "README.md"
      ])

    assert metrics == %{
             "relevant_file_recall" => 1.0,
             "irrelevant_files" => 1,
             "evidence_citation_recall" => 1.0
           }
  end

  test "review scoring measures recall, severity, location, and false positives" do
    expected = %{"findings" => [%{"severity" => "high", "path" => "lib/a.ex", "line" => 4}]}

    object = %{
      "findings" => [
        %{"severity" => "medium", "path" => "lib/a.ex", "line" => 4},
        %{"severity" => "low", "path" => "lib/b.ex", "line" => 1}
      ]
    }

    assert EvaluationRunner.score_review(object, expected) == %{
             "defect_recall" => 1.0,
             "false_positives" => 1,
             "severity_accuracy" => 0.0,
             "location_accuracy" => 1.0
           }
  end
end
