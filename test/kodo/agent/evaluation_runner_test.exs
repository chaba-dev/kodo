defmodule Kodo.Agent.EvaluationRunnerTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.EvaluationRunner

  test "evaluation runs require an explicit authenticated user scope" do
    scope = %Kodo.Accounts.Scope{user: %Kodo.Accounts.User{id: 123}}
    suite = %{"name" => "empty", "version" => 1, "tasks" => []}

    report = EvaluationRunner.run(scope, suite: suite)

    assert report["suite"]["name"] == "empty"
    assert report["tasks"] == []
    refute function_exported?(EvaluationRunner, :run, 0)
  end

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

  test "workspace search defaults empty paths to the workspace root" do
    root = Path.join(System.tmp_dir!(), "kodo-eval-search-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/example.ex"), "def health, do: :ok\n")

    on_exit(fn -> File.rm_rf!(root) end)

    assert %{"matches" => matches} =
             EvaluationRunner.search_workspace(root, %{"query" => "health", "paths" => []})

    assert matches =~ "lib/example.ex:1:def health"

    assert %{"matches" => matches} =
             EvaluationRunner.search_workspace(root, %{"query" => "health", "paths" => [""]})

    assert matches =~ "lib/example.ex:1:def health"
  end

  test "workspace replacement requires one exact match" do
    root = Path.join(System.tmp_dir!(), "kodo-eval-replace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    path = Path.join(root, "lib/example.ex")
    File.write!(path, "before\n")

    on_exit(fn -> File.rm_rf!(root) end)

    assert %{"changed" => true, "path" => "lib/example.ex"} =
             EvaluationRunner.replace_text(root, %{
               "path" => "lib/example.ex",
               "old_text" => "before",
               "new_text" => "after"
             })

    assert File.read!(path) == "after\n"

    assert %{"error" => "old_text must match exactly once"} =
             EvaluationRunner.replace_text(root, %{
               "path" => "lib/example.ex",
               "old_text" => "missing",
               "new_text" => "replacement"
             })

    File.write!(path, "duplicate duplicate\n")

    assert %{"error" => "old_text must match exactly once"} =
             EvaluationRunner.replace_text(root, %{
               "path" => "lib/example.ex",
               "old_text" => "duplicate",
               "new_text" => "replacement"
             })
  end

  test "workspace reads use the runner's line-based offset contract" do
    root = Path.join(System.tmp_dir!(), "kodo-eval-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "example.txt"), "one\ntwo\nthree\n")

    on_exit(fn -> File.rm_rf!(root) end)

    assert %{
             "content" => "two",
             "offset" => 1,
             "next_offset" => 2,
             "truncated" => true
           } =
             EvaluationRunner.read_file(root, %{
               "path" => "example.txt",
               "offset" => 1,
               "limit" => 1
             })

    assert %{
             "content" => "three",
             "offset" => 2,
             "next_offset" => nil,
             "truncated" => false
           } =
             EvaluationRunner.read_file(root, %{
               "path" => "example.txt",
               "offset" => 2,
               "limit" => 2
             })
  end

  test "workspace commands accept the root's equivalent dot-slash cwd" do
    root = Path.join(System.tmp_dir!(), "kodo-eval-command-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    assert %{"status" => 0, "output" => "verified"} =
             EvaluationRunner.run_command(
               root,
               %{"command" => "printf verified", "cwd" => "./", "timeout_ms" => 1_000},
               ["printf verified"]
             )
  end

  test "evaluation turns advertise only tools the synchronous harness supports" do
    names =
      EvaluationRunner.tool_definitions_for_turn("workspace-v4", 1, 8)
      |> Enum.map(& &1.name)

    assert "start_command" in names
    refute "poll_command" in names
    refute "stop_command" in names
  end

  test "correction prompts retain the original task and exact verification command" do
    task = %{
      "prompt" => "Fix add/2.",
      "expected" => %{"allowed_paths" => ["lib/calc.ex"]}
    }

    prompt =
      EvaluationRunner.correction_prompt(task, ["elixir -r lib/calc.ex test/public_test.exs"], [
        %{"path" => "lib/calc.ex", "line" => 2}
      ])

    assert prompt =~ "Fix add/2."
    assert prompt =~ "Only modify: lib/calc.ex"
    assert prompt =~ "elixir -r lib/calc.ex test/public_test.exs"
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
