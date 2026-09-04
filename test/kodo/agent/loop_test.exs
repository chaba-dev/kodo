defmodule Kodo.Agent.LoopTest do
  use Kodo.DataCase

  alias Kodo.Agent.Loop
  alias Kodo.Agent.Tools
  alias Kodo.Integrations
  alias Kodo.Runners
  alias Kodo.Sessions

  import Kodo.AccountsFixtures

  setup do
    scope = user_scope_fixture()

    {:ok, _integration} =
      Integrations.connect(scope, "openai", "api_key", %{"api_key" => "loop-test-key"})

    {:ok, runner} =
      Runners.register(scope, %{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 5,
        capabilities: []
      })

    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Budgeted turn",
        model: "openai:gpt-4o-mini"
      })

    {:ok, ownership} = Sessions.claim_ownership(session.id, nil)

    %{runner: runner, session: session, ownership: ownership, scope: scope}
  end

  test "stops before accepting a response that exceeds the token budget", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "token budget"
        },
        ownership: ownership
      )

    assert {:error, :token_budget_exceeded} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(max_tokens: 100),
               ownership: ownership
             )
  end

  test "fails before recording an invocation when the required integration is disconnected", %{
    session: session,
    ownership: ownership,
    scope: scope
  } do
    {:ok, integration} = Integrations.get_integration_by_provider(scope, "openai")

    assert {:ok, _disconnected} =
             Integrations.disconnect(scope, integration.id, integration.credential_generation)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "final answer"},
        ownership: ownership
      )

    assert {:error, :integration_disconnected} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets([]),
               ownership: ownership
             )

    refute Enum.any?(Sessions.events_after(session.id), &(&1.type == "model_invocation_started"))
  end

  test "records the resolved role and model mapping for an invocation", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "token budget"},
        ownership: ownership
      )

    assert {:error, :token_budget_exceeded} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(max_tokens: 100),
               ownership: ownership
             )

    invocation =
      Enum.find(Sessions.events_after(session.id), &(&1.type == "model_invocation_started"))

    assert invocation.payload["role"] == "primary"
    assert invocation.payload["provider"] == "openai"
    assert invocation.payload["model"] == "openai:gpt-4o-mini"
    assert invocation.payload["reasoning"] == "none"
    assert invocation.version == 4
    assert invocation.payload["model_identity"] == "gpt-4o-mini"
    assert invocation.payload["authentication_type"] == "api_key"
    assert invocation.payload["billing_path"] == "platform"
    assert invocation.payload["role_contract"] == "alpha-v1"
    refute Map.has_key?(invocation.payload, "role_prompt_version")
    assert invocation.payload["toolset_version"] == "workspace-v5"
    assert invocation.payload["capability_validation"]["tools"]
    assert invocation.payload["capability_validation"]["required_context_window"] == 100_000

    assert invocation.payload["model_mapping"]["roles"]["review"]["model"] ==
             "openai:gpt-4o-mini"
  end

  test "replays a pre-mapping session with its legacy model and alpha contract", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    previous_test_pid = Application.get_env(:kodo, :fake_llm_test_pid)
    Application.put_env(:kodo, :fake_llm_test_pid, self())
    on_exit(fn -> restore_env(:fake_llm_test_pid, previous_test_pid) end)
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    [created] = Sessions.events_after(session.id)

    created
    |> Ecto.Changeset.change(payload: Map.delete(created.payload, "model_mapping"))
    |> Repo.update!()

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "capture contract"},
        ownership: ownership
      )

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:llm_request, %LLMDB.Model{provider: :openai}, system, tools, opts}, 5_000
    assert system["content"] == Kodo.Agent.Roles.fetch!(:primary).prompt
    assert tools == Tools.definitions("workspace-v5")
    assert opts[:reasoning] == "none"

    assert_receive {:tool_request, review_request}
    assert review_request["request"]["tool"] == "git_diff"

    broadcast_success(runner, review_request, %{
      "result" => "output",
      "content" => "clean diff",
      "truncated" => false
    })

    assert {:ok, "The fix is complete."} = Task.await(loop)

    invocation =
      Enum.find(Sessions.events_after(session.id), &(&1.type == "model_invocation_started"))

    assert invocation.version == 4
    assert invocation.payload["model"] == "openai:gpt-4o-mini"
    assert invocation.payload["role_contract"] == "alpha-v1"
    assert invocation.payload["toolset_version"] == "workspace-v5"

    assert invocation.payload["model_mapping"]["roles"]["primary"]["sources"]["model"] ==
             "session"
  end

  test "replays a session whose persisted mapping uses numeric contract versions", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    previous_test_pid = Application.get_env(:kodo, :fake_llm_test_pid)
    Application.put_env(:kodo, :fake_llm_test_pid, self())
    on_exit(fn -> restore_env(:fake_llm_test_pid, previous_test_pid) end)
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    [created] = Sessions.events_after(session.id)

    legacy_mapping =
      created.payload["model_mapping"]
      |> Map.delete("profile_version")
      |> Map.put("profile_revision", 4)
      |> update_in(["roles"], fn roles ->
        Map.new(roles, fn {role, mapping} ->
          {role,
           mapping
           |> Map.delete("role_contract")
           |> Map.put("role_contract_version", 4)}
        end)
      end)

    created
    |> Ecto.Changeset.change(payload: Map.put(created.payload, "model_mapping", legacy_mapping))
    |> Repo.update!()

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "capture contract"},
        ownership: ownership
      )

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:llm_request, %LLMDB.Model{provider: :openai}, system, tools, opts}, 5_000
    assert system["content"] == Kodo.Agent.Roles.fetch!(:primary).prompt
    assert tools == Tools.definitions("workspace-v5")
    assert opts[:reasoning] == "none"

    assert_receive {:tool_request, review_request}

    broadcast_success(runner, review_request, %{
      "result" => "output",
      "content" => "clean diff",
      "truncated" => false
    })

    assert {:ok, "The fix is complete."} = Task.await(loop)

    invocation =
      Enum.find(Sessions.events_after(session.id), &(&1.type == "model_invocation_started"))

    assert invocation.payload["model"] == "openai:gpt-4o-mini"
    assert invocation.payload["role_contract"] == "alpha-v1"
    assert invocation.payload["toolset_version"] == "workspace-v5"
  end

  test "does not dispatch a model effect after its ownership epoch is replaced", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "token budget"},
        ownership: ownership
      )

    assert {:ok, replacement} = Sessions.claim_ownership(session.id, nil)
    assert replacement.epoch > ownership.epoch

    assert {:error, :stale_ownership} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets([]),
               ownership: ownership
             )

    refute Enum.any?(Sessions.events_after(session.id), &(&1.type == "model_invocation_started"))
  end

  test "delegates focused read-only investigation and returns only its final evidence", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "delegate search"},
        ownership: ownership
      )

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:tool_request, request}
    assert request["request"]["tool"] == "read_file"

    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner.id}",
      {:runner_tool_response, runner.id,
       %{
         "protocol_version" => 5,
         "request_id" => request["request_id"],
         "status" => "success",
         "response" => %{
           "result" => "file",
           "content" => "helper documentation",
           "offset" => 0,
           "next_offset" => nil,
           "truncated" => false
         }
       }}
    )

    assert_receive {:tool_request, review_request}
    assert review_request["request"]["tool"] == "git_diff"

    broadcast_success(runner, review_request, %{
      "result" => "output",
      "content" => "clean diff",
      "truncated" => false
    })

    assert {:ok, "Used delegated evidence."} = Task.await(loop)

    events = Sessions.events_after(session.id)

    assert Enum.any?(events, fn event ->
             event.type == "subagent_invocation_started" and
               event.payload["role"] == "search" and
               event.payload["model"] == "openai:gpt-4o-mini" and
               event.payload["toolset_version"] == "read-only-v1"
           end)

    assert Enum.any?(events, fn event ->
             event.type == "tool_completed" and
               event.payload["name"] == "delegate_search" and
               event.payload["output"] == %{
                 "result" => "search_evidence",
                 "content" => "README.md:1 contains the requested helper evidence."
               }
           end)
  end

  test "denies search tools outside the persisted read-only toolset", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "delegate unsafe search"},
        ownership: ownership
      )

    assert {:error, {:tool_denied, "apply_patch"}} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets([]),
               ownership: ownership
             )

    refute Enum.any?(Sessions.events_after(session.id), fn event ->
             event.type == "tool_requested" and event.payload["name"] == "apply_patch"
           end)
  end

  test "resumes delegated search without redispatching a completed read", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    Application.put_env(:kodo, :fake_llm_search_resume_pid, self())
    on_exit(fn -> Application.delete_env(:kodo, :fake_llm_search_resume_pid) end)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "delegate search"},
        ownership: ownership
      )

    interrupted =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:tool_request, read_request}

    broadcast_success(runner, read_request, %{
      "result" => "file",
      "content" => "helper documentation",
      "offset" => 0,
      "next_offset" => nil,
      "truncated" => false
    })

    assert_receive :search_continuation_started
    Task.shutdown(interrupted, :brutal_kill)
    Application.delete_env(:kodo, :fake_llm_search_resume_pid)

    resumed =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:tool_request, review_request}
    assert review_request["request"]["tool"] == "git_diff"

    broadcast_success(runner, review_request, %{
      "result" => "output",
      "content" => "clean diff",
      "truncated" => false
    })

    assert {:ok, "Used delegated evidence."} = Task.await(resumed)

    assert Enum.count(Sessions.events_after(session.id), fn event ->
             event.type == "tool_requested" and event.payload["name"] == "read_file"
           end) == 1
  end

  test "reviews the final diff with the persisted review mapping before completion", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)
    previous_review_pid = Application.get_env(:kodo, :fake_llm_review_pid)
    Application.put_env(:kodo, :fake_llm_review_pid, self())
    on_exit(fn -> restore_env(:fake_llm_review_pid, previous_review_pid) end)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "final answer"},
        ownership: ownership
      )

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:tool_request, request}
    assert request["request"] == %{"tool" => "git_diff", "paths" => []}

    broadcast_success(runner, request, %{
      "result" => "output",
      "content" => "clean diff",
      "truncated" => false
    })

    assert_receive {:review_messages, messages}
    review_request = List.last(messages)["content"]
    assert review_request =~ "Original task:\nfinal answer"
    assert review_request =~ "Review this final diff:\n\nclean diff"

    assert {:ok, "Ready for review."} = Task.await(loop)

    assert {:ok, "Ready for review."} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets([]),
               ownership: ownership
             )

    refute_receive {:tool_request, _duplicate_review}

    events = Sessions.events_after(session.id)

    assert Enum.any?(events, fn event ->
             event.type == "review_invocation_started" and
               event.payload["role"] == "review" and
               event.payload["model"] == "openai:gpt-4o-mini" and
               event.payload["role_contract"] == "alpha-v1"
           end)

    assert Enum.any?(events, fn event ->
             event.type == "review_result" and event.payload["clean"] and
               event.payload["findings"] == []
           end)
  end

  test "feeds supported review findings back to primary and reviews the correction", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "final answer"},
        ownership: ownership
      )

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:tool_request, first_review}

    broadcast_success(runner, first_review, %{
      "result" => "output",
      "content" =>
        "diff --git a/lib/example.ex b/lib/example.ex\n--- a/lib/example.ex\n+++ b/lib/example.ex\nREVIEW_FINDING",
      "truncated" => false
    })

    assert_receive {:tool_request, corrected_review}

    broadcast_success(runner, corrected_review, %{
      "result" => "output",
      "content" => "clean corrected diff",
      "truncated" => false
    })

    assert {:ok, "Addressed review findings."} = Task.await(loop)

    events = Sessions.events_after(session.id)
    results = Enum.filter(events, &(&1.type == "review_result"))

    assert Enum.map(results, & &1.payload["clean"]) == [false, true]

    assert Enum.map(
             Enum.filter(events, &(&1.type == "assistant_message_completed")),
             & &1.payload["content"]
           ) == ["Addressed review findings."]

    assert Enum.any?(events, fn event ->
             event.type == "review_feedback" and
               hd(event.payload["findings"])["path"] == "lib/example.ex"
           end)
  end

  test "ownership transfer waits for an in-flight model dispatch boundary", %{
    session: session,
    ownership: ownership
  } do
    previous_test_pid = Application.get_env(:kodo, :fake_llm_test_pid)
    Application.put_env(:kodo, :fake_llm_test_pid, self())

    on_exit(fn -> restore_env(:fake_llm_test_pid, previous_test_pid) end)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "ownership barrier"},
        ownership: ownership
      )

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:model_dispatch_started, dispatch_pid}

    transfer =
      Task.async(fn ->
        Sessions.transfer_ownership(ownership, nil)
      end)

    transfer_before_release =
      receive do
        {ref, result} when ref == transfer.ref -> result
      after
        100 -> :blocked
      end

    send(dispatch_pid, :release_model_dispatch)

    assert transfer_before_release == :blocked
    assert {:ok, replacement} = Task.await(transfer)
    assert replacement.epoch > ownership.epoch
    assert {:error, :stale_ownership} = Task.await(loop)
  end

  test "records a typed tool timeout", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "Fix it"
        },
        ownership: ownership
      )

    assert {:error, :tool_timeout} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(tool_timeout: 0),
               ownership: ownership
             )

    assert Enum.any?(Sessions.events_after(session.id), fn event ->
             event.type == "tool_failed" and event.payload["error"] == ":tool_timeout"
           end)
  end

  test "records malformed successful runner output as a failed tool", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "Fix it"},
        ownership: ownership
      )

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:tool_request, request}

    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner.id}",
      {:runner_tool_response, runner.id,
       %{
         "protocol_version" => 5,
         "request_id" => request["request_id"],
         "status" => "success",
         "response" => "invalid"
       }}
    )

    assert {:error, :invalid_runner_response} = Task.await(loop)

    assert Enum.any?(Sessions.events_after(session.id), fn event ->
             event.type == "tool_failed" and
               event.payload["error"] == ":invalid_runner_response"
           end)
  end

  test "counts interrupted provider attempts against the durable continuation budget", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "Fix it"
        },
        ownership: ownership
      )

    for continuation <- 1..2 do
      {:ok, _event} =
        Sessions.append_event(
          session.id,
          "model_invocation_started",
          %{
            "continuation" => continuation,
            "invocation_id" => Ecto.UUID.generate()
          },
          ownership: ownership
        )
    end

    assert {:error, :continuation_budget_exceeded} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(max_continuations: 2),
               ownership: ownership
             )

    assert Enum.count(
             Sessions.events_after(session.id),
             &(&1.type == "model_invocation_started")
           ) == 2
  end

  test "reserves the final continuation for an answer without tools", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    previous_test_pid = Application.get_env(:kodo, :fake_llm_test_pid)
    Application.put_env(:kodo, :fake_llm_test_pid, self())
    on_exit(fn -> restore_env(:fake_llm_test_pid, previous_test_pid) end)
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "force final turn"},
        ownership: ownership
      )

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets(max_continuations: 2),
          ownership: ownership
        )
      end)

    assert_receive {:tool_request, request}, 1_000
    assert request["request"]["tool"] == "apply_patch"

    broadcast_success(runner, request, %{
      "result" => "files_changed",
      "paths" => ["example.txt"]
    })

    assert_receive {:tool_request, review_request}, 1_000
    assert review_request["request"]["tool"] == "git_diff"

    broadcast_success(runner, review_request, %{
      "result" => "output",
      "content" => "clean diff",
      "truncated" => false
    })

    assert {:ok, "Finished before the budget expired."} = Task.await(loop)
    assert_receive {:final_turn_tools, []}

    assert Enum.any?(Sessions.events_after(session.id), fn event ->
             event.type == "assistant_message_completed" and
               event.payload["content"] == "Finished before the budget expired."
           end)
  end

  test "rejects duplicate provider tool-call ids before dispatch", %{
    session: session,
    ownership: ownership
  } do
    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "duplicate tool ids"
        },
        ownership: ownership
      )

    assert {:error, :invalid_tool_call_ids} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets([]),
               ownership: ownership
             )

    refute Enum.any?(Sessions.events_after(session.id), &(&1.type == "tool_requested"))
  end

  test "records tool results for every call when one call fails", %{
    runner: runner,
    session: session,
    ownership: ownership
  } do
    {:ok, _registration} = Registry.register(Kodo.RunnerRegistry, runner.id, nil)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{
          "role" => "user",
          "content" => "multiple tools"
        },
        ownership: ownership
      )

    assert {:error, :tool_timeout} =
             Loop.run(session.id,
               adapter: Kodo.Test.FakeLLM,
               budgets: budgets(tool_timeout: 0),
               ownership: ownership
             )

    failures = Enum.filter(Sessions.events_after(session.id), &(&1.type == "tool_failed"))
    assert Enum.map(failures, & &1.payload["tool_call_id"]) == ["first", "second"]
  end

  test "rehoming during a multi-tool approval does not persist later calls as skipped", %{
    session: session,
    ownership: ownership
  } do
    {:ok, session} =
      session |> Ecto.Changeset.change(approval_policy: "safe") |> Kodo.Repo.update()

    {:ok, _status} = Sessions.set_status(session.id, "running", "agent", ownership: ownership)

    {:ok, _event} =
      Sessions.append_event(
        session.id,
        "user_message",
        %{"role" => "user", "content" => "multiple tools"},
        ownership: ownership
      )

    :ok = Phoenix.PubSub.subscribe(Kodo.PubSub, "session:#{session.id}")

    loop =
      Task.async(fn ->
        Loop.run(session.id,
          adapter: Kodo.Test.FakeLLM,
          budgets: budgets([]),
          ownership: ownership
        )
      end)

    assert_receive {:session_event, %{type: "approval_requested"}}
    send(loop.pid, :rehoming_requested)
    assert Task.await(loop) == {:error, :rehoming_requested}

    refute Enum.any?(Sessions.events_after(session.id), fn event ->
             event.type == "tool_failed" and event.payload["tool_call_id"] == "second"
           end)
  end

  defp budgets(overrides) do
    Keyword.merge(
      [max_continuations: 8, max_tokens: 1_000, model_timeout: 1_000, tool_timeout: 1_000],
      overrides
    )
  end

  defp broadcast_success(runner, request, response) do
    Phoenix.PubSub.broadcast(
      Kodo.PubSub,
      "runner_responses:#{runner.id}",
      {:runner_tool_response, runner.id,
       %{
         "protocol_version" => 5,
         "request_id" => request["request_id"],
         "status" => "success",
         "response" => response
       }}
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:kodo, key)
  defp restore_env(key, value), do: Application.put_env(:kodo, key, value)
end
