defmodule Mix.Tasks.Kodo.Eval.Validate do
  @moduledoc "Validates and fingerprints Kodo's pinned MVP evaluation suite."

  use Mix.Task

  @shortdoc "Validates and fingerprints the pinned MVP evaluation suite"

  @impl true
  def run(_args) do
    suite = Kodo.Agent.EvaluationSuite.load!()
    counts = Enum.frequencies_by(suite["tasks"], & &1["type"])

    Mix.shell().info(
      "#{suite["name"]}: #{map_size(counts)} roles, #{length(suite["tasks"])} tasks, " <>
        "sha256:#{Kodo.Agent.EvaluationSuite.fingerprint(suite)}"
    )
  end
end
