defmodule Kodo.Agent.Tools do
  @moduledoc "Canonical model tool schemas and typed runner request translation."

  @object %{"type" => "object", "additionalProperties" => false}
  @string %{"type" => "string"}
  @integer %{"type" => "integer", "minimum" => 0}

  def definitions do
    [
      tool("list_files", "List files below a workspace path", %{"path" => @string}, ["path"]),
      tool(
        "search_code",
        "Search workspace text and return bounded matches",
        %{"query" => @string, "paths" => %{"type" => "array", "items" => @string}},
        ["query", "paths"]
      ),
      tool(
        "read_file",
        "Read a bounded range from a workspace file",
        %{"path" => @string, "offset" => @integer, "limit" => @integer},
        ["path", "offset", "limit"]
      ),
      tool("git_status", "Inspect repository status", %{}, []),
      tool(
        "git_diff",
        "Inspect the current repository diff",
        %{"paths" => %{"type" => "array", "items" => @string}},
        ["paths"]
      ),
      tool("apply_patch", "Apply a bounded unified patch", %{"patch" => @string}, ["patch"]),
      tool(
        "start_command",
        "Start a verification command",
        %{"command" => @string, "cwd" => @string, "timeout_ms" => @integer},
        ["command", "cwd", "timeout_ms"]
      ),
      tool(
        "poll_command",
        "Poll command output after a sequence cursor",
        %{"process_id" => @string, "after_sequence" => @integer},
        ["process_id", "after_sequence"]
      ),
      tool(
        "stop_command",
        "Stop a running command and return remaining output",
        %{"process_id" => @string, "after_sequence" => @integer},
        ["process_id", "after_sequence"]
      )
    ]
  end

  def request(name, arguments) when is_binary(name) and is_map(arguments) do
    translate(name, arguments)
  end

  def request(_name, _arguments), do: {:error, :invalid_tool_call}

  defp translate("list_files", %{"path" => path} = args) when is_binary(path),
    do: exact(args, ["path"], "list_files")

  defp translate("search_code", %{"query" => query, "paths" => paths} = args)
       when is_binary(query) and is_list(paths),
       do: strings(paths, args, ["paths", "query"], "search_code")

  defp translate("read_file", %{"path" => path, "offset" => offset, "limit" => limit} = args)
       when is_binary(path) and is_integer(offset) and offset >= 0 and is_integer(limit) and
              limit > 0,
       do: exact(args, ["limit", "offset", "path"], "read_file")

  defp translate("git_status", args), do: exact(args, [], "git_status")

  defp translate("git_diff", %{"paths" => paths} = args) when is_list(paths),
    do: strings(paths, args, ["paths"], "git_diff")

  defp translate("apply_patch", %{"patch" => patch} = args) when is_binary(patch),
    do: exact(args, ["patch"], "apply_patch")

  defp translate(
         "start_command",
         %{"command" => command, "cwd" => cwd, "timeout_ms" => timeout} = args
       )
       when is_binary(command) and is_binary(cwd) and is_integer(timeout) and timeout >= 0,
       do: exact(args, ["command", "cwd", "timeout_ms"], "start_command")

  defp translate(name, %{"process_id" => process_id, "after_sequence" => sequence} = args)
       when name in ["poll_command", "stop_command"] and is_binary(process_id) and
              is_integer(sequence) and sequence >= 0 do
    with {:ok, process_id} <- Ecto.UUID.cast(process_id),
         {:ok, request} <- exact(args, ["after_sequence", "process_id"], name) do
      {:ok, %{request | "process_id" => process_id}}
    else
      _ -> {:error, :invalid_tool_call}
    end
  end

  defp translate(name, _args) do
    if Enum.any?(definitions(), &(&1.name == name)) do
      {:error, :invalid_tool_call}
    else
      {:error, :unknown_tool}
    end
  end

  defp strings(values, args, keys, name) do
    if Enum.all?(values, &is_binary/1),
      do: exact(args, keys, name),
      else: {:error, :invalid_tool_call}
  end

  defp exact(args, keys, name) do
    if Enum.sort(Map.keys(args)) == keys do
      {:ok, Map.put(args, "tool", name)}
    else
      {:error, :invalid_tool_call}
    end
  end

  defp tool(name, description, properties, required) do
    %{
      name: name,
      description: description,
      parameters: Map.merge(@object, %{"properties" => properties, "required" => required})
    }
  end
end
