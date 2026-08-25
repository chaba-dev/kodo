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

  @contracts %{
    primary: %{1 => @primary_v1, 2 => @primary_v2},
    search: %{1 => @search_v1, 2 => @search_v2},
    review: %{1 => @review_v1, 2 => @review_v2}
  }
  @current_versions %{primary: 2, search: 2, review: 2}

  @type role :: :primary | :search | :review

  @spec all() :: %{role() => map()}
  def all, do: Map.new(@current_versions, fn {role, version} -> {role, fetch!(role, version)} end)

  @spec fetch!(role()) :: map()
  def fetch!(role), do: fetch!(role, Map.fetch!(@current_versions, role))

  @spec fetch!(role(), pos_integer()) :: map()
  def fetch!(role, version), do: @contracts |> Map.fetch!(role) |> Map.fetch!(version)
end
