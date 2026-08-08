defmodule KodoWeb.RunnerSocket do
  @moduledoc """
  Authenticates loopback runner WebSockets before any channel topic is authorized.

  The signed token proves prior local registration, not operating-system user identity. This is the
  deliberate trust boundary for the single-user MVP.
  """

  use Phoenix.Socket

  alias Kodo.RunnerProtocol
  alias Kodo.Runners

  @token_salt RunnerProtocol.token_salt()
  @token_max_age_seconds RunnerProtocol.token_max_age_seconds()

  channel "runner:*", KodoWeb.RunnerChannel

  @impl true
  def connect(%{"token" => token}, socket, %{peer_data: %{address: address}}) do
    with true <- loopback?(address),
         {:ok, runner_id} <-
           Phoenix.Token.verify(KodoWeb.Endpoint, @token_salt, token,
             max_age: @token_max_age_seconds
           ),
         %{} <- Runners.get_runner(runner_id) do
      {:ok, assign(socket, :runner_id, runner_id)}
    else
      _ -> :error
    end
  end

  def connect(_, _, _), do: :error

  @impl true
  def id(socket), do: "runner_socket:#{socket.assigns.runner_id}"

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
