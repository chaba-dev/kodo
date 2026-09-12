defmodule Kodo.LLM.InvocationAdmission do
  @moduledoc false

  alias Kodo.LLM.Credential

  @enforce_keys [:model, :credential]
  defstruct [:model, :credential]

  @opaque t :: %__MODULE__{model: LLMDB.Model.t(), credential: Credential.t()}

  # This wrapper is an internal call-graph boundary, not a bearer capability: Elixir structs are
  # constructible inside the VM. Production agent paths receive it only from the session operation
  # that atomically records invocation start; the out-of-band evaluation harness is deliberately
  # named and kept separate. Avoid adding a database recheck at dispatch, because an admitted
  # provider operation is allowed to finish after replacement or disconnection.
  @doc false
  def new(%LLMDB.Model{} = model, %Credential{} = credential) do
    %__MODULE__{model: model, credential: credential}
  end
end
