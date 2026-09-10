defmodule Kodo.Test.FakeRefreshClient do
  @moduledoc false

  def refresh(refresh_token, opts) do
    agent = Keyword.fetch!(opts, :agent)

    response =
      Agent.get_and_update(agent, fn %{responses: [response | remaining]} = state ->
        {response,
         %{state | responses: remaining, refresh_tokens: [refresh_token | state.refresh_tokens]}}
      end)

    if is_function(response, 1), do: response.(refresh_token), else: response
  end
end
