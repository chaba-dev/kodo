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
    assert is_map(catalog["rubrics"])
    assert map_size(catalog["rubrics"]) > 0
    assert Map.has_key?(catalog["standards"], catalog["current_standard"])
    assert catalog["suites"] != []
    assert File.exists?(Path.join(__DIR__, "README.adoc"))

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

  test "behavior rubrics define observable weighted dimensions", %{catalog: catalog} do
    Enum.each(catalog["rubrics"], fn {_name, rubric} ->
      dimensions = rubric["dimensions"]
      ids = Enum.map(dimensions, & &1["id"])

      assert rubric["description"] != ""
      assert Map.keys(rubric["scoring"]) |> Enum.sort() == ["0", "0.5", "1"]
      assert rubric["aggregation"]["method"] == "weighted_mean"
      assert rubric["aggregation"]["episode_target"] > 0
      assert rubric["aggregation"]["episode_target"] <= 1
      assert dimensions != []
      assert length(ids) == MapSet.size(MapSet.new(ids))

      Enum.each(dimensions, fn dimension ->
        assert dimension["description"] != ""
        assert dimension["observable"] != ""
        assert dimension["weight"] > 0
        assert dimension["target"] > 0
        assert dimension["target"] <= 1
        assert is_boolean(dimension["critical"])
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
    reference_path = Path.join(Path.dirname(contract_path), "README.adoc")
    criteria = standard["criteria"]
    criterion_ids = MapSet.new(criteria, & &1["id"])
    threshold_ids = contract["regression_thresholds"] |> Map.keys() |> MapSet.new()

    assert File.exists?(reference_path)
    assert contract["version"] == 1
    assert contract["suite"] == entry["name"]
    assert contract["suite"] == baseline["suite"]["name"]
    assert contract["suite_fingerprint"] == baseline["suite"]["fingerprint"]
    assert criterion_ids == threshold_ids
    assert_recorded_candidates(contract, contract_path, baseline["metrics"]["task_count"])

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

  defp assert_recorded_candidates(contract, contract_path, task_count) do
    Enum.each(contract["candidate_results"] || [], fn result_path ->
      result =
        result_path
        |> Path.expand(Path.dirname(contract_path))
        |> File.read!()
        |> Jason.decode!()

      assert result["suite"]["name"] == contract["suite"]
      assert result["suite"]["fingerprint"] == contract["suite_fingerprint"]
      assert result["metrics"]["task_count"] == task_count
      assert length(result["tasks"]) == task_count
    end)
  end

  defp target_improves_on_threshold?(%{"direction" => "minimum", "target" => target}, threshold),
    do: target >= threshold

  defp target_improves_on_threshold?(%{"direction" => "maximum", "target" => target}, threshold),
    do: target <= threshold

  defp meets_threshold?(value, "minimum", threshold), do: value >= threshold
  defp meets_threshold?(value, "maximum", threshold), do: value <= threshold
end
