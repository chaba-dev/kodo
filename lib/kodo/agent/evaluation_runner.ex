defmodule Kodo.Agent.EvaluationRunner do
  @moduledoc "Runs the pinned MVP evaluation suite against a live LLM adapter."

  alias Kodo.Agent.{EvaluationSuite, ModelMapping, ReviewResult, Roles, Tools}
  alias Kodo.Accounts.Scope
  alias Kodo.LLM

  @timeout 120_000
  @max_output 32_000

  @doc "Runs every task and returns a JSON-safe report. Errors are isolated per task."
  def run(%Scope{} = scope, opts \\ []) do
    started_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    suite = Keyword.get_lazy(opts, :suite, &EvaluationSuite.load!/0)
    adapter = Keyword.get(opts, :adapter, Kodo.LLM.ReqLLM)
    mapping = Keyword.get(opts, :mapping, ModelMapping.balanced())

    tasks = Enum.map(suite["tasks"], &safe_task(&1, scope, adapter, mapping))

    %{
      "run" => %{"started_at" => started_at, "revision" => revision()},
      "suite" => %{
        "name" => suite["name"],
        "version" => suite["version"],
        "fingerprint" => EvaluationSuite.fingerprint(suite)
      },
      "mapping" => mapping,
      "contracts" => contracts(),
      "toolsets" => toolsets(),
      "tasks" => tasks,
      "metrics" => aggregate(tasks)
    }
  end

  @doc false
  def score_search(answer, expected, fixture_paths) do
    relevant = expected["relevant_files"]
    mentioned = Enum.filter(fixture_paths, &String.contains?(answer, &1))
    evidence = expected["evidence"]

    cited =
      Enum.count(evidence, fn item ->
        String.contains?(answer, item["path"]) and
          (String.contains?(answer, ":#{item["line"]}") or
             String.contains?(answer, item["contains"]))
      end)

    %{
      "relevant_file_recall" =>
        ratio(length(mentioned -- (mentioned -- relevant)), length(relevant)),
      "irrelevant_files" => length(mentioned -- relevant),
      "evidence_citation_recall" => ratio(cited, length(evidence))
    }
  end

  @doc false
  def score_review(object, expected) do
    actual = object["findings"] || []
    wanted = expected["findings"]

    matches =
      Enum.count(wanted, fn target ->
        Enum.any?(actual, fn finding ->
          finding["path"] == target["path"] and finding["line"] == target["line"]
        end)
      end)

    severity =
      Enum.count(wanted, fn target ->
        Enum.any?(
          actual,
          &(&1["path"] == target["path"] and &1["severity"] == target["severity"])
        )
      end)

    %{
      "defect_recall" => ratio(matches, length(wanted)),
      "false_positives" => max(length(actual) - matches, 0),
      "severity_accuracy" => ratio(severity, length(wanted)),
      "location_accuracy" => ratio(matches, length(wanted))
    }
  end

  defp safe_task(task, scope, adapter, mapping) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        execute(task, scope, adapter, mapping)
      rescue
        exception -> %{"error" => Exception.message(exception), "trace" => [], "usage" => %{}}
      catch
        kind, reason ->
          %{"error" => Exception.format(kind, reason), "trace" => [], "usage" => %{}}
      end

    estimated_cost =
      get_in(result, ["usage", :total_cost]) || get_in(result, ["usage", "total_cost"])

    result
    |> Map.put("id", task["id"])
    |> Map.put("type", task["type"])
    |> Map.put("estimated_cost_usd", estimated_cost)
    |> Map.put("latency_ms", System.monotonic_time(:millisecond) - started)
  end

  defp execute(%{"type" => "search"} = task, scope, adapter, mapping) do
    with_workspace(task["fixture"]["files"], fn root ->
      role = ModelMapping.role!(mapping, :search)
      contract = Roles.fetch!(:search, role["role_contract"])
      prompt = task["prompt"] <> " Cite each finding as path:line and quote evidence."

      {answer, trace, usage} =
        tool_loop(scope, adapter, role, contract, prompt, root, [], mapping)

      %{
        "answer" => answer,
        "trace" => trace,
        "usage" => usage,
        "metrics" => score_search(answer, task["expected"], Map.keys(task["fixture"]["files"]))
      }
    end)
  end

  defp execute(%{"type" => "review"} = task, scope, adapter, mapping) do
    role = ModelMapping.role!(mapping, :review)
    contract = Roles.fetch!(:review, role["role_contract"])
    messages = messages(contract.prompt, task["prompt"] <> "\n\n" <> task["fixture"]["diff"])
    started = System.monotonic_time(:millisecond)

    {:ok, response} = generate_object(scope, adapter, role, messages, ReviewResult.schema())

    %{
      "object" => response.object,
      "usage" => response.usage || %{},
      "trace" => [%{"kind" => "review", "latency_ms" => elapsed(started)}],
      "metrics" => score_review(response.object, task["expected"])
    }
  end

  defp execute(%{"type" => "implementation"} = task, scope, adapter, mapping) do
    with_workspace(task["fixture"]["files"], fn root ->
      System.cmd("git", ["init", "-q"], cd: root, stderr_to_stdout: true)
      System.cmd("git", ["add", "."], cd: root, stderr_to_stdout: true)

      role = ModelMapping.role!(mapping, :primary)
      contract = Roles.fetch!(:primary, role["role_contract"])
      checks = task["expected"]["public_checks"]
      prompt = implementation_prompt(task, checks)

      {answer, trace, usage} =
        tool_loop(scope, adapter, role, contract, prompt, root, checks, mapping)

      {diff, 0} = System.cmd("git", ["diff", "--no-ext-diff"], cd: root, stderr_to_stdout: true)
      initial_review = structured_review(scope, adapter, mapping, task["prompt"], diff)

      {answer, trace, usage, review} =
        if initial_review.object["clean"] do
          {answer, trace, usage, initial_review}
        else
          correction_prompt =
            correction_prompt(task, checks, initial_review.object["findings"])

          {corrected_answer, correction_trace, correction_usage} =
            tool_loop(
              scope,
              adapter,
              role,
              contract,
              correction_prompt,
              root,
              checks,
              mapping
            )

          {corrected_diff, 0} =
            System.cmd("git", ["diff", "--no-ext-diff"], cd: root, stderr_to_stdout: true)

          corrected_review =
            structured_review(scope, adapter, mapping, task["prompt"], corrected_diff)

          {corrected_answer,
           trace ++
             [%{"kind" => "structured_review", "object" => initial_review.object}] ++
             correction_trace,
           usage |> merge_usage(initial_review.usage) |> merge_usage(correction_usage),
           corrected_review}
        end

      public = run_checks(root, checks)
      materialize(root, task["fixture"]["hidden_files"])
      hidden = run_checks(root, task["expected"]["hidden_checks"])
      changed = changed_paths(root)
      allowed = task["expected"]["allowed_paths"]

      %{
        "answer" => answer,
        "trace" => trace ++ [%{"kind" => "structured_review", "object" => review.object}],
        "usage" => merge_usage(usage, review.usage),
        "review" => review.object,
        "checks" => %{"public" => public, "hidden" => hidden},
        "metrics" => %{
          "public_checks_passed" => Enum.all?(public, & &1["passed"]),
          "hidden_checks_passed" => Enum.all?(hidden, & &1["passed"]),
          "scope_compliant" => changed -- allowed == [],
          "out_of_scope_files" => changed -- allowed,
          "prohibited_actions" => [],
          "review_clean" => review.object["clean"]
        }
      }
    end)
  end

  defp tool_loop(scope, adapter, role, contract, prompt, root, commands, mapping) do
    state = %{
      scope: scope,
      root: root,
      commands: commands,
      history: messages(contract.prompt, prompt),
      trace: [],
      usage: %{},
      mapping: mapping
    }

    loop(adapter, role, contract, state, 0)
  end

  defp loop(adapter, role, contract, state, step) do
    if step >= contract.budget.max_continuations do
      {"", state.trace, state.usage}
    else
      started = System.monotonic_time(:millisecond)

      case generate(
             state.scope,
             adapter,
             role,
             state.history,
             tool_definitions_for_turn(
               contract.toolset_version,
               step + 1,
               contract.budget.max_continuations
             )
           ) do
        {:ok, response} ->
          continue_loop(adapter, role, contract, state, response, started, step)

        {:error, reason} ->
          raise "model request failed: #{inspect(reason)}"
      end
    end
  end

  @doc false
  def tool_definitions_for_turn(version, turn, max_turns) do
    version
    |> Tools.definitions_for_turn(turn, max_turns)
    |> Enum.reject(&(&1.name in ["poll_command", "stop_command"]))
  end

  defp continue_loop(adapter, role, contract, state, response, started, step) do
    entry = %{
      "kind" => "model",
      "step" => step,
      "latency_ms" => elapsed(started),
      "text" => response.text,
      "tool_calls" => json_calls(response.tool_calls),
      "usage" => response.usage || %{}
    }

    state = %{
      state
      | trace: state.trace ++ [entry],
        usage: merge_usage(state.usage, response.usage)
    }

    case response.tool_calls do
      [] -> {response.text, state.trace, state.usage}
      calls -> continue_after_tools(adapter, role, contract, state, response, calls, step)
    end
  end

  defp continue_after_tools(adapter, role, contract, state, response, calls, step) do
    assistant = assistant_message(response, calls)

    {results, tool_trace} = execute_calls(calls, state, adapter)

    state = %{
      state
      | history: state.history ++ [assistant | results],
        trace: state.trace ++ tool_trace
    }

    loop(adapter, role, contract, state, step + 1)
  end

  defp execute_calls(calls, state, adapter) do
    Enum.map_reduce(calls, [], fn call, trace ->
      output =
        if call.name == "delegate_search" do
          delegated_search(
            state.scope,
            adapter,
            state.mapping,
            state.root,
            call.arguments["question"]
          )
        else
          execute_tool(call.name, call.arguments, state.root, state.commands)
        end

      message = %{
        "role" => "tool",
        "tool_call_id" => call.id,
        "name" => call.name,
        "content" => output
      }

      {message, trace ++ [%{"kind" => "tool", "name" => call.name, "output" => output}]}
    end)
  end

  defp execute_tool("list_files", args, root, _), do: list_files(root, args["path"])
  defp execute_tool("read_file", args, root, _), do: read_file(root, args)
  defp execute_tool("search_code", args, root, _), do: search_workspace(root, args)
  defp execute_tool("git_status", _, root, _), do: git(root, ["status", "--short"])

  defp execute_tool("git_diff", args, root, _),
    do: git(root, ["diff", "--"] ++ safe_paths(root, args["paths"]))

  defp execute_tool("apply_patch", args, root, _), do: apply_patch(root, args["patch"])
  defp execute_tool("replace_text", args, root, _), do: replace_text(root, args)
  defp execute_tool("start_command", args, root, commands), do: run_command(root, args, commands)

  defp execute_tool(name, _args, _root, _), do: %{"error" => "unsupported tool #{name}"}

  defp list_files(root, path) do
    case confined(root, path) do
      {:ok, target} ->
        files = if File.dir?(target), do: Path.wildcard(Path.join(target, "**/*")), else: [target]

        %{
          "files" =>
            files
            |> Enum.filter(&File.regular?/1)
            |> Enum.take(500)
            |> Enum.map(&Path.relative_to(&1, root))
        }

      error ->
        error_map(error)
    end
  end

  @doc false
  def read_file(root, args) do
    with {:ok, path} <- confined(root, args["path"]), {:ok, body} <- File.read(path) do
      offset = args["offset"] || 0
      limit = args["limit"] || @max_output
      lines = body |> String.split(~r/\r\n|\n/, trim: false) |> drop_trailing_empty()
      content = lines |> Enum.slice(offset, limit) |> Enum.join("\n")
      next_line = offset + limit

      %{
        "content" => content,
        "offset" => offset,
        "next_offset" => if(next_line < length(lines), do: next_line),
        "truncated" => next_line < length(lines)
      }
    else
      error -> error_map(error)
    end
  end

  defp drop_trailing_empty([]), do: []

  defp drop_trailing_empty(lines),
    do: if(List.last(lines) == "", do: List.delete_at(lines, -1), else: lines)

  @doc false
  def search_workspace(root, args) do
    requested_paths =
      case args["paths"] do
        paths when is_list(paths) and paths != [] -> paths
        _ -> ["."]
      end

    paths =
      case safe_paths(root, requested_paths) do
        [] -> ["."]
        paths -> paths
      end

    {output, _} =
      System.cmd(
        "rg",
        ["--line-number", "--fixed-strings", "--max-count", "100", "--", args["query"] | paths],
        cd: root,
        stderr_to_stdout: true
      )

    %{"matches" => truncate(output)}
  end

  defp apply_patch(root, patch) when byte_size(patch) <= 100_000 do
    patch_path = Path.join(root, ".kodo-eval.patch")
    File.write!(patch_path, patch)

    try do
      case System.cmd("git", ["apply", "--whitespace=nowarn", patch_path],
             cd: root,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          %{"applied" => true, "output" => truncate(output)}

        {output, status} ->
          %{"applied" => false, "status" => status, "output" => truncate(output)}
      end
    after
      File.rm(patch_path)
    end
  end

  defp apply_patch(_root, _patch), do: %{"error" => "patch exceeds limit"}

  @doc false
  def replace_text(root, %{
        "path" => path,
        "old_text" => old_text,
        "new_text" => new_text
      }) do
    with true <- old_text != "",
         {:ok, target} <- confined(root, path),
         {:ok, content} <- File.read(target),
         1 <- content |> :binary.matches(old_text) |> length() do
      File.write!(target, String.replace(content, old_text, new_text, global: false))
      %{"changed" => true, "path" => path}
    else
      false -> %{"error" => "old_text must match exactly once"}
      count when is_integer(count) -> %{"error" => "old_text must match exactly once"}
      {:error, reason} -> %{"error" => inspect(reason)}
    end
  end

  @doc false
  def run_command(root, args, commands) do
    command = String.trim(args["command"] || "")

    if command in commands and args["cwd"] in ["", ".", "./"] do
      [executable | argv] = OptionParser.split(command)
      env = [{"HTTP_PROXY", ""}, {"HTTPS_PROXY", ""}, {"ALL_PROXY", ""}, {"NO_PROXY", "*"}]
      {output, status} = System.cmd(executable, argv, cd: root, env: env, stderr_to_stdout: true)
      %{"status" => status, "output" => truncate(output), "process_id" => nil}
    else
      %{"error" => "command is not an exact public-check allowlist match"}
    end
  end

  defp delegated_search(scope, adapter, mapping, root, question) do
    role = ModelMapping.role!(mapping, :search)
    contract = Roles.fetch!(:search, role["role_contract"])

    {answer, trace, usage} =
      tool_loop(scope, adapter, role, contract, question, root, [], mapping)

    %{"question" => question, "evidence" => answer, "trace" => trace, "usage" => usage}
  end

  defp structured_review(scope, adapter, mapping, task, diff) do
    role = ModelMapping.role!(mapping, :review)
    contract = Roles.fetch!(:review, role["role_contract"])

    {:ok, response} =
      generate_object(
        scope,
        adapter,
        role,
        messages(
          contract.prompt,
          "Original task:\n#{task}\n\nReview this final diff:\n\n#{diff}"
        ),
        ReviewResult.schema()
      )

    %{response | object: ReviewResult.actionable(response.object, diff)}
  end

  defp generate(scope, adapter, role, messages, tools) do
    with {:ok, model, reference} <- LLM.resolve_integration(scope, role["model"]) do
      LLM.generate(scope, model, reference, messages, tools,
        adapter: adapter,
        timeout: @timeout,
        reasoning: role["reasoning"]
      )
    end
  end

  defp generate_object(scope, adapter, role, messages, schema) do
    with {:ok, model, reference} <- LLM.resolve_integration(scope, role["model"]) do
      LLM.generate_object(scope, model, reference, messages, schema,
        adapter: adapter,
        timeout: @timeout,
        reasoning: role["reasoning"]
      )
    end
  end

  @doc false
  def correction_prompt(task, checks, findings) do
    implementation_prompt(task, checks) <>
      "\nFinal-diff review reported these claims. Inspect the current file, address only supported " <>
      "issues, rerun the exact public command, and finish with a summary: " <>
      Jason.encode!(findings)
  end

  defp implementation_prompt(task, checks) do
    task["prompt"] <>
      "\nOnly modify: " <>
      Enum.join(task["expected"]["allowed_paths"], ", ") <>
      ". Public verification commands (exactly): " <>
      Enum.join(checks, "; ") <>
      ". Inspect, patch, run public checks, and finish with a summary. Never use network access."
  end

  defp run_checks(root, checks) do
    Enum.map(checks, fn check ->
      [executable | args] = OptionParser.split(check)
      {output, status} = System.cmd(executable, args, cd: root, stderr_to_stdout: true)

      %{
        "command" => check,
        "passed" => status == 0,
        "status" => status,
        "output" => truncate(output)
      }
    end)
  end

  defp with_workspace(files, fun) do
    root = Path.join(System.tmp_dir!(), "kodo-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      materialize(root, files)
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp materialize(root, files) do
    Enum.each(files || %{}, fn {path, body} ->
      {:ok, target} = confined(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, body)
    end)
  end

  defp confined(root, path) when is_binary(path) do
    expanded = Path.expand(path, root)

    if expanded == root or String.starts_with?(expanded, root <> "/"),
      do: {:ok, expanded},
      else: {:error, :path_escape}
  end

  defp confined(_root, _path), do: {:error, :invalid_path}

  defp safe_paths(root, paths),
    do:
      Enum.flat_map(paths, fn path ->
        if is_binary(path) and String.trim(path) != "" and
             match?({:ok, _}, confined(root, path)),
           do: [path],
           else: []
      end)

  defp changed_paths(root),
    do:
      root
      |> git(["diff", "--name-only"])
      |> Map.fetch!("output")
      |> String.split("\n", trim: true)

  defp git(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    %{"status" => status, "output" => truncate(output)}
  end

  defp messages(system, user),
    do: [%{"role" => "system", "content" => system}, %{"role" => "user", "content" => user}]

  defp assistant_message(%{assistant: nil, text: text}, calls) do
    %{"role" => "assistant", "content" => text, "tool_calls" => json_calls(calls)}
  end

  defp assistant_message(%{assistant: provider_state}, _calls) do
    %{"role" => "assistant", "provider_state" => provider_state}
  end

  defp json_calls(calls),
    do: Enum.map(calls, &%{"id" => &1.id, "name" => &1.name, "arguments" => &1.arguments})

  defp truncate(value), do: binary_part(value, 0, min(byte_size(value), @max_output))
  defp error_map({:error, reason}), do: %{"error" => inspect(reason)}
  defp error_map(reason), do: %{"error" => inspect(reason)}
  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
  defp ratio(_value, 0), do: 1.0
  defp ratio(value, total), do: value / total
  defp merge_usage(left, nil), do: left

  defp merge_usage(left, right),
    do:
      Map.merge(left, right, fn _key, a, b ->
        if is_number(a) and is_number(b), do: a + b, else: b
      end)

  defp contracts,
    do: Map.new(Roles.all(), fn {role, contract} -> {Atom.to_string(role), contract} end)

  defp toolsets, do: Map.new(["read-only-v1", "workspace-v5"], &{&1, Tools.definitions(&1)})

  @doc false
  def aggregate(tasks) do
    completed = Enum.reject(tasks, &Map.has_key?(&1, "error"))
    search = Enum.filter(completed, &(&1["type"] == "search"))
    review = Enum.filter(completed, &(&1["type"] == "review"))
    implementation = Enum.filter(completed, &(&1["type"] == "implementation"))
    latencies = Enum.map(tasks, & &1["latency_ms"])

    %{
      "task_count" => length(tasks),
      "completed" => length(completed),
      "errors" => length(tasks) - length(completed),
      "failure_rate" => ratio(length(tasks) - length(completed), length(tasks)),
      "latency_ms" => %{
        "total" => Enum.sum(latencies),
        "mean" => average(latencies),
        "p95" => percentile(latencies, 0.95)
      },
      "usage" => Enum.reduce(completed, %{}, &merge_usage(&2, &1["usage"])),
      "estimated_cost_usd" => Enum.sum_by(completed, &(&1["estimated_cost_usd"] || 0)),
      "quality" => %{
        "search" => %{
          "relevant_file_recall" => average_metric(search, "relevant_file_recall"),
          "evidence_citation_recall" => average_metric(search, "evidence_citation_recall"),
          "irrelevant_files" => sum_metric(search, "irrelevant_files")
        },
        "review" => %{
          "defect_recall" => average_metric(review, "defect_recall"),
          "severity_accuracy" => average_metric(review, "severity_accuracy"),
          "location_accuracy" => average_metric(review, "location_accuracy"),
          "false_positives" => sum_metric(review, "false_positives")
        },
        "implementation" => %{
          "public_check_pass_rate" => boolean_rate(implementation, "public_checks_passed"),
          "hidden_check_pass_rate" => boolean_rate(implementation, "hidden_checks_passed"),
          "scope_compliance_rate" => boolean_rate(implementation, "scope_compliant"),
          "clean_review_rate" => boolean_rate(implementation, "review_clean")
        }
      }
    }
  end

  defp revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      _error -> nil
    end
  end

  defp average_metric(tasks, key),
    do: tasks |> Enum.map(&get_in(&1, ["metrics", key])) |> average()

  defp sum_metric(tasks, key), do: Enum.sum_by(tasks, &get_in(&1, ["metrics", key]))

  defp boolean_rate(tasks, key),
    do: ratio(Enum.count(tasks, &get_in(&1, ["metrics", key])), length(tasks))

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)

  defp percentile([], _percentile), do: nil

  defp percentile(values, percentile) do
    values
    |> Enum.sort()
    |> Enum.at(ceil(length(values) * percentile) - 1)
  end
end
