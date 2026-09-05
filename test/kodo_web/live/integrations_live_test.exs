defmodule KodoWeb.IntegrationsLiveTest do
  use KodoWeb.ConnCase, async: false

  import Kodo.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Kodo.Integrations
  alias Kodo.Integrations.CredentialEncryption

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: Kodo.Accounts.Scope.for_user(user), user: user}
  end

  test "renders the authenticated settings shell and disconnected OpenAI card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/integrations")

    assert has_element?(view, "#settings-shell")
    assert has_element?(view, "#settings-nav-integrations[aria-current='page']")
    assert has_element?(view, "#settings-nav-account")
    assert has_element?(view, "#openai-integration #openai-connect")
    assert has_element?(view, "#openai-status", "Not connected")
    refute has_element?(view, "#openai-status", "Access")
    assert has_element?(view, "#openai-status[aria-live='polite'][aria-atomic='true']")
  end

  test "requires authentication", %{conn: _conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             build_conn() |> live(~p"/integrations")
  end

  test "allows a normally authenticated session to display the API-key form", %{user: user} do
    conn =
      build_conn()
      |> log_in_user(user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
      )

    assert {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")
    assert has_element?(view, "#openai-api-key-form")
  end

  test "connects without assigning or rendering the submitted key", %{conn: conn, scope: scope} do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")

    assert has_element?(view, "#openai-api-key-form")
    refute has_element?(view, "#openai-api-key-form[phx-change]")

    secret = "openai-live-secret"

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => secret}})
    |> render_submit()

    assert_receive message = {:integration_validation_finished, _id, _generation}
    send(view.pid, message)
    _ = :sys.get_state(view.pid)
    refute render(view) =~ secret
    refute inspect(:sys.get_state(view.pid)) =~ secret
    refute has_element?(view, "#openai-api-key-panel")
    assert has_element?(view, "#openai-status", "Connected")
    assert has_element?(view, "#openai-status", "Unable to verify")
    assert has_element?(view, "#openai-access-detail", "connection remains saved")

    assert {:ok, integration} = Integrations.get_integration_by_provider(scope, "openai")
    assert {:ok, %{"api_key" => ^secret}} = CredentialEncryption.decrypt(integration)
  end

  test "updates the displayed status after asynchronous validation", %{conn: conn, scope: scope} do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "valid-live-secret"}})
    |> render_submit()

    assert_receive message = {:integration_validation_finished, _id, _generation}
    send(view.pid, message)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#openai-status dd.text-green-700", "Valid")
    refute has_element?(view, "#openai-validation-progress")
  end

  test "shows a rejected credential as invalid in red", %{conn: conn, scope: scope} do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "invalid-live-secret"}})
    |> render_submit()

    assert_receive message = {:integration_validation_finished, _id, _generation}
    send(view.pid, message)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#openai-status dd.text-red-700", "Invalid")
  end

  test "checks access again without re-entering or exposing the saved key", %{
    conn: conn,
    scope: scope
  } do
    Application.put_env(:kodo, :fake_api_key_validation_test_pid, self())

    on_exit(fn -> Application.delete_env(:kodo, :fake_api_key_validation_test_pid) end)
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, _integration} = connect_openai(scope, "blocking-manual-check")
    {:ok, view, _html} = live(conn, ~p"/integrations")

    view |> element("#openai-check-access") |> render_click()

    assert_receive {:validation_probe_started, probe, validation_task}
    assert has_element?(view, "#openai-check-access[disabled]", "Checking…")
    assert has_element?(view, "#openai-validation-progress")
    refute inspect(:sys.get_state(view.pid)) =~ "blocking-manual-check"

    validation_ref = Process.monitor(validation_task)
    send(probe, {:finish_validation_probe, {:ok, 200, %{"data" => []}}})
    assert_receive message = {:integration_validation_finished, _id, _generation}
    send(view.pid, message)
    assert_receive {:DOWN, ^validation_ref, :process, ^validation_task, _reason}
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#openai-status dd.text-green-700", "Valid")
    assert has_element?(view, "#openai-check-access:not([disabled])", "Check access")
    refute has_element?(view, "#openai-validation-progress")
  end

  test "replaces a key and clears the form after success", %{conn: conn, scope: scope} do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, original} = connect_openai(scope, "first-secret")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=replace")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "replacement-secret"}})
    |> render_submit()

    assert_receive {:integration_validation_finished, _id, _generation}
    assert {:ok, replaced} = Integrations.get_integration_by_provider(scope, "openai")
    assert replaced.credential_generation == original.credential_generation + 1

    assert {:ok, %{"api_key" => "replacement-secret"}} =
             CredentialEncryption.decrypt(replaced)

    refute has_element?(view, "#openai-api-key-panel")
  end

  test "reconnects a disconnected integration through the connect action", %{
    conn: conn,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, original} = connect_openai(scope, "first-secret")

    {:ok, disconnected} =
      Integrations.disconnect(scope, original.id, original.credential_generation)

    {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "valid-reconnected"}})
    |> render_submit()

    assert_receive {:integration_validation_finished, _id, _generation}
    assert {:ok, reconnected} = Integrations.get_integration(scope, original.id)
    assert reconnected.connection_status == "connected"
    assert reconnected.credential_generation == disconnected.credential_generation + 1

    assert {:ok, %{"api_key" => "valid-reconnected"}} =
             CredentialEncryption.decrypt(reconnected)
  end

  test "generation-fences a stale replacement form", %{conn: conn, scope: scope} do
    {:ok, original} = connect_openai(scope, "first-secret")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=replace")

    assert {:ok, current} =
             Integrations.replace_credentials(
               scope,
               original.id,
               original.credential_generation,
               %{"api_key" => "concurrent-secret"}
             )

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "stale-secret"}})
    |> render_submit()

    assert {:ok, persisted} = Integrations.get_integration_by_provider(scope, "openai")
    assert persisted.credential_generation == current.credential_generation

    assert {:ok, %{"api_key" => "concurrent-secret"}} =
             CredentialEncryption.decrypt(persisted)
  end

  test "does not adopt a replacement generation after a validation refresh", %{
    conn: conn,
    scope: scope
  } do
    {:ok, original} = connect_openai(scope, "first-secret")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=replace")

    {:ok, current} =
      Integrations.replace_credentials(
        scope,
        original.id,
        original.credential_generation,
        %{"api_key" => "concurrent-secret"}
      )

    send(
      view.pid,
      {:integration_validation_finished, current.id, current.credential_generation}
    )

    _ = :sys.get_state(view.pid)

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "stale-secret"}})
    |> render_submit()

    assert {:ok, persisted} = Integrations.get_integration(scope, original.id)
    assert persisted.credential_generation == current.credential_generation

    assert {:ok, %{"api_key" => "concurrent-secret"}} =
             CredentialEncryption.decrypt(persisted)
  end

  test "does not turn an open connect form into replacement after another tab connects", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")
    {:ok, current} = connect_openai(scope, "concurrent-secret")

    send(
      view.pid,
      {:integration_validation_finished, current.id, current.credential_generation}
    )

    _ = :sys.get_state(view.pid)

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "stale-secret"}})
    |> render_submit()

    assert {:ok, persisted} = Integrations.get_integration(scope, current.id)

    assert {:ok, %{"api_key" => "concurrent-secret"}} =
             CredentialEncryption.decrypt(persisted)
  end

  test "does not disconnect a newer credential after a validation refresh", %{
    conn: conn,
    scope: scope
  } do
    {:ok, original} = connect_openai(scope, "first-secret")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=disconnect")

    {:ok, current} =
      Integrations.replace_credentials(
        scope,
        original.id,
        original.credential_generation,
        %{"api_key" => "concurrent-secret"}
      )

    send(
      view.pid,
      {:integration_validation_finished, current.id, current.credential_generation}
    )

    _ = :sys.get_state(view.pid)
    view |> element("#openai-confirm-disconnect") |> render_click()

    assert {:ok, persisted} = Integrations.get_integration(scope, original.id)
    assert persisted.connection_status == "connected"
    assert persisted.credential_generation == current.credential_generation
  end

  test "remains alive when an older validation finishes after a newer task", %{
    conn: conn,
    scope: scope
  } do
    Application.put_env(:kodo, :fake_api_key_validation_test_pid, self())

    on_exit(fn -> Application.delete_env(:kodo, :fake_api_key_validation_test_pid) end)
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")

    {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "blocking-first"}})
    |> render_submit()

    assert_receive {:validation_probe_started, first_probe, first_validation}
    render_patch(view, ~p"/integrations?action=replace")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "blocking-second"}})
    |> render_submit()

    assert_receive {:validation_probe_started, second_probe, second_validation}
    second_validation_ref = Process.monitor(second_validation)
    send(second_probe, {:finish_validation_probe, {:ok, 200, %{"data" => []}}})
    assert_receive {:integration_validation_finished, _id, _generation}
    assert_receive {:DOWN, ^second_validation_ref, :process, ^second_validation, _reason}

    send(first_probe, {:finish_validation_probe, {:ok, 200, %{"data" => []}}})
    first_validation_ref = Process.monitor(first_validation)
    view_ref = Process.monitor(view.pid)
    assert_receive {:DOWN, ^first_validation_ref, :process, ^first_validation, _reason}
    _ = :sys.get_state(view.pid)
    refute_receive {:DOWN, ^view_ref, :process, _, _reason}
  end

  test "does not show obsolete validation progress for the current generation", %{
    conn: conn,
    scope: scope
  } do
    Application.put_env(:kodo, :fake_api_key_validation_test_pid, self())

    on_exit(fn -> Application.delete_env(:kodo, :fake_api_key_validation_test_pid) end)
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")

    {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "blocking-first"}})
    |> render_submit()

    assert_receive {:validation_probe_started, first_probe, first_validation}
    render_patch(view, ~p"/integrations?action=replace")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "blocking-second"}})
    |> render_submit()

    assert_receive {:validation_probe_started, second_probe, _second_validation}
    send(second_probe, {:finish_validation_probe, {:ok, 200, %{"data" => []}}})
    assert_receive message = {:integration_validation_finished, _id, _generation}
    send(view.pid, message)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#openai-status dd.text-green-700", "Valid")
    refute has_element?(view, "#openai-validation-progress")

    first_validation_ref = Process.monitor(first_validation)
    send(first_probe, {:finish_validation_probe, {:ok, 200, %{"data" => []}}})
    assert_receive {:DOWN, ^first_validation_ref, :process, ^first_validation, _reason}
  end

  test "allows saving after the authenticated session leaves sudo mode", %{
    conn: conn,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")
    expire_sudo(view)
    secret = "valid-aged-session-secret"

    response =
      view
      |> form("#openai-api-key-form", %{"integration" => %{"api_key" => secret}})
      |> render_submit()

    assert_receive {:integration_validation_finished, _id, _generation}
    refute inspect(response) =~ secret

    assert {:ok, integration} = Integrations.get_integration_by_provider(scope, "openai")
    assert {:ok, %{"api_key" => ^secret}} = CredentialEncryption.decrypt(integration)
  end

  test "allows disconnecting after the authenticated session leaves sudo mode", %{
    conn: conn,
    scope: scope
  } do
    {:ok, integration} = connect_openai(scope, "disconnect-secret")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=disconnect")
    expire_sudo(view)

    view |> element("#openai-confirm-disconnect") |> render_click()

    assert {:ok, persisted} = Integrations.get_integration(scope, integration.id)
    assert persisted.connection_status == "disconnected"
  end

  test "disconnect confirmation explains admitted requests and clears credentials", %{
    conn: conn,
    scope: scope
  } do
    {:ok, _integration} = connect_openai(scope, "disconnect-secret")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=disconnect")

    assert has_element?(view, "#openai-disconnect-panel", "already admitted or sent")

    assert has_element?(
             view,
             "#openai-revoke-key-link[href='https://platform.openai.com/api-keys'][target='_blank']"
           )

    assert has_element?(view, "#openai-revoke-key-link .sr-only", "opens in a new tab")

    view |> element("#openai-confirm-disconnect") |> render_click()

    assert {:ok, disconnected} = Integrations.get_integration_by_provider(scope, "openai")
    assert disconnected.connection_status == "disconnected"
    assert is_nil(disconnected.encrypted_credentials)
    refute has_element?(view, "#openai-disconnect-panel")
  end

  test "does not show validation state for a disconnected row", %{conn: conn, scope: scope} do
    {:ok, integration} = connect_openai(scope, "disconnected-secret")

    {:ok, _integration} =
      Integrations.disconnect(scope, integration.id, integration.credential_generation)

    {:ok, view, _html} = live(conn, ~p"/integrations")

    assert has_element?(view, "#openai-status", "Disconnected")
    refute has_element?(view, "#openai-status", "Access")
  end

  defp connect_openai(scope, key) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => key})
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
