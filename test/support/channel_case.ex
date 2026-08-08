defmodule KodoWeb.ChannelCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint KodoWeb.Endpoint
      import Phoenix.ChannelTest
    end
  end

  setup tags do
    Kodo.DataCase.setup_sandbox(tags)
    :ok
  end
end
