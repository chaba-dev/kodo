defmodule KodoWeb.IntegrationsLiveTest do
  use KodoWeb.ConnCase, async: true

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
    refute has_element?(view, "#openai-status", "Validation")
  end

  test "requires authentication", %{conn: _conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             build_conn() |> live(~p"/integrations")
  end

  test "requires fresh sudo before displaying the API-key form", %{user: user} do
    conn =
      build_conn()
      |> log_in_user(user,
        token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
      )

    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/integrations?action=connect")
    assert path == ~p"/users/reauthenticate/openai/connect"
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

    assert_receive {:integration_validation_finished, _id, _generation}
    _ = :sys.get_state(view.pid)
    refute render(view) =~ secret
    refute inspect(:sys.get_state(view.pid)) =~ secret
    refute has_element?(view, "#openai-api-key-panel")
    assert has_element?(view, "#openai-status", "Connected")
    assert has_element?(view, "#openai-status", "Validation unavailable")

    assert {:ok, integration} = Integrations.get_integration_by_provider(scope, "openai")
    assert {:ok, %{"api_key" => ^secret}} = CredentialEncryption.decrypt(integration)
  end

  test "updates the displayed status after asynchronous validation", %{conn: conn, scope: scope} do
    Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{scope.user.id}")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=connect")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "valid-live-secret"}})
    |> render_submit()

    assert_receive {:integration_validation_finished, _id, _generation}
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#openai-status", "Validated")
    refute has_element?(view, "#openai-validation-progress")
  end

  test "replaces a key and clears the form after success", %{conn: conn, scope: scope} do
    {:ok, original} = connect_openai(scope, "first-secret")
    {:ok, view, _html} = live(conn, ~p"/integrations?action=replace")

    view
    |> form("#openai-api-key-form", %{"integration" => %{"api_key" => "replacement-secret"}})
    |> render_submit()

    assert {:ok, replaced} = Integrations.get_integration_by_provider(scope, "openai")
    assert replaced.credential_generation == original.credential_generation + 1

    assert {:ok, %{"api_key" => "replacement-secret"}} =
             CredentialEncryption.decrypt(replaced)

    refute has_element?(view, "#openai-api-key-panel")
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
    refute has_element?(view, "#openai-status", "Validation")
  end

  defp connect_openai(scope, key) do
    Integrations.connect(scope, "openai", "api_key", %{"api_key" => key})
  end
end
