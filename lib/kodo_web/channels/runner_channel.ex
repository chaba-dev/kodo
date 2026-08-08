defmodule KodoWeb.RunnerChannel do
  @moduledoc "Authenticated transport for one active local runner connection."

  use KodoWeb, :channel

  alias Kodo.RunnerProtocol
  alias Kodo.Runners

  @protocol_version RunnerProtocol.version()
  @max_payload_bytes RunnerProtocol.max_payload_bytes()

  @impl true
  def join("runner:" <> runner_id, %{"protocol_version" => @protocol_version}, socket)
      when runner_id == socket.assigns.runner_id do
    # The registry is the single-node active-session lock; registration dies with the channel.
    case Registry.register(Kodo.RunnerRegistry, runner_id, nil) do
      {:ok, _} ->
        connect_runner(runner_id, socket)

      {:error, {:already_registered, _pid}} ->
        {:error, %{reason: "runner already connected"}}
    end
  end

  def join("runner:" <> _runner_id, _payload, _socket),
    do: {:error, %{reason: "unauthorized or unsupported protocol"}}

  @impl true
  def handle_in("tool_response", payload, socket) do
    # Size the decoded payload again at the trust boundary before broadcasting it in-process.
    case Jason.encode(payload) do
      {:ok, encoded} when byte_size(encoded) <= @max_payload_bytes ->
        _ = Runners.touch(socket.assigns.runner_id)

        Phoenix.PubSub.broadcast(
          Kodo.PubSub,
          "runner_responses:#{socket.assigns.runner_id}",
          {:runner_tool_response, socket.assigns.runner_id, payload}
        )

        {:reply, :ok, socket}

      _ ->
        {:reply, {:error, %{reason: "payload too large or invalid"}}, socket}
    end
  end

  @impl true
  def handle_info({:tool_request, request}, socket) do
    # The tool request ID carries durable correlation; Phoenix push refs remain transport-local.
    :ok = push(socket, "tool_request", request)
    {:noreply, socket}
  end

  defp connect_runner(runner_id, socket) do
    with %{} = runner <- Runners.get_runner(runner_id),
         {:ok, _runner} <- Runners.connected(runner) do
      {:ok, socket}
    else
      nil -> {:error, %{reason: "runner no longer exists"}}
      {:error, _changeset} -> {:error, %{reason: "runner update failed"}}
    end
  end
end
