defmodule KodoWeb.IntegrationsLiveTest do
  use KodoWeb.ConnCase, async: false

  import Kodo.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kodo.Cluster.InstanceManager
  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption
  alias Kodo.Integrations.DeviceAuthorizationAttempt
  alias Kodo.Repo
  alias Kodo.Test.FakeDeviceAuthorizationClient
  alias Kodo.Test.FakeRefreshClient

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: Kodo.Accounts.Scope.for_user(user), user: user}
  end

  test "renders an empty authenticated settings page with every provider in the add menu", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/integrations")

    assert has_element?(view, "#settings-shell")
    assert has_element?(view, "#settings-nav-integrations[aria-current='page']")
    assert has_element?(view, "#integrations-empty")
    assert has_element?(view, "#add-integration-menu")

    for {provider, name} <-
          [
            {"openai", "OpenAI API"},
            {"anthropic", "Anthropic"},
            {"openrouter", "OpenRouter"},
            {"openai_codex", "ChatGPT Subscription"}
          ] do
      assert has_element?(view, "#add-#{provider}", name)
    end
  end

  test "requires authentication", %{conn: _conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = build_conn() |> live(~p"/integrations")
  end

  test "normally authenticated sessions can open the add modal", %{user: user} do
    conn =
      build_conn()
      |> log_in_user(user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
      )

    assert {:ok, view, _html} = live(conn, new_path("openai"))
    assert has_element?(view, "#integration-modal [role='dialog'][aria-modal='true']")
    assert has_element?(view, "#integration-api-key-form input[name='integration[display_name]']")
    refute has_element?(view, "#integration-api-key-form[phx-change]")
  end

  test "shows save errors inside the modal alert boundary", %{conn: conn} do
    {:ok, view, _html} = live(conn, new_path("openai"))

    render_submit(view, "save_api_key", %{
      "integration" => %{
        "display_name" => "Account",
        "api_key" => "",
        "modal_token" => live_assign(view, :modal_token)
      }
    })

    assert has_element?(view, "[role='dialog'] #integration-modal-error[role='alert']")
    assert has_element?(view, "#integration-modal-error", "API key")

    assert has_element?(
             view,
             "#integration-api-key-form input[aria-describedby='integration-modal-error']"
           )
  end

  test "an unsupported provider cannot fall back to OpenAI", %{conn: conn} do
    assert {:error,
            {:live_redirect,
             %{
               to: "/integrations",
               flash: %{"error" => "This provider integration is not available."}
             }}} = live(conn, ~p"/integrations?#{[provider: "anthopic", action: "connect"]}")
  end

  test "an account-specific URL without a provider cannot target active OpenAI", %{
    conn: conn,
    scope: scope
  } do
    {:ok, integration} = connect_provider(scope, "openai", "secret", "Personal")

    assert {:error, {:live_redirect, %{to: "/integrations", flash: %{"error" => error}}}} =
             live(conn, ~p"/integrations?#{[action: "replace", integration: integration.id]}")

    assert error =~ "changed in another session"
  end

  test "renders stored ChatGPT subscription accounts", %{
    conn: conn,
    scope: scope
  } do
    {:ok, integration} =
      Integrations.create_oauth_integration(scope, "openai_codex",
        display_name: "Personal subscription"
      )

    assert {:ok, view, _html} = live(conn, ~p"/integrations")
    assert has_element?(view, "#settings-shell")
    assert has_element?(view, card(integration), "Personal subscription")
    assert has_element?(view, "#integration-#{integration.id}-reconnect", "Authorize")
  end

  test "starts, renders, copies, and cancels ChatGPT device authorization", %{
    conn: conn,
    scope: scope
  } do
    owner = self()

    blocking_poll = fn :poll, _payload ->
      send(owner, {:live_device_poll_started, self()})

      receive do
        :finish_poll -> :pending
      end
    end

    _client =
      configure_device_client(
        create: [
          {:ok,
           %{
             payload: %{"device_auth_id" => "private-device", "user_code" => "ABCD-EFGH"},
             polling_interval_ms: 0,
             verification_url: "https://auth.openai.com/codex/device"
           }}
        ],
        poll: [blocking_poll]
      )

    {:ok, view, _html} = live(conn, new_path("openai_codex"))
    assert has_element?(view, "#device-authorization-form")
    refute has_element?(view, "#device-authorization-form input[type='password']")

    view
    |> form("#device-authorization-form", %{
      "integration" => %{"display_name" => "Personal subscription"}
    })
    |> render_submit()

    assert_receive {:live_device_poll_started, poller}
    [integration] = Integrations.list_integrations(scope)
    panel = "#integration-#{integration.id}-device-authorization"

    assert has_element?(view, panel, "https://auth.openai.com/codex/device")
    assert has_element?(view, panel, "ABCD-EFGH")

    assert has_element?(
             view,
             "#integration-#{integration.id}-copy-device-code[data-copy-text='ABCD-EFGH'][aria-label='Copy one-time code']"
           )

    refute inspect(:sys.get_state(view.pid)) =~ "private-device"

    render_click(view, "cancel_device_authorization", %{
      "device_authorization_attempt_id" => Ecto.UUID.generate(),
      "generation" => "1"
    })

    assert Repo.one!(DeviceAuthorizationAttempt).state == "active"
    assert render(view) =~ "changed in another session"

    view
    |> element("#integration-#{integration.id}-cancel-device-authorization")
    |> render_click()

    refute has_element?(view, panel)
    assert Repo.one!(DeviceAuthorizationAttempt).state == "cancelled"

    monitor = Process.monitor(poller)
    send(poller, :finish_poll)
    assert_receive {:DOWN, ^monitor, :process, ^poller, :normal}
  end

  test "device authorization uses the normal aged authenticated boundary", %{
    scope: scope,
    user: user
  } do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")

    _client =
      configure_device_client(
        create: [
          {:ok,
           %{
             payload: %{"device_auth_id" => "device", "user_code" => "CODE"},
             polling_interval_ms: 0,
             verification_url: "https://auth.openai.com/codex/device"
           }}
        ],
        poll: [
          {:ok,
           %{
             "authorization_code" => "authorization",
             "code_challenge" => "challenge",
             "code_verifier" => "verifier"
           }}
        ],
        exchange: [{:ok, device_tokens()}]
      )

    conn =
      build_conn()
      |> log_in_user(user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
      )

    {:ok, view, _html} = live(conn, new_path("openai_codex"))

    view
    |> form("#device-authorization-form", %{
      "integration" => %{"display_name" => "Aged session"}
    })
    |> render_submit()

    assert_receive {:integration_changed, integration_id, _generation}
    assert {:ok, integration} = Integrations.get_integration(scope, integration_id)
    assert integration.connection_status == "connected"
  end

  test "removes an expired one-time code when the page loads", %{conn: conn, scope: scope} do
    assert {:ok, integration} =
             Integrations.create_oauth_integration(scope, "openai_codex",
               display_name: "Expired attempt"
             )

    assert {:ok, attempt} =
             Integrations.begin_device_authorization(
               scope,
               integration.id,
               integration.credential_generation,
               %{"device_auth_id" => "expired-device", "user_code" => "EXPIRED"},
               0
             )

    Repo.update!(
      Ecto.Changeset.change(attempt,
        provider_deadline: DateTime.add(DateTime.utc_now(), -1, :second)
      )
    )

    {:ok, view, _html} = live(conn, ~p"/integrations")
    refute has_element?(view, "#integration-#{integration.id}-device-authorization")
    assert Repo.reload!(attempt).state == "expired"
  end

  test "resumes an exchange-stage authorization after its worker lease expires", %{
    conn: conn,
    scope: scope
  } do
    owner = self()

    blocking_exchange = fn :exchange, _payload ->
      send(owner, {:exchange_resumed, self()})

      receive do
        :finish_exchange -> {:ok, device_tokens()}
      end
    end

    _client = configure_device_client(exchange: [blocking_exchange])
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")

    assert {:ok, integration} =
             Integrations.create_oauth_integration(scope, "openai_codex",
               display_name: "Recovering subscription"
             )

    assert {:ok, _attempt} =
             Integrations.begin_device_authorization(
               scope,
               integration.id,
               integration.credential_generation,
               %{"device_auth_id" => "device", "user_code" => "CODE"},
               0
             )

    assert {:ok, {claim, _payload}} =
             Integrations.claim_device_authorization(scope, integration.id, Ecto.UUID.generate())

    assert {:ok, persisted} =
             Integrations.store_device_authorization_exchange(scope, claim, %{
               "authorization_code" => "authorization",
               "code_challenge" => "challenge",
               "code_verifier" => "verifier"
             })

    Repo.update!(
      Ecto.Changeset.change(persisted,
        claim_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      )
    )

    {:ok, view, _html} = live(conn, ~p"/integrations")
    assert_receive {:exchange_resumed, worker}

    panel = "#integration-#{integration.id}-device-authorization"
    assert has_element?(view, panel, "Completing OpenAI authorization")
    assert has_element?(view, panel, "Securely exchanging credentials")
    refute has_element?(view, "#integration-#{integration.id}-copy-device-code")

    send(worker, :finish_exchange)
    integration_id = integration.id
    assert_receive message = {:integration_changed, ^integration_id, _generation}
    send(view.pid, message)
    _ = :sys.get_state(view.pid)

    assert {:ok, connected} = Integrations.get_integration(scope, integration.id)
    assert connected.connection_status == "connected"
    refute has_element?(view, panel)
  end

  test "cancelling authorization removes its code from another open tab", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    assert {:ok, integration} =
             Integrations.create_oauth_integration(scope, "openai_codex",
               display_name: "Shared subscription"
             )

    assert {:ok, attempt} =
             Integrations.begin_device_authorization(
               scope,
               integration.id,
               integration.credential_generation,
               %{"device_auth_id" => "device", "user_code" => "SHARED"},
               30_000
             )

    {:ok, first_view, _html} = live(conn, ~p"/integrations")
    {:ok, second_view, _html} = live(log_in_user(build_conn(), user), ~p"/integrations")
    panel = "#integration-#{integration.id}-device-authorization"
    assert has_element?(first_view, panel, "SHARED")
    assert has_element?(second_view, panel, "SHARED")

    first_view
    |> element("#integration-#{integration.id}-cancel-device-authorization")
    |> render_click()

    _ = :sys.get_state(second_view.pid)
    refute has_element?(second_view, panel)
    assert Repo.reload!(attempt).state == "cancelled"
  end

  test "shows completion and reauthorization after the device flow succeeds", %{
    conn: conn,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")

    _client =
      configure_device_client(
        create: [
          {:ok,
           %{
             payload: %{"device_auth_id" => "device", "user_code" => "CODE"},
             polling_interval_ms: 0,
             verification_url: "https://auth.openai.com/codex/device"
           }}
        ],
        poll: [
          {:ok,
           %{
             "authorization_code" => "authorization",
             "code_challenge" => "challenge",
             "code_verifier" => "verifier"
           }}
        ],
        exchange: [{:ok, device_tokens()}]
      )

    {:ok, view, _html} = live(conn, new_path("openai_codex"))

    view
    |> form("#device-authorization-form", %{
      "integration" => %{"display_name" => "Completed subscription"}
    })
    |> render_submit()

    assert_receive {:integration_changed, integration_id, _generation}
    _ = :sys.get_state(view.pid)
    assert {:ok, integration} = Integrations.get_integration(scope, integration_id)
    assert integration.connection_status == "connected"
    assert has_element?(view, card(integration), "Completed subscription")
    assert has_element?(view, check_button(integration), "Check access")
    assert has_element?(view, "#integration-#{integration.id}-reauthorize", "Reauthorize")
    refute has_element?(view, "#integration-#{integration.id}-device-authorization")

    view
    |> element("#integration-#{integration.id}-reauthorize")
    |> render_click()

    assert has_element?(view, "#device-authorization-form")
    assert has_element?(view, "#integration-modal-title", "Reauthorize Completed subscription")

    render_patch(view, ~p"/integrations")
    _refresh_client = configure_refresh_client([{:ok, device_tokens()}])
    view |> element(check_button(integration)) |> render_click()
    finish_validation(view)
    assert has_element?(view, "#{status(integration)} dd.text-green-700", "Valid")
  end

  test "offers recovery and disconnect actions when ChatGPT authorization is required", %{
    conn: conn,
    scope: scope
  } do
    assert {:ok, integration} =
             Integrations.create_oauth_integration(scope, "openai_codex",
               display_name: "Expired subscription"
             )

    assert {:ok, connected} =
             Integrations.oauth_succeeded(scope, integration.id, 0, %{
               "access_token" => "access",
               "refresh_token" => "refresh"
             })

    assert {:ok, required} =
             Integrations.refresh_invalid_grant(
               scope,
               connected.id,
               connected.credential_generation
             )

    {:ok, view, _html} = live(conn, ~p"/integrations")
    assert has_element?(view, "#integration-#{required.id}-reauthorize", "Reauthorize")
    assert has_element?(view, "#integration-#{required.id}-disconnect", "Disconnect")
    refute has_element?(view, "#integration-#{required.id}-reconnect")

    view |> element("#integration-#{required.id}-reauthorize") |> render_click()
    assert has_element?(view, "#device-authorization-form")
  end

  test "adds multiple accounts for one provider without exposing secrets", %{
    conn: conn,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, view, _html} = live(conn, new_path("openai"))

    submit_new(view, "Work", "valid-work-secret")
    finish_validation(view)

    render_patch(view, new_path("openai"))
    submit_new(view, "Personal", "valid-personal-secret")
    finish_validation(view)

    [first, second] = Integrations.list_integrations(scope)
    assert first.active
    refute second.active
    assert Enum.map([first, second], & &1.display_name) == ["Work", "Personal"]

    assert has_element?(view, card(first), "Work")
    assert has_element?(view, active_badge(first), "Active")
    refute has_element?(view, activate_button(first))
    assert has_element?(view, card(second), "Personal")
    assert has_element?(view, activate_button(second), "Activate")
    refute inspect(:sys.get_state(view.pid)) =~ "valid-personal-secret"

    assert {:ok, %{"api_key" => "valid-work-secret"}} = CredentialEncryption.decrypt(first)
    assert {:ok, %{"api_key" => "valid-personal-secret"}} = CredentialEncryption.decrypt(second)
  end

  test "activates the selected account and deactivates its provider sibling", %{
    conn: conn,
    scope: scope
  } do
    {:ok, first} = connect_provider(scope, "openai", "first-secret", "Work")
    {:ok, second} = connect_provider(scope, "openai", "second-secret", "Personal")
    {:ok, view, _html} = live(conn, ~p"/integrations")

    view |> element(activate_button(second)) |> render_click()

    assert has_element?(view, active_badge(second), "Active")
    assert has_element?(view, activate_button(first), "Activate")
    refute has_element?(view, active_badge(first))

    assert {:ok, persisted_first} = Integrations.get_integration(scope, first.id)
    assert {:ok, persisted_second} = Integrations.get_integration(scope, second.id)
    refute persisted_first.active
    assert persisted_second.active
  end

  test "rejects a stale activation generation", %{conn: conn, scope: scope} do
    {:ok, _first} = connect_provider(scope, "openai", "first-secret", "Work")
    {:ok, second} = connect_provider(scope, "openai", "second-secret", "Personal")
    {:ok, view, _html} = live(conn, ~p"/integrations")

    view
    |> render_click("activate", %{
      "integration" => second.id,
      "generation" => Integer.to_string(second.credential_generation + 1)
    })

    assert {:ok, persisted} = Integrations.get_integration(scope, second.id)
    refute persisted.active
  end

  test "does not expose another user's account through account-specific URLs", %{
    conn: conn
  } do
    other_scope = user_scope_fixture()
    {:ok, integration} = connect_provider(other_scope, "openai", "other-secret", "Other")

    assert {:error,
            {:live_redirect,
             %{
               to: "/integrations",
               flash: %{
                 "error" =>
                   "The integration changed in another session. Review its current state."
               }
             }}} = live(conn, action_path(integration, "replace"))
  end

  test "checks access for the selected account only", %{conn: conn, scope: scope} do
    Application.put_env(:kodo, :fake_api_key_validation_test_pid, self())
    on_exit(fn -> Application.delete_env(:kodo, :fake_api_key_validation_test_pid) end)
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")

    {:ok, first} = connect_provider(scope, "openai", "first-secret", "Work")
    {:ok, second} = connect_provider(scope, "openai", "blocking-manual-check", "Personal")
    {:ok, view, _html} = live(conn, ~p"/integrations")

    view |> element(check_button(second)) |> render_click()

    assert_receive {:validation_probe_started, probe, validation_task}
    assert has_element?(view, "#{check_button(second)}[disabled]", "Checking…")
    assert has_element?(view, progress(second))
    refute has_element?(view, progress(first))
    refute inspect(:sys.get_state(view.pid)) =~ "blocking-manual-check"

    validation_ref = Process.monitor(validation_task)
    send(probe, {:finish_validation_probe, {:ok, 200, %{"data" => []}}})
    second_id = second.id
    assert_receive message = {:integration_validation_finished, ^second_id, _generation}
    send(view.pid, message)
    assert_receive {:DOWN, ^validation_ref, :process, ^validation_task, _reason}
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#{status(second)} dd.text-green-700", "Valid")
    assert has_element?(view, status(first), "Not checked")
  end

  test "rejects stale check-access generations before starting a probe", %{
    conn: conn,
    scope: scope
  } do
    Application.put_env(:kodo, :fake_api_key_validation_test_pid, self())
    on_exit(fn -> Application.delete_env(:kodo, :fake_api_key_validation_test_pid) end)
    {:ok, integration} = connect_provider(scope, "openai", "secret", "Personal")
    {:ok, view, _html} = live(conn, ~p"/integrations")

    render_click(view, "check_access", %{
      "integration" => integration.id,
      "generation" => Integer.to_string(integration.credential_generation + 1)
    })

    refute_receive {:validation_probe_started, _probe, _task}
  end

  test "credential inputs have generation-specific DOM identities", %{conn: conn, scope: scope} do
    {:ok, first} = connect_provider(scope, "openai", "first-secret", "Work")
    {:ok, second} = connect_provider(scope, "openai", "second-secret", "Personal")
    {:ok, view, _html} = live(conn, action_path(first, "replace"))

    first_key = "#integration-openai-replace-#{first.id}-#{first.credential_generation}-key"
    second_key = "#integration-openai-replace-#{second.id}-#{second.credential_generation}-key"
    assert has_element?(view, first_key)

    render_patch(view, action_path(second, "replace"))
    refute has_element?(view, first_key)
    assert has_element?(view, second_key)
  end

  test "a form opened for another provider cannot be submitted after its modal changes", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, new_path("openai"))
    old_token = live_assign(view, :modal_token)

    render_patch(view, new_path("anthropic"))

    render_submit(view, "save_api_key", %{
      "integration" => %{
        "display_name" => "Wrong target",
        "api_key" => "openai-secret",
        "modal_token" => old_token
      }
    })

    assert Integrations.list_integrations(scope) == []
  end

  test "a replacement form cannot write to the account from a newer modal", %{
    conn: conn,
    scope: scope
  } do
    {:ok, openai} = connect_provider(scope, "openai", "openai-secret", "OpenAI")

    {:ok, anthropic} =
      connect_provider(scope, "anthropic", "anthropic-secret", "Anthropic")

    {:ok, view, _html} = live(conn, action_path(openai, "replace"))
    old_token = live_assign(view, :modal_token)
    render_patch(view, action_path(anthropic, "replace"))

    render_submit(view, "save_api_key", %{
      "integration" => %{"api_key" => "wrong-secret", "modal_token" => old_token}
    })

    assert {:ok, %{"api_key" => "openai-secret"}} =
             openai |> Repo.reload!() |> CredentialEncryption.decrypt()

    assert {:ok, %{"api_key" => "anthropic-secret"}} =
             anthropic |> Repo.reload!() |> CredentialEncryption.decrypt()
  end

  test "a disconnect event cannot target the account from a newer modal", %{
    conn: conn,
    scope: scope
  } do
    {:ok, first} = connect_provider(scope, "openai", "first-secret", "Work")
    {:ok, second} = connect_provider(scope, "openai", "second-secret", "Personal")
    {:ok, view, _html} = live(conn, action_path(first, "disconnect"))
    old_token = live_assign(view, :modal_token)

    render_patch(view, action_path(second, "disconnect"))
    render_click(view, "disconnect", %{"modal-token" => old_token})

    assert Repo.reload!(first).connection_status == "connected"
    assert Repo.reload!(second).connection_status == "connected"
  end

  test "activation is reflected in another open settings tab", %{
    conn: conn,
    scope: scope,
    user: user
  } do
    {:ok, first} = connect_provider(scope, "openai", "first-secret", "Work")
    {:ok, second} = connect_provider(scope, "openai", "second-secret", "Personal")
    {:ok, first_view, _html} = live(conn, ~p"/integrations")
    {:ok, second_view, _html} = live(log_in_user(build_conn(), user), ~p"/integrations")

    first_view |> element(activate_button(second)) |> render_click()
    _ = :sys.get_state(second_view.pid)

    assert has_element?(second_view, active_badge(second))
    assert has_element?(second_view, activate_button(first))
  end

  test "shows rejected credentials as invalid in red", %{conn: conn, scope: scope} do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, view, _html} = live(conn, new_path("openai"))

    submit_new(view, "Rejected", "invalid-live-secret")
    assert_receive message = {:integration_validation_finished, id, _generation}
    send(view.pid, message)
    _ = :sys.get_state(view.pid)

    assert {:ok, integration} = Integrations.get_integration(scope, id)
    assert has_element?(view, "#{status(integration)} dd.text-red-700", "Invalid")
    assert has_element?(view, detail(integration), "provider rejected")
  end

  test "replaces only the account named by the URL and fences stale forms", %{
    conn: conn,
    scope: scope
  } do
    {:ok, first} = connect_provider(scope, "openai", "first-secret", "Work")
    {:ok, second} = connect_provider(scope, "openai", "second-secret", "Personal")
    {:ok, view, _html} = live(conn, action_path(second, "replace"))

    assert has_element?(view, "#integration-modal-title", "Personal")
    refute has_element?(view, "#integration-api-key-form input[name='integration[display_name]']")

    assert {:ok, current} =
             Integrations.replace_credentials(
               scope,
               second.id,
               second.credential_generation,
               %{"api_key" => "concurrent-secret"}
             )

    send(view.pid, {:integration_validation_finished, current.id, current.credential_generation})
    _ = :sys.get_state(view.pid)

    view
    |> form("#integration-api-key-form", %{"integration" => %{"api_key" => "stale-secret"}})
    |> render_submit()

    assert {:ok, persisted_first} = Integrations.get_integration(scope, first.id)
    assert {:ok, persisted_second} = Integrations.get_integration(scope, second.id)
    assert {:ok, %{"api_key" => "first-secret"}} = CredentialEncryption.decrypt(persisted_first)

    assert {:ok, %{"api_key" => "concurrent-secret"}} =
             CredentialEncryption.decrypt(persisted_second)
  end

  test "reconnects the selected disconnected account", %{conn: conn, scope: scope} do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, original} = connect_provider(scope, "openai", "first-secret", "Work")

    {:ok, disconnected} =
      Integrations.disconnect(scope, original.id, original.credential_generation)

    {:ok, view, _html} = live(conn, action_path(disconnected, "connect"))

    view
    |> form("#integration-api-key-form", %{
      "integration" => %{"api_key" => "valid-reconnected"}
    })
    |> render_submit()

    original_id = original.id
    assert_receive {:integration_validation_finished, ^original_id, _generation}
    assert {:ok, reconnected} = Integrations.get_integration(scope, original.id)
    assert reconnected.connection_status == "connected"
    assert reconnected.credential_generation == disconnected.credential_generation + 1
  end

  test "disconnecting the active account does not silently activate another", %{
    conn: conn,
    scope: scope
  } do
    {:ok, active} = connect_provider(scope, "openai", "first-secret", "Work")
    {:ok, inactive} = connect_provider(scope, "openai", "second-secret", "Personal")
    {:ok, view, _html} = live(conn, action_path(active, "disconnect"))

    assert has_element?(view, "#disconnect-confirmation", "will have no active account")
    assert has_element?(view, "#disconnect-confirmation", "already admitted or sent")
    assert has_element?(view, "#revoke-key-link[target='_blank'] .sr-only", "opens in a new tab")

    view |> element("#confirm-disconnect") |> render_click()

    assert {:ok, disconnected} = Integrations.get_integration(scope, active.id)
    assert {:ok, still_inactive} = Integrations.get_integration(scope, inactive.id)
    assert disconnected.connection_status == "disconnected"
    refute disconnected.active
    refute still_inactive.active
    assert is_nil(disconnected.encrypted_credentials)
    assert has_element?(view, activate_button(inactive), "Activate")
  end

  test "adds and validates each supported provider independently", %{conn: conn, scope: scope} do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")

    for provider <- ~w(anthropic openrouter) do
      secret = "valid-#{provider}-live-secret"
      {:ok, view, _html} = live(conn, new_path(provider))
      assert has_element?(view, "#integration-api-key-form")

      submit_new(view, "#{provider} account", secret)
      finish_validation(view)

      assert {:ok, integration} = Integrations.get_active_integration_by_provider(scope, provider)
      assert has_element?(view, card(integration), "#{provider} account")
      assert has_element?(view, "#{status(integration)} dd.text-green-700", "Valid")
      assert {:ok, %{"api_key" => ^secret}} = CredentialEncryption.decrypt(integration)
    end
  end

  test "allows saving and disconnecting after sudo mode expires", %{
    conn: conn,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, view, _html} = live(conn, new_path("openai"))
    expire_sudo(view)
    submit_new(view, "Aged session", "valid-aged-secret")
    assert_receive {:integration_validation_finished, id, _generation}

    assert {:ok, integration} = Integrations.get_integration(scope, id)
    render_patch(view, action_path(integration, "disconnect"))
    expire_sudo(view)
    view |> element("#confirm-disconnect") |> render_click()

    assert {:ok, disconnected} = Integrations.get_integration(scope, id)
    assert disconnected.connection_status == "disconnected"
  end

  defp submit_new(view, display_name, key) do
    view
    |> form("#integration-api-key-form", %{
      "integration" => %{"display_name" => display_name, "api_key" => key}
    })
    |> render_submit()
  end

  defp finish_validation(view) do
    assert_receive message = {:integration_validation_finished, _id, _generation}
    send(view.pid, message)
    _ = :sys.get_state(view.pid)
  end

  defp connect_provider(scope, provider, key, display_name) do
    Integrations.connect(scope, provider, "api_key", %{"api_key" => key},
      display_name: display_name
    )
  end

  defp new_path(provider),
    do: ~p"/integrations?#{[provider: provider, action: "connect"]}"

  defp action_path(integration, action),
    do:
      ~p"/integrations?#{[provider: integration.provider, action: action, integration: integration.id]}"

  defp card(integration), do: "#integration-#{integration.id}-card"
  defp status(integration), do: "#integration-#{integration.id}-status"
  defp detail(integration), do: "#integration-#{integration.id}-access-detail"
  defp progress(integration), do: "#integration-#{integration.id}-validation-progress"
  defp active_badge(integration), do: "#integration-#{integration.id}-active-badge"
  defp activate_button(integration), do: "#integration-#{integration.id}-activate"
  defp check_button(integration), do: "#integration-#{integration.id}-check-access"

  defp configure_device_client(responses) do
    start_supervised!(
      {InstanceManager,
       enabled: true, boot_id: Ecto.UUID.generate(), heartbeat_interval: :infinity}
    )

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             responses:
               %{create: [], poll: [], exchange: []}
               |> Map.merge(Map.new(responses)),
             calls: []
           }
         end}
      )

    Application.put_env(:kodo, :device_authorization_client, FakeDeviceAuthorizationClient)
    Application.put_env(:kodo, :fake_device_authorization_client_agent, agent)

    on_exit(fn ->
      Application.delete_env(:kodo, :device_authorization_client)
      Application.delete_env(:kodo, :fake_device_authorization_client_agent)
    end)

    agent
  end

  defp device_tokens do
    %{
      "access_token" =>
        jwt(%{"exp" => DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3_600)}),
      "refresh_token" => "refresh-secret",
      "id_token" =>
        jwt(%{
          "https://api.openai.com/auth" => %{"chatgpt_account_id" => "account-secret"}
        })
    }
  end

  defp configure_refresh_client(responses) do
    agent =
      start_supervised!(
        {Agent, fn -> %{responses: responses, refresh_tokens: []} end},
        id: {:live_refresh_client, System.unique_integer([:positive])}
      )

    Application.put_env(:kodo, :oauth_refresh_client, FakeRefreshClient)
    Application.put_env(:kodo, :fake_refresh_client_agent, agent)

    on_exit(fn ->
      Application.delete_env(:kodo, :oauth_refresh_client)
      Application.delete_env(:kodo, :fake_refresh_client_agent)
    end)

    agent
  end

  defp jwt(claims) do
    encoded = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    "header.#{encoded}.signature"
  end

  defp live_assign(view, name) do
    :sys.get_state(view.pid).socket.assigns[name]
  end

  defp expire_sudo(view) do
    :sys.replace_state(view.pid, fn state ->
      put_in(
        state.socket.assigns.current_scope.user.authenticated_at,
        DateTime.add(DateTime.utc_now(:second), -11, :minute)
      )
    end)
  end
end
