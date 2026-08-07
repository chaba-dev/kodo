defmodule KodoWeb.RunnerSocket do
  use Phoenix.Socket

  alias Kodo.Runners

  channel "runner:*", KodoWeb.RunnerChannel

  @impl true
  def connect(%{"token" => token}, socket, %{peer_data: %{address: address}}) do
    with true <- loopback?(address),
         {:ok, runner_id} <-
           Phoenix.Token.verify(KodoWeb.Endpoint, "runner socket v1", token, max_age: 86_400),
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
