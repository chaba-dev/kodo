defimpl Jason.Encoder, for: Kodo.Test.BlockingJSONValue do
  def encode(value, opts) do
    send(value.owner, {:json_encoding_blocked, value.ref, self()})

    receive do
      {:continue_json_encoding, ref} when ref == value.ref ->
        Jason.Encoder.encode(value.value, opts)
    end
  end
end
