defmodule Kodo.SessionsTest do
  use Kodo.DataCase

  alias Kodo.Cluster.Instances
  alias Kodo.Runners
  alias Kodo.Sessions
  alias Kodo.Sessions.Session

  import Kodo.AccountsFixtures

  setup do
    scope = user_scope_fixture()

    {:ok, runner} =
      Runners.register(scope, %{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 4,
        capabilities: []
      })

    %{runner: runner, scope: scope}
  end

  test "creates a session with its reconstructible creation event", %{
    runner: runner,
    scope: scope
  } do
    assert {:ok, session} =
             Sessions.create_session(scope, %{
               runner_id: runner.id,
               title: "Fix greeting",
               model: "openai:gpt-4o-mini"
             })

    assert [event] = Sessions.events_after(session.id)
    assert event.sequence == 1
    assert event.type == "session_created"
    assert event.payload["runner_id"] == runner.id
    assert event.payload["approval_policy"] == "standard"
    assert event.payload["status"] == "idle"
    assert event.payload["model_mapping"]["profile"] == "balanced"
    assert event.payload["model_mapping"]["profile_version"] == "alpha-v1"

    assert event.payload["model_mapping"]["roles"]["primary"]["model"] ==
             "openai:gpt-4o-mini"

    assert event.payload["model_mapping"]["roles"]["search"]["sources"]["model"] == "profile"
  end

  test "persists a selected approval policy", %{runner: runner, scope: scope} do
    assert {:ok, session} =
             Sessions.create_session(scope, %{
               runner_id: runner.id,
               title: "Careful changes",
               model: "openai:gpt-4o-mini",
               approval_policy: "safe"
             })

    assert session.approval_policy == "safe"
    assert hd(Sessions.events_after(session.id)).payload["approval_policy"] == "safe"
  end

  test "uses the balanced profile when no session model is selected", %{
    runner: runner,
    scope: scope
  } do
    assert {:ok, session} =
             Sessions.create_session(scope, %{
               runner_id: runner.id,
               title: "Recommended model"
             })

    assert session.model == "openai:gpt-4o-mini"

    mapping = hd(Sessions.events_after(session.id)).payload["model_mapping"]
    assert mapping["profile"] == "balanced"
    assert mapping["profile_version"] == "alpha-v1"
    assert mapping["roles"]["primary"]["sources"]["model"] == "profile"
  end

  test "rejects a present invalid session model instead of using the profile default", %{
    runner: runner,
    scope: scope
  } do
    for model <- [nil, "", 123] do
      assert {:error, changeset} =
               Sessions.create_session(scope, %{
                 runner_id: runner.id,
                 title: "Invalid model",
                 model: model
               })

      assert errors_on(changeset).model != []
    end
  end

  test "lists only the current user's sessions with their runners", %{
    runner: runner,
    scope: scope
  } do
    {:ok, owned} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Owned session",
        model: "test:model"
      })

    other_scope = user_scope_fixture()

    {:ok, other_runner} =
      Runners.register(other_scope, %{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 4,
        capabilities: []
      })

    {:ok, _other} =
      Sessions.create_session(other_scope, %{
        runner_id: other_runner.id,
        title: "Other session",
        model: "test:model"
      })

    assert [%{id: id, runner: %{id: runner_id}}] = Sessions.list_sessions(scope)
    assert id == owned.id
    assert runner_id == runner.id
  end

  test "tracks event activity on the session index", %{runner: runner, scope: scope} do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Activity",
        model: "test:model"
      })

    old_activity = DateTime.add(DateTime.utc_now(), -60, :second)
    session |> Ecto.Changeset.change(updated_at: old_activity) |> Repo.update!()

    assert {:ok, _event} =
             Sessions.append_event(session.id, "assistant_message_started", %{})

    [listed] = Sessions.list_sessions(scope)
    assert DateTime.after?(listed.updated_at, old_activity)
  end

  test "pages session navigation with a stable user-scoped cursor", %{
    runner: runner,
    scope: scope
  } do
    sessions =
      for number <- 1..3 do
        {:ok, session} =
          Sessions.create_session(scope, %{
            runner_id: runner.id,
            title: "Session #{number}",
            model: "test:model"
          })

        timestamp = DateTime.add(~U[2026-01-01 00:00:00.000000Z], number, :second)
        session |> Ecto.Changeset.change(updated_at: timestamp) |> Repo.update!()
      end

    assert {first_page, cursor} = Sessions.list_sessions_page(scope, limit: 2)

    assert Enum.map(first_page, & &1.id) ==
             sessions |> Enum.reverse() |> Enum.take(2) |> Enum.map(& &1.id)

    assert cursor

    assert {second_page, nil} =
             Sessions.list_sessions_page(scope, limit: 2, before: cursor)

    assert Enum.map(second_page, & &1.id) == [hd(sessions).id]
  end

  test "publishes only index-visible changes on the owning user's topic", %{
    runner: runner,
    scope: scope
  } do
    :ok = Sessions.subscribe_index(scope)

    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Scoped updates",
        model: "test:model"
      })

    assert_receive {:session_index_changed, session_id}
    assert session_id == session.id

    {:ok, _event} =
      Sessions.append_event(session.id, "assistant_message_completed", %{
        "role" => "assistant",
        "content" => "No index fields changed"
      })

    refute_receive {:session_index_changed, _session_id}

    {:ok, _status} = Sessions.set_status(session.id, "running")
    assert_receive {:session_index_changed, session_id}
    assert session_id == session.id

    other_scope = user_scope_fixture()

    {:ok, other_runner} =
      Runners.register(other_scope, %{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 4,
        capabilities: []
      })

    {:ok, _other_session} =
      Sessions.create_session(other_scope, %{
        runner_id: other_runner.id,
        title: "Other user",
        model: "test:model"
      })

    refute_receive {:session_index_changed, _session_id}
  end

  test "rejects a session without an owning user", %{runner: runner} do
    changeset =
      Session.create_changeset(%Session{}, %{
        runner_id: runner.id,
        title: "Ownerless",
        model: "test:model"
      })

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).user_id
  end

  test "rejects another user's owned runner", %{runner: runner} do
    other_scope = user_scope_fixture()

    assert {:error, :runner_not_authorized} =
             Sessions.create_session(other_scope, %{
               runner_id: runner.id,
               title: "Unauthorized workspace",
               model: "test:model"
             })
  end

  test "rejects an ownerless legacy runner", %{scope: scope} do
    {:ok, runner} =
      Runners.register(%{
        workspace_root: "/work/#{Ecto.UUID.generate()}",
        platform: "linux",
        architecture: "x86_64",
        runner_version: "0.1.0",
        protocol_version: 4,
        capabilities: []
      })

    assert {:error, :runner_not_authorized} =
             Sessions.create_session(scope, %{
               runner_id: runner.id,
               title: "Cannot claim by UUID",
               model: "test:model"
             })
  end

  test "allocates gap-free event sequences and replays after a cursor", %{
    runner: runner,
    scope: scope
  } do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Replay",
        model: "openai:gpt-4o-mini"
      })

    assert {:ok, second} = Sessions.append_event(session.id, "user_message", %{"content" => "go"})
    assert {:ok, third} = Sessions.append_event(session.id, "assistant_message_started", %{})

    assert [^third] = Sessions.events_after(session.id, second.sequence)
    assert Enum.map(Sessions.events_after(session.id), & &1.sequence) == [1, 2, 3]
  end

  test "persists status and its transition atomically", %{runner: runner, scope: scope} do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Cancel",
        model: "openai:gpt-4o-mini"
      })

    assert {:ok, {%{status: "cancelled"}, event}} =
             Sessions.set_status(session.id, "cancelled", "user")

    assert event.type == "session_status_changed"
    assert event.payload == %{"status" => "cancelled"}
  end

  test "begins a turn with its message and running status in one transaction", %{
    runner: runner,
    scope: scope
  } do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Atomic turn",
        model: "openai:gpt-4o-mini"
      })

    request_id = Ecto.UUID.generate()
    assert {:ok, [message, status]} = Sessions.begin_turn(session.id, "Fix it", request_id)
    assert message.type == "user_message"
    assert status.type == "session_status_changed"
    assert status.sequence == message.sequence + 1
    assert Sessions.get_session!(session.id).status == "running"
    assert {:ok, []} = Sessions.begin_turn(session.id, "Fix it", request_id)

    assert {:error, :turn_in_progress} = Sessions.begin_turn(session.id, "Duplicate")
    assert Enum.count(Sessions.events_after(session.id), &(&1.type == "user_message")) == 1
  end

  test "advances ownership epochs and fences every stale state mutation", %{
    runner: runner,
    scope: scope
  } do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Fenced session",
        model: "test:model"
      })

    {:ok, first_owner} = Instances.register(instance_attrs("kodo@one"))
    {:ok, second_owner} = Instances.register(instance_attrs("kodo@two"))

    assert {:ok, first} = Sessions.claim_ownership(session.id, first_owner.boot_id)
    assert first.epoch == 1
    assert :ok = Sessions.assert_owner(first)
    assert {:error, :session_owned} = Sessions.claim_ownership(session.id, second_owner.boot_id)

    assert {:ok, second} = Sessions.transfer_ownership(first, second_owner.boot_id)
    assert second.epoch == 2
    assert {:error, :stale_ownership} = Sessions.assert_owner(first)
    assert :ok = Sessions.assert_owner(second)

    assert {:error, :stale_ownership} =
             Sessions.append_event(session.id, "user_message", %{"content" => "stale"},
               ownership: first
             )

    assert {:error, :stale_ownership} =
             Sessions.begin_turn(session.id, "stale turn", nil, ownership: first)

    assert {:ok, _event} =
             Sessions.append_event(session.id, "user_message", %{"content" => "current"},
               ownership: second
             )

    persisted = Sessions.get_session!(session.id)
    assert persisted.owner_boot_id == second_owner.boot_id
    assert persisted.ownership_epoch == 2
  end

  test "a new boot takes over a session whose prior owner is stale", %{
    runner: runner,
    scope: scope
  } do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Restart recovery",
        model: "test:model"
      })

    {:ok, old_boot} = Instances.register(instance_attrs("kodo@old"))
    {:ok, new_boot} = Instances.register(instance_attrs("kodo@new"))
    {:ok, old_ownership} = Sessions.claim_ownership(session.id, old_boot.boot_id)

    stale_timestamp = DateTime.add(DateTime.utc_now(), -120, :second)

    Kodo.Cluster.Instance
    |> where([instance], instance.boot_id == ^old_boot.boot_id)
    |> Repo.update_all(set: [last_seen_at: stale_timestamp])

    assert {:ok, new_ownership} =
             Sessions.claim_ownership(session.id, new_boot.boot_id)

    assert new_ownership.epoch > old_ownership.epoch
    assert new_ownership.owner_boot_id == new_boot.boot_id
  end

  test "rejects state mutations and effects after the owner's authoritative heartbeat expires", %{
    runner: runner,
    scope: scope
  } do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Expired owner",
        model: "test:model"
      })

    {:ok, owner} = Instances.register(instance_attrs("kodo@expired"))
    {:ok, ownership} = Sessions.claim_ownership(session.id, owner.boot_id)

    Kodo.Cluster.Instance
    |> where([instance], instance.boot_id == ^owner.boot_id)
    |> Repo.update_all(set: [last_seen_at: DateTime.add(DateTime.utc_now(), -120, :second)])

    assert {:error, :stale_ownership} = Sessions.assert_owner(ownership)

    assert {:error, :stale_ownership} =
             Sessions.append_event(session.id, "user_message", %{"content" => "too late"},
               ownership: ownership
             )

    assert {:error, :stale_ownership} =
             Sessions.dispatch_if_owner(ownership, fn -> send(self(), :dispatched) end)

    refute_receive :dispatched
  end

  test "ownership activation is blocked while an eligible legacy instance lacks fencing", %{
    runner: runner,
    scope: scope
  } do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Mixed rollout",
        model: "test:model"
      })

    {:ok, target} = Instances.register(instance_attrs("kodo@target"))

    {:ok, _legacy} =
      Instances.register(%{
        instance_attrs("kodo@legacy")
        | protocol_capabilities: ["session-events-v1"]
      })

    assert {:error, :ownership_capability_not_cluster_wide} =
             Sessions.claim_ownership(session.id, target.boot_id)
  end

  test "resolves an approval through durable ownership without a local coordinator", %{
    runner: runner,
    scope: scope
  } do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Remote approval",
        model: "test:model"
      })

    {:ok, owner} = Instances.register(instance_attrs("kodo@remote"))
    {:ok, ownership} = Sessions.claim_ownership(session.id, owner.boot_id)
    approval_id = Ecto.UUID.generate()

    {:ok, _status} = Sessions.set_status(session.id, "running", "agent", ownership: ownership)

    assert {:ok, {_request, _status}} =
             Sessions.request_approval(
               session.id,
               %{"approval_id" => approval_id},
               ownership: ownership
             )

    assert Registry.lookup(Kodo.SessionRegistry, session.id) == []

    assert {:ok, {_resolved, _status}} =
             Sessions.resolve_approval(scope, session.id, approval_id, "approved")

    assert Registry.lookup(Kodo.SessionRegistry, session.id) == []
  end

  test "retries session creation by client request id", %{runner: runner, scope: scope} do
    attrs = %{
      runner_id: runner.id,
      title: "Idempotent creation",
      model: "openai:gpt-4o-mini",
      client_request_id: Ecto.UUID.generate()
    }

    assert {:ok, first} = Sessions.create_session(scope, attrs)
    assert {:ok, second} = Sessions.create_session(scope, attrs)
    assert second.id == first.id
  end

  test "only the current durable approval can resolve", %{runner: runner, scope: scope} do
    {:ok, session} =
      Sessions.create_session(scope, %{
        runner_id: runner.id,
        title: "Current approval",
        model: "openai:gpt-4o-mini",
        approval_policy: "safe"
      })

    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    {:ok, _status} = Sessions.set_status(session.id, "running")

    assert {:ok, {_request, _status}} =
             Sessions.request_approval(session.id, %{"approval_id" => first})

    assert {:ok, _cancelled} = Sessions.cancel_session(session.id)
    {:ok, _status} = Sessions.set_status(session.id, "running")

    assert {:ok, {_request, _status}} =
             Sessions.request_approval(session.id, %{"approval_id" => second})

    assert {:error, :approval_not_pending} =
             Sessions.resolve_approval(scope, session.id, first, "approved")

    assert {:ok, {_resolved, _status}} =
             Sessions.resolve_approval(scope, session.id, second, "approved")
  end

  defp instance_attrs(node_name) do
    %{
      boot_id: Ecto.UUID.generate(),
      node_name: node_name,
      artifact_revision: "test-revision",
      deployment_generation: 1,
      ready: true,
      draining: false,
      capacity: 1,
      protocol_capabilities: [
        "session-events-v1",
        "session-ownership-v1",
        "session-placement-v1",
        "session-rehoming-v1"
      ]
    }
  end
end
