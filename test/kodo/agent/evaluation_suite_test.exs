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

  test "hidden implementation checks execute the hidden test file" do
    task = Enum.find(EvaluationSuite.load!()["tasks"], &(&1["id"] == "implementation-05"))
    root = Path.join(System.tmp_dir!(), "kodo-suite-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    task["fixture"]["files"]
    |> Map.merge(task["fixture"]["hidden_files"])
    |> Enum.each(fn {path, body} ->
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, body)
    end)

    [executable | args] = OptionParser.split(hd(task["expected"]["hidden_checks"]))
    {output, status} = System.cmd(executable, args, cd: root, stderr_to_stdout: true)

    assert status != 0
    assert output =~ "test low (HiddenTest)"
    assert output =~ "1/2 passed"
  end
end
