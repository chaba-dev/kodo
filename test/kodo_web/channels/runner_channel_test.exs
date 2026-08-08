defmodule KodoWeb.RunnerChannelTest do
  use KodoWeb.ChannelCase

  alias Kodo.RunnerProtocol
  alias Kodo.Runners
  alias KodoWeb.RunnerSocket

  @valid %{
    workspace_root: "/work/project",
    platform: "linux",
    architecture: "x86_64",
    runner_version: "0.1.0",
    protocol_version: 3,
    capabilities: []
  }

  setup do
    {:ok, runner} = Runners.register(@valid)
    token = Phoenix.Token.sign(KodoWeb.Endpoint, "runner socket v1", runner.id)
    %{runner: runner, token: token}
  end

  test "socket rejects an invalid token" do
    assert :error = connect(RunnerSocket, %{"token" => "invalid"}, connect_options())
  end

  test "socket rejects a non-loopback peer", %{token: token} do
    options = [connect_info: %{peer_data: %{address: {192, 0, 2, 10}}}]
    assert :error = connect(RunnerSocket, %{"token" => token}, options)
  end

  test "authenticated runner joins only its exact topic", %{runner: runner, token: token} do
    assert {:ok, socket} = connect(RunnerSocket, %{"token" => token}, connect_options())

    assert {:error, %{reason: _}} =
             subscribe_and_join(socket, "runner:other", %{"protocol_version" => 3})

    assert {:ok, %{limits: limits}, channel} =
             subscribe_and_join(socket, "runner:#{runner.id}", %{"protocol_version" => 3})

    assert limits == RunnerProtocol.limits()

    request = %{"protocol_version" => 3, "request_id" => Ecto.UUID.generate()}
    assert :ok = Runners.dispatch(runner.id, request)
    assert_push "tool_request", ^request

    Phoenix.PubSub.subscribe(Kodo.PubSub, "runner_responses:#{runner.id}")
    response = %{"request_id" => request["request_id"], "output" => "ok"}
    ref = push(channel, "tool_response", response)
    assert_reply ref, :ok
    runner_id = runner.id
    assert_receive {:runner_tool_response, ^runner_id, ^response}
  end

  test "join rejects unsupported protocol", %{runner: runner, token: token} do
    assert {:ok, socket} = connect(RunnerSocket, %{"token" => token}, connect_options())

    assert {:error, %{reason: _}} =
             subscribe_and_join(socket, "runner:#{runner.id}", %{"protocol_version" => 2})
  end

  test "duplicate active connection is rejected", %{runner: runner, token: token} do
    assert {:ok, first_socket} = connect(RunnerSocket, %{"token" => token}, connect_options())
    assert {:ok, second_socket} = connect(RunnerSocket, %{"token" => token}, connect_options())
    topic = "runner:#{runner.id}"

    assert {:ok, _, _channel} =
             subscribe_and_join(first_socket, topic, %{"protocol_version" => 3})

    assert {:error, %{reason: "runner already connected"}} =
             subscribe_and_join(second_socket, topic, %{"protocol_version" => 3})
  end

  defp connect_options do
    [connect_info: %{peer_data: %{address: {127, 0, 0, 1}}}]
  end
end
