defmodule Kodo.EvaluationBenchmarkTest do
  use ExUnit.Case, async: true

  @catalog_path Path.join(__DIR__, "criteria.json")

  setup_all do
    catalog = @catalog_path |> File.read!() |> Jason.decode!()
    %{catalog: catalog}
  end

  test "catalog preserves versioned benchmark standards", %{catalog: catalog} do
    assert catalog["schema_version"] == 1
    assert is_map(catalog["standards"])
    assert map_size(catalog["standards"]) > 0
    assert Map.has_key?(catalog["standards"], catalog["current_standard"])
    assert catalog["suites"] != []

    Enum.each(catalog["standards"], fn {_name, standard} ->
      criteria = standard["criteria"]
      ids = Enum.map(criteria, & &1["id"])

      assert criteria != []
      assert length(ids) == MapSet.size(MapSet.new(ids))

      Enum.each(criteria, fn criterion ->
        assert criterion["description"] != ""
        assert criterion["direction"] in ["minimum", "maximum"]
        assert is_list(criterion["metric_path"])
        assert criterion["metric_path"] != []
        assert is_number(criterion["target"])
      end)
    end)
  end

  test "registered suite baselines meet their regression thresholds", %{catalog: catalog} do
    Enum.each(catalog["suites"], &assert_suite_meets_thresholds(&1, catalog))
  end

  defp assert_suite_meets_thresholds(entry, catalog) do
    contract_path = Path.expand(entry["criteria"], __DIR__)
    contract = contract_path |> File.read!() |> Jason.decode!()
    standard = Map.fetch!(catalog["standards"], contract["standard"])
    baseline_path = Path.expand(contract["baseline_result"], Path.dirname(contract_path))
    baseline = baseline_path |> File.read!() |> Jason.decode!()
    criteria = standard["criteria"]
    criterion_ids = MapSet.new(criteria, & &1["id"])
    threshold_ids = contract["regression_thresholds"] |> Map.keys() |> MapSet.new()

    assert contract["version"] == 1
    assert contract["suite"] == entry["name"]
    assert contract["suite"] == baseline["suite"]["name"]
    assert contract["suite_fingerprint"] == baseline["suite"]["fingerprint"]
    assert criterion_ids == threshold_ids

    Enum.each(criteria, fn criterion ->
      value = get_in(baseline, criterion["metric_path"])
      threshold = Map.fetch!(contract["regression_thresholds"], criterion["id"])

      assert is_number(value)
      assert is_number(threshold)
      assert target_improves_on_threshold?(criterion, threshold)

      assert meets_threshold?(value, criterion["direction"], threshold),
             "#{contract["suite"]} #{criterion["id"]} value #{value} does not meet " <>
               "#{criterion["direction"]} threshold #{threshold}"
    end)
  end

  defp target_improves_on_threshold?(%{"direction" => "minimum", "target" => target}, threshold),
    do: target >= threshold

  defp target_improves_on_threshold?(%{"direction" => "maximum", "target" => target}, threshold),
    do: target <= threshold

  defp meets_threshold?(value, "minimum", threshold), do: value >= threshold
  defp meets_threshold?(value, "maximum", threshold), do: value <= threshold
end
