defmodule Kodo.RunnersTest do
  use Kodo.DataCase

  alias Kodo.RunnerProtocol
  alias Kodo.Runners

  @valid %{
    workspace_root: "/work/project",
    platform: "linux",
    architecture: "x86_64",
    runner_version: "0.1.0",
    protocol_version: 5,
    capabilities: ["shell"]
  }

  test "registration upserts the reported workspace identity with a stable id" do
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "runners")

    assert {:ok, first} = Runners.register(@valid)
    assert_receive {:runner_registered, ^first}

    assert {:ok, second} = Runners.register(%{@valid | runner_version: "0.2.0"})
    assert_receive {:runner_registered, ^second}
    assert first.id == second.id
    assert second.runner_version == "0.2.0"
  end

  test "connection updates publish runner readiness" do
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "runners")
    {:ok, runner} = Runners.register(%{@valid | workspace_root: "/work/connected"})
    assert_receive {:runner_registered, ^runner}

    assert {:ok, connected} = Runners.connected(runner)
    assert_receive {:runner_connected, ^connected}
    assert connected.last_connected_at
  end

  test "registration rejects unsupported protocol versions" do
    assert {:error, changeset} = Runners.register(%{@valid | protocol_version: 2})
    assert "must be equal to 5" in errors_on(changeset).protocol_version
  end

  test "dispatch rejects payloads that cannot fit in a complete wire message" do
    payload = %{"content" => String.duplicate("x", 4 * 1024 * 1024)}

    assert {:error, :invalid_request} = Runners.dispatch(Ecto.UUID.generate(), payload)
  end

  test "runner policy fails fast when its replay cache cannot retain a response" do
    invalid = %{RunnerProtocol.limits() | max_cached_response_bytes: 1}

    assert_raise ArgumentError, "runner limits exceed transport or replay-cache budgets", fn ->
      RunnerProtocol.validate_limits!(invalid)
    end
  end

  test "runner policy rejects values outside the cross-platform contract" do
    invalid = %{RunnerProtocol.limits() | max_blocking_tools: 1025}

    assert_raise ArgumentError, fn -> RunnerProtocol.validate_limits!(invalid) end
  end
end
