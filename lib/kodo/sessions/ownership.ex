defmodule Kodo.Sessions.Ownership do
  @moduledoc "A coordinator's durable fencing token for one session."

  @enforce_keys [:session_id, :owner_boot_id, :epoch]
  defstruct [:session_id, :owner_boot_id, :epoch]
end
