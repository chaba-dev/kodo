defmodule Kodo.Agent.Roles do
  @moduledoc "Prerelease contracts for Kodo's model-backed agent roles."

  @contract_id "alpha-v1"
  @contracts %{
    primary: %{
      id: @contract_id,
      responsibility: :own_task,
      prompt:
        "You are Kodo's primary coding agent. Inspect the complete target file, make the smallest correct change with replace_text, and verify it. Use the exact public verification command from the task with cwd '.'. After every edit, reread the changed file and run that exact command; if either exposes an error, fix it before doing anything else. Do not substitute mix commands or invent working directories. Treat review feedback as a claim: inspect the current file and preserve behavior required by the original task before changing code. Leave enough budget to verify and summarize.",
      tools: :workspace,
      toolset_version: "workspace-v5",
      budget: %{max_continuations: 8, max_tokens: 100_000},
      output: :final_answer,
      capabilities: %{
        tools: true,
        structured_output: false,
        min_context: 100_000,
        input_modalities: [:text]
      }
    },
    search: %{
      id: @contract_id,
      responsibility: :investigate_codebase,
      prompt:
        "Investigate the requested codebase question using read-only tools. You have at most six model turns: batch independent tool calls and reserve the final turn for a concise answer supported by file and line evidence.",
      tools: :read_only,
      toolset_version: "read-only-v1",
      budget: %{max_continuations: 6, max_tokens: 30_000},
      output: :evidence,
      capabilities: %{
        tools: true,
        structured_output: false,
        min_context: 30_000,
        input_modalities: [:text]
      }
    },
    review: %{
      id: @contract_id,
      responsibility: :review_final_diff,
      prompt:
        "Review the supplied original task and final diff for actionable defects introduced by the diff. The original task is authoritative: a diff that implements its requested behavior is not a defect. Never recommend reverting required behavior. Report only a concrete correctness failure or regression visible in the diff, with severity, location, explanation, and a fix that changes code. Do not report speculation, optional improvements, performance concerns without evidence, correct code, or a finding whose suggested fix says no change is needed. Set clean=true if and only if findings is empty.",
      tools: :read_only,
      toolset_version: "read-only-v1",
      budget: %{max_continuations: 2, max_tokens: 30_000},
      output: :review_findings,
      capabilities: %{
        tools: true,
        structured_output: :object,
        min_context: 30_000,
        input_modalities: [:text]
      }
    }
  }

  @type role :: :primary | :search | :review
  @type contract_id :: String.t()

  @spec all() :: %{role() => map()}
  def all, do: @contracts

  @spec fetch!(role()) :: map()
  def fetch!(role), do: Map.fetch!(@contracts, role)

  @spec fetch!(role(), contract_id()) :: map()
  def fetch!(role, contract_id) do
    contract = fetch!(role)

    if contract.id == contract_id do
      contract
    else
      raise KeyError, key: contract_id, term: %{role => contract.id}
    end
  end
end
