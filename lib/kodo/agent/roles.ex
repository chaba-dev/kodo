defmodule Kodo.Agent.Roles do
  @moduledoc "Versioned contracts for Kodo's model-backed agent roles."

  @primary_v1 %{
    version: 1,
    responsibility: :own_task,
    prompt:
      "You are Kodo's primary coding agent. Inspect evidence, make the smallest correct patch, and verify it.",
    tools: :workspace,
    toolset_version: "workspace-v1",
    budget: %{max_continuations: 8, max_tokens: 100_000},
    output: :final_answer
  }
  @search_v1 %{
    version: 1,
    responsibility: :investigate_codebase,
    prompt:
      "Investigate the requested codebase question using read-only tools. Return concise findings supported by file and line evidence.",
    tools: :read_only,
    toolset_version: "read-only-v1",
    budget: %{max_continuations: 4, max_tokens: 30_000},
    output: :evidence
  }
  @review_v1 %{
    version: 1,
    responsibility: :review_final_diff,
    prompt:
      "Review the supplied final diff for correctness and regressions. Report only supported findings with severity, location, explanation, and a suggested fix; a clean review is valid.",
    tools: :read_only,
    toolset_version: "read-only-v1",
    budget: %{max_continuations: 2, max_tokens: 30_000},
    output: :review_findings
  }

  @primary_v2 Map.put(@primary_v1, :version, 2)
              |> Map.put(:capabilities, %{
                tools: true,
                structured_output: false,
                min_context: 100_000,
                input_modalities: [:text]
              })
  @search_v2 Map.put(@search_v1, :version, 2)
             |> Map.put(:capabilities, %{
               tools: true,
               structured_output: false,
               min_context: 30_000,
               input_modalities: [:text]
             })
  @review_v2 Map.put(@review_v1, :version, 2)
             |> Map.put(:capabilities, %{
               tools: true,
               structured_output: :json_schema,
               min_context: 30_000,
               input_modalities: [:text]
             })

  @review_v3 @review_v2
             |> Map.put(:version, 3)
             |> Map.put(
               :prompt,
               "Review the supplied original task and final diff for actionable defects introduced by the diff. Report only a change that must be made to restore correctness or prevent a regression, with severity, location, explanation, and a concrete suggested fix. Do not report a correct change, summarize the diff as a finding, or emit a finding whose suggested fix says no change is needed. Set clean=true if and only if findings is empty."
             )

  @review_v4 @review_v3
             |> Map.put(:version, 4)
             |> Map.put(
               :prompt,
               "Review the supplied original task and final diff for actionable defects introduced by the diff. The original task is authoritative: a diff that implements its requested behavior is not a defect. Never recommend reverting required behavior. Report only a concrete correctness failure or regression visible in the diff, with severity, location, explanation, and a fix that changes code. Do not report speculation, optional improvements, performance concerns without evidence, correct code, or a finding whose suggested fix says no change is needed. Set clean=true if and only if findings is empty."
             )

  @review_v5 @review_v4
             |> Map.put(:version, 5)
             |> put_in([:capabilities, :structured_output], :object)

  @primary_v3 @primary_v2
              |> Map.put(:version, 3)
              |> Map.put(:toolset_version, "workspace-v2")

  @primary_v4 @primary_v3
              |> Map.put(:version, 4)
              |> Map.put(:toolset_version, "workspace-v3")
              |> Map.put(
                :prompt,
                "You are Kodo's primary coding agent. Inspect evidence, make the smallest correct patch, and verify it. apply_patch accepts only a complete git unified diff with diff --git, ---, +++, and @@ hunk headers; never send replacement text alone. Batch independent tool calls when useful and leave enough budget to verify and summarize."
              )

  @primary_v5 @primary_v4
              |> Map.put(:version, 5)
              |> Map.put(:toolset_version, "workspace-v4")
              |> Map.put(
                :prompt,
                "You are Kodo's primary coding agent. Inspect evidence, make the smallest correct change, and verify it. Prefer replace_text for exact edits to existing files; old_text must occur exactly once. Use apply_patch for changes replace_text cannot express, and provide a complete git unified diff with correct diff --git, ---, +++, and @@ hunk counts. Batch independent tool calls when useful and leave enough budget to verify and summarize."
              )

  @primary_v6 @primary_v5
              |> Map.put(:version, 6)
              |> Map.put(:toolset_version, "workspace-v5")
              |> Map.put(
                :prompt,
                "You are Kodo's primary coding agent. Inspect the complete target file, make the smallest correct change with replace_text, and verify it. Use the exact public verification command from the task with cwd '.'. After every edit, reread the changed file and run that exact command; if either exposes an error, fix it before doing anything else. Do not substitute mix commands or invent working directories. Treat review feedback as a claim: inspect the current file and preserve behavior required by the original task before changing code. Leave enough budget to verify and summarize."
              )

  @search_v3 @search_v2
             |> Map.put(:version, 3)
             |> Map.put(:budget, %{max_continuations: 6, max_tokens: 30_000})
             |> Map.put(
               :prompt,
               "Investigate the requested codebase question using read-only tools. You have at most six model turns: batch independent tool calls and reserve the final turn for a concise answer supported by file and line evidence."
             )

  @contracts %{
    primary: %{
      1 => @primary_v1,
      2 => @primary_v2,
      3 => @primary_v3,
      4 => @primary_v4,
      5 => @primary_v5,
      6 => @primary_v6
    },
    search: %{1 => @search_v1, 2 => @search_v2, 3 => @search_v3},
    review: %{
      1 => @review_v1,
      2 => @review_v2,
      3 => @review_v3,
      4 => @review_v4,
      5 => @review_v5
    }
  }
  @current_versions %{primary: 6, search: 3, review: 5}

  @type role :: :primary | :search | :review

  @spec all() :: %{role() => map()}
  def all, do: Map.new(@current_versions, fn {role, version} -> {role, fetch!(role, version)} end)

  @spec fetch!(role()) :: map()
  def fetch!(role), do: fetch!(role, Map.fetch!(@current_versions, role))

  @spec fetch!(role(), pos_integer()) :: map()
  def fetch!(role, version), do: @contracts |> Map.fetch!(role) |> Map.fetch!(version)
end
