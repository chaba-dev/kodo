defmodule Kodo.Test.FakeRefreshClient do
  @moduledoc false

  def refresh(refresh_token, opts) do
    agent =
      Keyword.get(opts, :agent) || Application.fetch_env!(:kodo, :fake_refresh_client_agent)

    response =
      Agent.get_and_update(agent, fn %{responses: [response | remaining]} = state ->
        {response,
         %{state | responses: remaining, refresh_tokens: [refresh_token | state.refresh_tokens]}}
      end)

    if is_function(response, 1), do: response.(refresh_token), else: response
  end
end
