defmodule Kodo.Test.FakeDeviceAuthorizationClient do
  @moduledoc false

  def create(opts), do: respond(opts, :create, nil)
  def poll(payload, opts), do: respond(opts, :poll, payload)
  def exchange(payload, opts), do: respond(opts, :exchange, payload)

  defp respond(opts, operation, payload) do
    agent = Keyword.fetch!(opts, :agent)

    Agent.get_and_update(agent, fn state ->
      [response | remaining] = Map.fetch!(state.responses, operation)

      new_state = %{
        state
        | calls: [{operation, payload} | state.calls],
          responses: Map.put(state.responses, operation, remaining)
      }

      {response, new_state}
    end)
  end
end
