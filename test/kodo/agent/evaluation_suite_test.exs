defmodule Kodo.Agent.EvaluationSuiteTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.EvaluationSuite

  test "loads ten pinned tasks for each MVP role" do
    suite = EvaluationSuite.load!()

    assert suite["name"] == "mvp-v1"

    assert Enum.frequencies_by(suite["tasks"], & &1["type"]) == %{
             "implementation" => 10,
             "review" => 10,
             "search" => 10
           }

    assert EvaluationSuite.fingerprint(suite) =~ ~r/^[0-9a-f]{64}$/
  end

  test "rejects duplicate or incomplete task sets" do
    suite = EvaluationSuite.load!()
    [first | rest] = suite["tasks"]

    assert_raise ArgumentError, fn ->
      EvaluationSuite.validate!(%{suite | "tasks" => [first, first | rest]})
    end

    assert_raise ArgumentError, fn ->
      EvaluationSuite.validate!(%{suite | "tasks" => rest})
    end
  end
end
