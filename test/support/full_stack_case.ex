defmodule Kodo.Test.FullStackCase do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  @runner_ready_timeout 15_000
  @session_timeout 30_000
  @http_timeout 10_000
  @http_ok_status 200
  @successful_command_exit_code 0

  def start_stack! do
    port = free_port!()

    start_supervised!(
      {Bandit,
       plug: KodoWeb.Endpoint, scheme: :http, port: port, ip: {127, 0, 0, 1}, startup_log: false},
      id: {:full_stack_bandit, port}
    )

    %{base_url: "http://127.0.0.1:#{port}", port: port}
  end

  def fixture! do
    root = Path.join(System.tmp_dir!(), "kodo-e2e-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "greeting.txt"), "helo\n")
    git!(root, ["init", "--quiet"])
    git!(root, ["config", "user.email", "kodo-e2e@example.invalid"])
    git!(root, ["config", "user.name", "Kodo E2E"])
    git!(root, ["add", "greeting.txt"])
    git!(root, ["commit", "--quiet", "-m", "fixture"])
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  def start_runner!(base_url, workspace, token) do
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "runners")
    executable = runner_executable!()

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "daemon",
          "--workspace",
          workspace,
          "--control-plane",
          base_url,
          "--token",
          token
        ]
      ])

    monitor = :erlang.monitor(:port, port)

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
    end)

    runner = wait_runner!(:runner_registered, port, monitor)
    connected = wait_runner!(:runner_connected, port, monitor)
    assert connected.id == runner.id
    runner
  end

  def post!(base_url, path, body, expected_status, token) do
    response =
      Req.post!(base_url <> path,
        json: body,
        auth: {:bearer, token},
        receive_timeout: @http_timeout
      )

    assert response.status == expected_status
    response.body
  end

  def replay!(base_url, session_id, token) do
    replay_pages!(base_url, session_id, token, 0, [])
  end

  defp replay_pages!(base_url, session_id, token, cursor, events) do
    response =
      Req.get!(base_url <> "/api/sessions/#{session_id}?after_sequence=#{cursor}",
        auth: {:bearer, token},
        receive_timeout: @http_timeout
      )

    assert response.status == @http_ok_status
    replay = response.body
    events = events ++ replay["events"]

    if replay["has_more"] do
      replay_pages!(base_url, session_id, token, List.last(events)["sequence"], events)
    else
      Map.put(replay, "events", events)
    end
  end

  def assert_live_outcome!(replay, workspace) do
    assert replay["session"]["status"] == "completed"
    assert File.read!(Path.join(workspace, "greeting.txt")) == "hello\n"
    assert Enum.any?(replay["events"], &(&1["type"] == "assistant_message_completed"))

    sequences = Enum.map(replay["events"], & &1["sequence"])
    assert sequences == Enum.to_list(1..length(sequences))

    completed_tools =
      for %{"type" => "tool_completed", "payload" => payload} <- replay["events"],
          do: payload

    assert Enum.any?(completed_tools, fn payload ->
             payload["name"] in ["poll_command", "stop_command"] and
               match?(
                 %{"exited" => %{"code" => @successful_command_exit_code}},
                 payload["output"]["status"]
               )
           end)
  end

  def subscribe_session!(session_id) do
    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session_id}")
  end

  def await_completed!(session_id, timeout \\ @session_timeout) do
    receive do
      {:session_event, %{type: "session_status_changed", payload: %{"status" => "completed"}}} ->
        :ok

      {:session_event, %{type: "session_failed", payload: payload}} ->
        flunk("session #{session_id} failed: #{inspect(payload)}")

      {:session_event, %{type: "session_status_changed", payload: %{"status" => status}}}
      when status in ["failed", "cancelled"] ->
        flunk("session #{session_id} reached #{status}")
    after
      timeout -> flunk("session #{session_id} did not complete")
    end
  end

  def terminate_session!(session_id) do
    case Registry.lookup(Kodo.SessionRegistry, session_id) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        :ok = DynamicSupervisor.terminate_child(Kodo.SessionSupervisor, pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}

      [] ->
        :ok
    end
  end

  defp wait_runner!(message, port, monitor) do
    receive do
      {^message, runner} ->
        runner

      {:DOWN, ^monitor, :port, ^port, reason} ->
        flunk("runner exited before #{message}: #{inspect(reason)}")

      {^port, {:data, output}} ->
        IO.write(:stderr, output)
        wait_runner!(message, port, monitor)
    after
      @runner_ready_timeout -> flunk("timed out waiting for #{message}")
    end
  end

  defp runner_executable! do
    case System.get_env("KODO_RUNNER_BIN") do
      nil ->
        {_, status} =
          System.cmd("cargo", ["build", "--quiet", "-p", "kodo", "--bin", "kodo"],
            stderr_to_stdout: true
          )

        assert status == 0, "cargo build failed"
        Path.expand("target/debug/kodo")

      configured ->
        executable = Path.expand(configured)
        assert File.exists?(executable), "KODO_RUNNER_BIN does not exist: #{executable}"
        executable
    end
  end

  defp free_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{output}"
  end
end
