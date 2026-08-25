defmodule Kodo.Agent.ReviewResultTest do
  use ExUnit.Case, async: true

  alias Kodo.Agent.ReviewResult

  test "keeps only actionable findings anchored to the diff" do
    object = %{
      "clean" => false,
      "findings" => [
        finding("lib/example.ex", "Change the return value."),
        finding("lib/example.ex", "No change needed; the code is correct."),
        finding("lib/missing.ex", "Change unrelated code.")
      ]
    }

    diff =
      "diff --git a/lib/example.ex b/lib/example.ex\n--- a/lib/example.ex\n+++ b/lib/example.ex\n"

    assert %{"clean" => false, "findings" => [finding]} =
             ReviewResult.actionable(object, diff)

    assert finding["suggested_fix"] == "Change the return value."
  end

  test "marks a review clean when every finding is rejected" do
    object = %{
      "clean" => false,
      "findings" => [finding("lib/example.ex", "No changes are needed.")]
    }

    assert ReviewResult.actionable(object, "diff --git a/lib/example.ex b/lib/example.ex\n") ==
             %{"clean" => true, "findings" => []}
  end

  defp finding(path, suggested_fix) do
    %{
      "severity" => "high",
      "path" => path,
      "line" => 1,
      "explanation" => "Explanation",
      "suggested_fix" => suggested_fix
    }
  end
end
