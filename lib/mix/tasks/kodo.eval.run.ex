defmodule Mix.Tasks.Kodo.Eval.Run do
  @moduledoc "Runs the pinned live MVP evaluation suite."
  @shortdoc "Run the pinned Kodo live evaluation"
  use Mix.Task

  alias Kodo.Accounts
  alias Kodo.Accounts.Scope
  alias Kodo.Agent.EvaluationRunner

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [output: :string, user_email: :string])

    if rest != [] or invalid != [] or is_nil(opts[:output]) or is_nil(opts[:user_email]) do
      Mix.raise("usage: mix kodo.eval.run --output PATH --user-email EMAIL")
    end

    Mix.Task.run("app.start")
    user = Accounts.get_user_by_email(opts[:user_email]) || Mix.raise("evaluation user not found")
    scope = Scope.for_user(user)
    output = Path.expand(opts[:output])
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, Jason.encode!(EvaluationRunner.run(scope), pretty: true))
    Mix.shell().info("Evaluation report written to #{output}")
  end
end
