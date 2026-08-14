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
end
