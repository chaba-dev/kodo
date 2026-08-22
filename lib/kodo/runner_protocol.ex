defmodule Kodo.RunnerProtocol do
  @moduledoc """
  Shared control-plane contract for local runner registration and transport.

  These values are protocol and security boundaries rather than user preferences. Keep the Rust
  transport constants in sync when changing them.
  """

  @version 4
  @limits_version 1
  @authority_lease_ttl_ms 15_000
  @token_salt "runner socket v1"
  @token_max_age_seconds 24 * 60 * 60
  @max_wire_bytes 4 * 1024 * 1024
  @phoenix_envelope_reserve_bytes 4 * 1024
  @max_payload_bytes @max_wire_bytes - @phoenix_envelope_reserve_bytes
  @json_escape_expansion 6
  @result_metadata_bytes 512
  @max_limit_value 4_294_967_295
  @max_blocking_tools 1024
  @limit_keys [
    :version,
    :max_output_bytes,
    :max_results,
    :max_patch_input_bytes,
    :max_file_input_bytes,
    :max_blocking_tools,
    :max_retained_processes,
    :max_process_output_chunks,
    :max_cached_requests,
    :max_cached_response_bytes
  ]

  # Phoenix owns connected-runner policy. Rust validates this map before constructing the runtime,
  # so changing it creates a new daemon policy epoch rather than mutating active work in place.
  @limits %{
    version: @limits_version,
    max_output_bytes: 256 * 1024,
    max_results: 1_000,
    max_patch_input_bytes: 512 * 1024,
    max_file_input_bytes: 16 * 1024 * 1024,
    max_blocking_tools: 8,
    max_retained_processes: 1024,
    max_process_output_chunks: 1024,
    max_cached_requests: 1024,
    max_cached_response_bytes: 16 * 1024 * 1024
  }

  def version, do: @version
  def token_salt, do: @token_salt
  def token_max_age_seconds, do: @token_max_age_seconds
  def max_wire_bytes, do: @max_wire_bytes
  def max_payload_bytes, do: @max_payload_bytes
  def limits, do: @limits

  @doc "Validates a successful response against the dispatched protocol tool."
  def validate_tool_response(%{"tool" => "list_files"}, %{
        "result" => "files",
        "paths" => paths,
        "truncated" => truncated
      })
      when is_list(paths) and is_boolean(truncated),
      do: validate_strings(paths)

  def validate_tool_response(%{"tool" => "search_code"}, %{
        "result" => "matches",
        "matches" => matches,
        "truncated" => truncated
      })
      when is_list(matches) and is_boolean(truncated) do
    if Enum.all?(matches, &valid_search_match?/1), do: {:ok, matches}, else: :error
  end

  def validate_tool_response(
        %{"tool" => "read_file"},
        %{
          "result" => "file",
          "content" => content,
          "offset" => offset,
          "next_offset" => next_offset,
          "truncated" => truncated
        } = response
      )
      when is_binary(content) and is_integer(offset) and offset >= 0 and
             (is_nil(next_offset) or (is_integer(next_offset) and next_offset >= 0)) and
             is_boolean(truncated),
      do: {:ok, response}

  def validate_tool_response(
        %{"tool" => tool},
        %{
          "result" => "output",
          "content" => content,
          "truncated" => truncated
        } = response
      )
      when tool in ["git_status", "git_diff"] and is_binary(content) and
             is_boolean(truncated),
      do: {:ok, response}

  def validate_tool_response(%{"tool" => "apply_patch"}, %{
        "result" => "files_changed",
        "paths" => paths
      })
      when is_list(paths),
      do: validate_strings(paths)

  def validate_tool_response(
        %{"tool" => "start_command"},
        %{
          "result" => "command_started",
          "process_id" => process_id
        } = response
      ) do
    if Ecto.UUID.cast(process_id) == {:ok, process_id}, do: {:ok, response}, else: :error
  end

  def validate_tool_response(
        %{"tool" => tool},
        %{
          "result" => "command_poll",
          "process_id" => process_id,
          "status" => status,
          "output" => output,
          "earliest_sequence" => earliest_sequence,
          "next_sequence" => next_sequence,
          "truncated" => truncated
        } = response
      )
      when is_list(output) do
    if valid_command_poll_metadata?(
         tool,
         process_id,
         status,
         earliest_sequence,
         next_sequence,
         truncated
       ) and Enum.all?(output, &valid_command_output?/1),
       do: {:ok, response},
       else: :error
  end

  def validate_tool_response(_request, _response), do: :error

  @doc "Builds the short runner-enforced lease carried by every connected tool request."
  def authority_lease(%{session_id: session_id, epoch: epoch}) do
    %{
      "session_id" => session_id,
      "ownership_epoch" => epoch,
      "ttl_ms" => @authority_lease_ttl_ms
    }
  end

  @doc "Fails fast when Phoenix policy cannot be safely enforced by a connected runner."
  def validate_limits!(limits \\ @limits)

  def validate_limits!(limits) when is_map(limits) do
    unless valid_limit_keys?(limits) do
      raise ArgumentError, "runner limits must contain exactly the versioned contract keys"
    end

    unless valid_limit_values?(limits) do
      raise ArgumentError, "runner limits must use the supported version and positive integers"
    end

    unless valid_limit_budgets?(limits) do
      raise ArgumentError, "runner limits exceed transport or replay-cache budgets"
    end

    limits
  end

  def validate_limits!(_limits), do: raise(ArgumentError, "runner limits must be a map")

  defp valid_limit_keys?(limits),
    do: Enum.sort(Map.keys(limits)) == Enum.sort(@limit_keys)

  defp valid_limit_values?(limits) do
    quota_values = limits |> Map.drop([:version]) |> Map.values()

    limits.version == @limits_version and
      Enum.all?(quota_values, &(is_integer(&1) and &1 > 0 and &1 <= @max_limit_value)) and
      limits.max_blocking_tools <= @max_blocking_tools
  end

  defp valid_limit_budgets?(limits) do
    maximum_response_bytes =
      limits.max_output_bytes * @json_escape_expansion +
        (limits.max_results + limits.max_process_output_chunks) * @result_metadata_bytes +
        @phoenix_envelope_reserve_bytes

    maximum_patch_bytes =
      limits.max_patch_input_bytes * @json_escape_expansion + @phoenix_envelope_reserve_bytes

    maximum_response_bytes <= @max_payload_bytes and
      maximum_response_bytes <= limits.max_cached_response_bytes and
      maximum_patch_bytes <= @max_payload_bytes
  end

  defp validate_strings(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error
  end

  defp valid_search_match?(%{"path" => path, "line" => line, "content" => content}),
    do: is_binary(path) and is_integer(line) and line >= 0 and is_binary(content)

  defp valid_search_match?(_match), do: false

  defp valid_process_status?(status) when status in ["running", "timed_out", "stopped"],
    do: true

  defp valid_process_status?(%{"exited" => %{"code" => code}}),
    do: is_nil(code) or is_integer(code)

  defp valid_process_status?(_status), do: false

  defp valid_command_poll_metadata?(
         tool,
         process_id,
         status,
         earliest_sequence,
         next_sequence,
         truncated
       ) do
    tool in ["poll_command", "stop_command"] and
      Ecto.UUID.cast(process_id) == {:ok, process_id} and valid_process_status?(status) and
      is_integer(earliest_sequence) and earliest_sequence >= 0 and
      is_integer(next_sequence) and next_sequence >= 0 and is_boolean(truncated)
  end

  defp valid_command_output?(%{
         "sequence" => sequence,
         "stream" => stream,
         "content" => content,
         "truncated" => truncated
       }),
       do:
         is_integer(sequence) and sequence >= 0 and stream in ["stdout", "stderr"] and
           is_binary(content) and is_boolean(truncated)

  defp valid_command_output?(_output), do: false
end
