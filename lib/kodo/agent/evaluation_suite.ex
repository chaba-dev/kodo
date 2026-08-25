defmodule Kodo.Agent.EvaluationSuite do
  @moduledoc "Loads and validates the pinned MVP evaluation-suite artifact."

  @suite_path Path.expand("../../../test/evals/mvp-v1/suite.json", __DIR__)
  @external_resource @suite_path
  @task_types ~w(search review implementation)
  @tasks_per_type 10

  def load! do
    suite = @suite_path |> File.read!() |> Jason.decode!()
    validate!(suite)
  end

  def validate!(%{"version" => 1, "name" => name, "tasks" => tasks} = suite)
      when is_binary(name) and is_list(tasks) do
    ids = Enum.map(tasks, & &1["id"])

    unless length(tasks) == @tasks_per_type * length(@task_types) and
             length(ids) == MapSet.size(MapSet.new(ids)) and
             Enum.all?(@task_types, &(task_count(tasks, &1) == @tasks_per_type)) and
             Enum.all?(tasks, &valid_task?/1) do
      raise ArgumentError, "invalid MVP evaluation suite"
    end

    suite
  end

  def validate!(_suite), do: raise(ArgumentError, "invalid MVP evaluation suite")

  def fingerprint(suite \\ load!()) do
    suite
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp task_count(tasks, type), do: Enum.count(tasks, &(&1["type"] == type))

  defp valid_task?(%{"id" => id, "type" => type, "prompt" => prompt} = task) do
    is_binary(id) and id != "" and type in @task_types and is_binary(prompt) and prompt != "" and
      valid_task_contract?(type, task)
  end

  defp valid_task?(_task), do: false

  defp valid_task_contract?("search", %{
         "fixture" => %{"files" => files},
         "expected" => %{"relevant_files" => relevant, "evidence" => evidence}
       }),
       do: nonempty_map?(files) and nonempty_strings?(relevant) and evidence != []

  defp valid_task_contract?("review", %{
         "fixture" => %{"diff" => diff},
         "expected" => %{"clean" => clean, "findings" => findings}
       }),
       do: is_binary(diff) and diff != "" and is_boolean(clean) and is_list(findings)

  defp valid_task_contract?("implementation", %{
         "fixture" => %{"files" => files, "hidden_files" => hidden_files},
         "expected" => %{
           "allowed_paths" => allowed_paths,
           "public_checks" => public_checks,
           "hidden_checks" => hidden_checks,
           "prohibited_actions" => prohibited_actions
         }
       }) do
    nonempty_map?(files) and nonempty_map?(hidden_files) and nonempty_strings?(allowed_paths) and
      nonempty_strings?(public_checks) and nonempty_strings?(hidden_checks) and
      nonempty_strings?(prohibited_actions)
  end

  defp valid_task_contract?(_type, _task), do: false

  defp nonempty_map?(value), do: is_map(value) and map_size(value) > 0

  defp nonempty_strings?(values),
    do: is_list(values) and values != [] and Enum.all?(values, &is_binary/1)
end
