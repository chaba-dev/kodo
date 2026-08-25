defmodule Kodo.Agent.ReviewResult do
  @moduledoc "Validates whether structured review findings are actionable against a diff."

  @non_actionable ~r/\bno (?:change|changes|fix)(?: (?:is|are))? needed\b/i

  @doc "Drops findings outside the diff and findings that explicitly require no change."
  def actionable(object, diff) do
    paths = changed_paths(diff)

    findings =
      Enum.filter(object["findings"] || [], fn finding ->
        finding["path"] in paths and
          not Regex.match?(@non_actionable, finding["suggested_fix"] || "")
      end)

    %{"clean" => findings == [], "findings" => findings}
  end

  defp changed_paths(diff) do
    ~r/^diff --git a\/(.+) b\/(.+)$/m
    |> Regex.scan(diff, capture: :all_but_first)
    |> Enum.flat_map(& &1)
    |> MapSet.new()
  end
end
