defmodule Kodo.EvaluationBenchmarkTest do
  use ExUnit.Case, async: true

  @criteria_path Path.join(__DIR__, "mvp-v1/criteria.json")

  setup_all do
    criteria = @criteria_path |> File.read!() |> Jason.decode!()
    baseline_path = Path.expand(criteria["baseline_result"], Path.dirname(@criteria_path))
    baseline = baseline_path |> File.read!() |> Jason.decode!()

    %{criteria: criteria, baseline: baseline}
  end

  test "criteria define valid regression thresholds and improvement targets", %{
    criteria: artifact,
    baseline: baseline
  } do
    assert artifact["version"] == 1
    assert artifact["suite"] == baseline["suite"]["name"]
    assert artifact["suite_fingerprint"] == baseline["suite"]["fingerprint"]

    criteria = artifact["criteria"]
    ids = Enum.map(criteria, & &1["id"])

    assert criteria != []
    assert length(ids) == MapSet.size(MapSet.new(ids))

    Enum.each(criteria, fn criterion ->
      assert criterion["description"] != ""
      assert criterion["direction"] in ["minimum", "maximum"]
      assert is_number(criterion["regression_threshold"])
      assert is_number(criterion["target"])
      assert is_number(get_in(baseline, criterion["metric_path"]))
      assert target_improves_on_threshold?(criterion)
    end)
  end

  test "accepted baseline meets every regression threshold", %{
    criteria: artifact,
    baseline: baseline
  } do
    Enum.each(artifact["criteria"], fn criterion ->
      value = get_in(baseline, criterion["metric_path"])

      assert meets_threshold?(value, criterion),
             "#{criterion["id"]} value #{value} does not meet " <>
               "#{criterion["direction"]} threshold #{criterion["regression_threshold"]}"
    end)
  end

  defp target_improves_on_threshold?(%{
         "direction" => "minimum",
         "regression_threshold" => threshold,
         "target" => target
       }),
       do: target >= threshold

  defp target_improves_on_threshold?(%{
         "direction" => "maximum",
         "regression_threshold" => threshold,
         "target" => target
       }),
       do: target <= threshold

  defp meets_threshold?(value, %{"direction" => "minimum", "regression_threshold" => threshold}),
    do: value >= threshold

  defp meets_threshold?(value, %{"direction" => "maximum", "regression_threshold" => threshold}),
    do: value <= threshold
end
