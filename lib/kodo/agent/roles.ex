defmodule Kodo.Agent.Roles do
  @moduledoc "Versioned contracts for Kodo's model-backed agent roles."

  @contracts %{
    primary: %{
      version: 1,
      responsibility: :own_task,
      prompt:
        "You are Kodo's primary coding agent. Inspect evidence, make the smallest correct patch, and verify it.",
      tools: :workspace,
      budget: %{max_continuations: 8, max_tokens: 100_000},
      output: :final_answer
    },
    search: %{
      version: 1,
      responsibility: :investigate_codebase,
      prompt:
        "Investigate the requested codebase question using read-only tools. Return concise findings supported by file and line evidence.",
      tools: :read_only,
      budget: %{max_continuations: 4, max_tokens: 30_000},
      output: :evidence
    },
    review: %{
      version: 1,
      responsibility: :review_final_diff,
      prompt:
        "Review the supplied final diff for correctness and regressions. Report only supported findings with severity, location, explanation, and a suggested fix; a clean review is valid.",
      tools: :read_only,
      budget: %{max_continuations: 2, max_tokens: 30_000},
      output: :review_findings
    }
  }

  @type role :: :primary | :search | :review

  @spec all() :: %{role() => map()}
  def all, do: @contracts

  @spec fetch!(role()) :: map()
  def fetch!(role), do: Map.fetch!(@contracts, role)
end
