defmodule Kodo.RunnerProtocol do
  @moduledoc """
  Shared control-plane contract for local runner registration and transport.

  These values are protocol and security boundaries rather than user preferences. Keep the Rust
  transport constants in sync when changing them.
  """

  @version 3
  @limits_version 1
  @token_salt "runner socket v1"
  @token_max_age_seconds 24 * 60 * 60
  @max_wire_bytes 4 * 1024 * 1024
  @phoenix_envelope_reserve_bytes 4 * 1024
  @max_payload_bytes @max_wire_bytes - @phoenix_envelope_reserve_bytes

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
end
