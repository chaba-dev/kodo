defmodule Kodo.RunnerProtocol do
  @moduledoc """
  Shared control-plane contract for local runner registration and transport.

  These values are protocol and security boundaries rather than user preferences. Keep the Rust
  transport constants in sync when changing them.
  """

  @version 2
  @token_salt "runner socket v1"
  @token_max_age_seconds 24 * 60 * 60
  @max_wire_bytes 4 * 1024 * 1024
  @phoenix_envelope_reserve_bytes 4 * 1024
  @max_payload_bytes @max_wire_bytes - @phoenix_envelope_reserve_bytes

  def version, do: @version
  def token_salt, do: @token_salt
  def token_max_age_seconds, do: @token_max_age_seconds
  def max_wire_bytes, do: @max_wire_bytes
  def max_payload_bytes, do: @max_payload_bytes
end
