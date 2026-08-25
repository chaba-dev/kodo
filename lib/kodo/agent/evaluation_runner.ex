defmodule Kodo.Agent.EvaluationRunner do
  @moduledoc "Runs the pinned MVP evaluation suite against a live LLM adapter."

  alias Kodo.Agent.{EvaluationSuite, ModelMapping, Roles, Tools}

  @timeout 120_000
  @max_steps 10
  @max_output 32_000
  @review_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["clean", "findings"],
    "properties" => %{
      "clean" => %{"type" => "boolean"},
      "findings" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["severity", "path", "line", "explanation"],
          "properties" => %{
            "severity" => %{"type" => "string", "enum" => ["low", "medium", "high"]},
            "path" => %{"type" => "string"},
            "line" => %{"type" => "integer", "minimum" => 1},
            "explanation" => %{"type" => "string"}
          }
        }
      }
    }
  }

  @doc "Runs every task and returns a JSON-safe report. Errors are isolated per task."
  def run(opts \\ []) do
    suite = Keyword.get_lazy(opts, :suite, &EvaluationSuite.load!/0)
    adapter = Keyword.get(opts, :adapter, Kodo.LLM.ReqLLM)
    mapping = Keyword.get(opts, :mapping, ModelMapping.balanced())

    tasks = Enum.map(suite["tasks"], &safe_task(&1, adapter, mapping))

    %{
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

  defp safe_task(task, adapter, mapping) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        execute(task, adapter, mapping)
      rescue
        exception -> %{"error" => Exception.message(exception), "trace" => [], "usage" => %{}}
      catch
        kind, reason ->
          %{"error" => Exception.format(kind, reason), "trace" => [], "usage" => %{}}
      end

    result
    |> Map.put("id", task["id"])
    |> Map.put("type", task["type"])
    |> Map.put("latency_ms", System.monotonic_time(:millisecond) - started)
  end

  defp execute(%{"type" => "search"} = task, adapter, mapping) do
    with_workspace(task["fixture"]["files"], fn root ->
      role = ModelMapping.role!(mapping, :search)
      contract = Roles.fetch!(:search, role["role_contract_version"])
      prompt = task["prompt"] <> " Cite each finding as path:line and quote evidence."
      {answer, trace, usage} = tool_loop(adapter, role, contract, prompt, root, [], [])

      %{
        "answer" => answer,
        "trace" => trace,
        "usage" => usage,
        "metrics" => score_search(answer, task["expected"], Map.keys(task["fixture"]["files"]))
      }
    end)
  end

  defp execute(%{"type" => "review"} = task, adapter, mapping) do
    role = ModelMapping.role!(mapping, :review)
    contract = Roles.fetch!(:review, role["role_contract_version"])
    messages = messages(contract.prompt, task["prompt"] <> "\n\n" <> task["fixture"]["diff"])
    started = System.monotonic_time(:millisecond)

    {:ok, response} =
      adapter.generate_object(role["model"], messages, @review_schema,
        timeout: @timeout,
        reasoning: role["reasoning"]
      )

    %{
      "object" => response.object,
      "usage" => response.usage || %{},
      "trace" => [%{"kind" => "review", "latency_ms" => elapsed(started)}],
      "metrics" => score_review(response.object, task["expected"])
    }
  end

  defp execute(%{"type" => "implementation"} = task, adapter, mapping) do
    with_workspace(task["fixture"]["files"], fn root ->
      System.cmd("git", ["init", "-q"], cd: root, stderr_to_stdout: true)
      System.cmd("git", ["add", "."], cd: root, stderr_to_stdout: true)

      role = ModelMapping.role!(mapping, :primary)
      contract = Roles.fetch!(:primary, role["role_contract_version"])
      checks = task["expected"]["public_checks"]
      prompt = implementation_prompt(task, checks)
      {answer, trace, usage} = tool_loop(adapter, role, contract, prompt, root, checks, [])
      {diff, 0} = System.cmd("git", ["diff", "--no-ext-diff"], cd: root, stderr_to_stdout: true)
      review = structured_review(adapter, mapping, diff)
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

  defp tool_loop(adapter, role, contract, prompt, root, commands, trace) do
    state = %{
      root: root,
      commands: commands,
      history: messages(contract.prompt, prompt),
      trace: trace,
      usage: %{}
    }

    loop(adapter, role, contract, state, 0)
  end

  defp loop(_adapter, _role, _contract, state, @max_steps),
    do: {"", state.trace, state.usage}

  defp loop(adapter, role, contract, state, step) do
    started = System.monotonic_time(:millisecond)

    case adapter.generate(
           role["model"],
           state.history,
           Tools.definitions(contract.toolset_version),
           timeout: @timeout,
           reasoning: role["reasoning"]
         ) do
      {:ok, response} ->
        continue_loop(adapter, role, contract, state, response, started, step)

      {:error, reason} ->
        raise "model request failed: #{inspect(reason)}"
    end
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
    assistant = %{
      "role" => "assistant",
      "content" => response.text,
      "tool_calls" => json_calls(calls)
    }

    {results, tool_trace} = execute_calls(calls, state.root, state.commands)

    state = %{
      state
      | history: state.history ++ [assistant | results],
        trace: state.trace ++ tool_trace
    }

    loop(adapter, role, contract, state, step + 1)
  end

  defp execute_calls(calls, root, commands) do
    Enum.map_reduce(calls, [], fn call, trace ->
      output = execute_tool(call.name, call.arguments, root, commands)

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
  defp execute_tool("search_code", args, root, _), do: search(root, args)
  defp execute_tool("git_status", _, root, _), do: git(root, ["status", "--short"])

  defp execute_tool("git_diff", args, root, _),
    do: git(root, ["diff", "--"] ++ safe_paths(root, args["paths"]))

  defp execute_tool("apply_patch", args, root, _), do: apply_patch(root, args["patch"])
  defp execute_tool("start_command", args, root, commands), do: command(root, args, commands)

  defp execute_tool("delegate_search", args, root, _),
    do: delegated_search(root, args["question"])

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

  defp read_file(root, args) do
    with {:ok, path} <- confined(root, args["path"]), {:ok, body} <- File.read(path) do
      offset = min(args["offset"] || 0, byte_size(body))
      limit = min(args["limit"] || @max_output, @max_output)

      %{
        "content" => binary_part(body, offset, min(limit, byte_size(body) - offset)),
        "truncated" => byte_size(body) > offset + limit
      }
    else
      error -> error_map(error)
    end
  end

  defp search(root, args) do
    paths = safe_paths(root, args["paths"] || ["."])

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
    case System.cmd("git", ["apply", "--whitespace=nowarn", "-"],
           cd: root,
           input: patch,
           stderr_to_stdout: true
         ) do
      {output, 0} -> %{"applied" => true, "output" => truncate(output)}
      {output, status} -> %{"applied" => false, "status" => status, "output" => truncate(output)}
    end
  end

  defp apply_patch(_root, _patch), do: %{"error" => "patch exceeds limit"}

  defp command(root, args, commands) do
    command = String.trim(args["command"] || "")

    if command in commands and args["cwd"] in ["", "."] do
      [executable | argv] = OptionParser.split(command)
      env = [{"HTTP_PROXY", ""}, {"HTTPS_PROXY", ""}, {"ALL_PROXY", ""}, {"NO_PROXY", "*"}]
      {output, status} = System.cmd(executable, argv, cd: root, env: env, stderr_to_stdout: true)
      %{"status" => status, "output" => truncate(output), "process_id" => nil}
    else
      %{"error" => "command is not an exact public-check allowlist match"}
    end
  end

  defp delegated_search(root, question) do
    terms =
      question
      |> String.split(~r/\W+/, trim: true)
      |> Enum.filter(&(byte_size(&1) > 3))
      |> Enum.take(5)

    outputs =
      Enum.map(terms, fn term -> search(root, %{"query" => term, "paths" => ["."]})["matches"] end)

    %{"question" => question, "evidence" => truncate(Enum.join(outputs, "\n"))}
  end

  defp structured_review(adapter, mapping, diff) do
    role = ModelMapping.role!(mapping, :review)
    contract = Roles.fetch!(:review, role["role_contract_version"])

    {:ok, response} =
      adapter.generate_object(role["model"], messages(contract.prompt, diff), @review_schema,
        timeout: @timeout,
        reasoning: role["reasoning"]
      )

    response
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
        if match?({:ok, _}, confined(root, path)), do: [path], else: []
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

  defp toolsets, do: Map.new(["read-only-v1", "workspace-v2"], &{&1, Tools.definitions(&1)})

  defp aggregate(tasks),
    do: %{
      "task_count" => length(tasks),
      "completed" => Enum.count(tasks, &(not Map.has_key?(&1, "error"))),
      "errors" => Enum.count(tasks, &Map.has_key?(&1, "error"))
    }
end
