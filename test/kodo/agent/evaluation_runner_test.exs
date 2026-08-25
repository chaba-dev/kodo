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

  test "workspace search defaults an empty path list to the workspace root" do
    root = Path.join(System.tmp_dir!(), "kodo-eval-search-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/example.ex"), "def health, do: :ok\n")

    on_exit(fn -> File.rm_rf!(root) end)

    assert %{"matches" => matches} =
             EvaluationRunner.search_workspace(root, %{"query" => "health", "paths" => []})

    assert matches =~ "lib/example.ex:1:def health"
  end

  test "aggregate records quality, latency, usage, cost availability, and failure rate" do
    tasks = [
      %{
        "type" => "search",
        "latency_ms" => 10,
        "usage" => %{total_tokens: 20},
        "estimated_cost_usd" => 0.01,
        "metrics" => %{
          "relevant_file_recall" => 1.0,
          "evidence_citation_recall" => 0.5,
          "irrelevant_files" => 1
        }
      },
      %{"type" => "review", "latency_ms" => 30, "usage" => %{}, "error" => "failed"}
    ]

    aggregate = EvaluationRunner.aggregate(tasks)

    assert aggregate["failure_rate"] == 0.5
    assert aggregate["latency_ms"] == %{"total" => 40, "mean" => 20.0, "p95" => 30}
    assert aggregate["usage"] == %{total_tokens: 20}
    assert aggregate["estimated_cost_usd"] == 0.01
    assert aggregate["quality"]["search"]["relevant_file_recall"] == 1.0
  end
end
