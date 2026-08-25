defmodule Mix.Tasks.Kodo.Eval.Run do
  @moduledoc "Runs the pinned live MVP evaluation suite."
  @shortdoc "Run the pinned Kodo live evaluation"
  use Mix.Task

  alias Kodo.Agent.EvaluationRunner

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])

    if rest != [] or invalid != [] or is_nil(opts[:output]) do
      Mix.raise("usage: mix kodo.eval.run --output PATH")
    end

    {:ok, _applications} = Application.ensure_all_started(:req_llm)
    output = Path.expand(opts[:output])
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode!(EvaluationRunner.run(), pretty: true))
    Mix.shell().info("Evaluation report written to #{output}")
  end
end
