defmodule KodoWeb.IntegrationsLive do
  use KodoWeb, :live_view

  alias Kodo.Integrations
  alias Kodo.Integrations.APIKeyValidation
  alias Kodo.Integrations.DeviceAuthorization
  alias Kodo.Integrations.OAuthAccessValidation

  @provider_configs [
    %{
      id: "openai",
      name: "OpenAI API",
      badge: "Platform billing",
      description: "Use an OpenAI Platform API key for compatible model requests.",
      key_label: "OpenAI API key",
      revoke_url: "https://platform.openai.com/api-keys"
    },
    %{
      id: "anthropic",
      name: "Anthropic",
      badge: "Platform billing",
      description: "Use a workspace-scoped Anthropic Console API key for Claude models.",
      key_label: "Anthropic API key",
      revoke_url: "https://console.anthropic.com/settings/keys"
    },
    %{
      id: "openrouter",
      name: "OpenRouter",
      badge: "Aggregator billing",
      description: "Use an OpenRouter API key for models billed through OpenRouter.",
      key_label: "OpenRouter API key",
      revoke_url: "https://openrouter.ai/settings/keys"
    },
    %{
      id: "openai_codex",
      name: "ChatGPT Subscription",
      badge: "Subscription billing · Beta",
      description:
        "Use an eligible ChatGPT subscription through OpenAI's device authorization flow.",
      key_label: nil,
      revoke_url: "https://chatgpt.com/#settings/Security"
    }
  ]
  @providers Enum.map(@provider_configs, & &1.id)
  @actions ~w(connect replace reauthorize disconnect)
  @max_api_key_bytes 4_096
  @device_authorization_retry_ms 30_100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{socket.assigns.current_scope.user.id}")
    end

    socket =
      socket
      |> assign(:action, nil)
      |> assign(:action_provider, nil)
      |> assign(:action_target, nil)
      |> assign(:modal_token, nil)
      |> assign(:modal_error, nil)
      |> assign(:provider_configs, @provider_configs)
      |> assign(:max_api_key_bytes, @max_api_key_bytes)
      |> assign(:api_key_form, empty_form())
      |> assign(:validation_tasks, %{})
      |> assign(:device_authorization_tasks, %{})
      |> assign(:device_authorization_retries, %{})
      |> load_integrations()

    socket =
      if connected?(socket) do
        {:ok, _deleted_count} = Integrations.cleanup_device_authorizations()
        resume_device_authorizations(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(
        %{"provider" => provider, "action" => action, "integration" => id},
        _uri,
        socket
      )
      when provider in @providers and action in @actions do
    open_existing_action(socket, provider, action, id)
  end

  def handle_params(%{"provider" => provider, "action" => "connect"}, _uri, socket)
      when provider in @providers do
    open_new_action(socket, provider)
  end

  def handle_params(%{"provider" => _provider, "action" => action}, _uri, socket)
      when action in @actions do
    unsupported_provider(socket)
  end

  # Account-specific links must include their provider so they cannot fall
  # through to the legacy OpenAI route and target a different account.
  def handle_params(%{"integration" => _id, "action" => action}, _uri, socket)
      when action in @actions do
    stale_action(socket)
  end

  # Keep the original OpenAI links valid for bookmarks made before integrations
  # became account-specific. New links always carry the integration ID.
  def handle_params(%{"action" => "connect"} = params, _uri, socket)
      when not is_map_key(params, "provider") do
    open_new_action(socket, "openai")
  end

  def handle_params(%{"action" => action} = params, _uri, socket)
      when action in ~w(replace disconnect) and not is_map_key(params, "provider") do
    socket = load_integrations(socket)

    case Enum.find(socket.assigns.integrations, &(&1.provider == "openai" and &1.active)) do
      nil -> stale_action(socket)
      integration -> open_existing_action(socket, "openai", action, integration.id)
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, close_action(socket)}
  end

  defp open_new_action(socket, provider) do
    modal_token = Ecto.UUID.generate()

    {:noreply,
     socket
     |> load_integrations()
     |> assign(:action, "connect")
     |> assign(:action_provider, provider)
     |> assign(:action_target, :new)
     |> assign(:modal_token, modal_token)
     |> assign(:modal_error, nil)
     |> assign(:api_key_form, empty_form(provider_name(provider), modal_token))}
  end

  defp open_existing_action(socket, provider, action, id) do
    socket = load_integrations(socket)

    case Enum.find(socket.assigns.integrations, &(&1.id == id and &1.provider == provider)) do
      nil ->
        stale_action(socket)

      integration ->
        case action_target(action, integration) do
          {:ok, target} ->
            modal_token = Ecto.UUID.generate()

            {:noreply,
             socket
             |> assign(:action, action)
             |> assign(:action_provider, provider)
             |> assign(:action_target, target)
             |> assign(:modal_token, modal_token)
             |> assign(:modal_error, nil)
             |> assign(:api_key_form, empty_form("", modal_token))}

          :error ->
            stale_action(socket)
        end
    end
  end

  @impl true
  def handle_event("save_api_key", %{"integration" => params}, socket) do
    api_key = Map.get(params, "api_key", "")

    with true <- socket.assigns.action in ~w(connect replace),
         true <- modal_token_valid?(socket, params),
         :ok <- validate_api_key(api_key),
         {:ok, integration} <- save_api_key(socket, params) do
      {:noreply,
       socket
       |> start_validation(integration)
       |> put_flash(:info, "#{integration.display_name} saved. Checking access.")
       |> push_patch(to: ~p"/integrations")}
    else
      false ->
        stale_action(socket)

      {:error, :invalid_api_key_input} ->
        {:noreply, assign(socket, :modal_error, "Enter an API key.")}

      {:error, :stale_credential_generation} ->
        stale_action(socket)

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         assign(socket, :modal_error, "Enter an account name between 1 and 80 characters.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :modal_error, "The integration could not be saved. Try again.")}
    end
  end

  def handle_event(
        "check_access",
        %{"integration" => id, "generation" => generation},
        socket
      ) do
    socket = load_integrations(socket)

    case Enum.find(socket.assigns.integrations, &(&1.id == id)) do
      %{connection_status: "connected", credential_generation: current_generation} = integration ->
        cond do
          Integer.to_string(current_generation) != generation -> stale_action(socket)
          validation_running?(socket.assigns.validation_tasks, integration) -> {:noreply, socket}
          true -> {:noreply, start_validation(socket, integration)}
        end

      _integration ->
        stale_action(socket)
    end
  end

  def handle_event("check_access", _params, socket), do: stale_action(socket)

  def handle_event("start_device_authorization", %{"integration" => params}, socket) do
    with true <- socket.assigns.action in ~w(connect reauthorize),
         true <- socket.assigns.action_provider == "openai_codex",
         true <- modal_token_valid?(socket, params),
         {:ok, integration} <- device_authorization_target(socket, params),
         {:ok, started} <-
           DeviceAuthorization.begin(
             socket.assigns.current_scope,
             integration.id,
             integration.credential_generation
           ) do
      {:noreply,
       socket
       |> track_device_authorization_task(started.task, integration.id)
       |> put_flash(:info, "Authorization started. Enter the one-time code with OpenAI.")
       |> push_patch(to: ~p"/integrations")}
    else
      false ->
        stale_action(socket)

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         assign(socket, :modal_error, "Enter an account name between 1 and 80 characters.")}

      {:error, :stale_credential_generation} ->
        stale_action(socket)

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Authorization could not be started. Try again.")
         |> push_patch(to: ~p"/integrations")}
    end
  end

  def handle_event("start_device_authorization", _params, socket), do: stale_action(socket)

  def handle_event(
        "cancel_device_authorization",
        %{"device_authorization_attempt_id" => attempt_id, "generation" => generation},
        socket
      ) do
    with {attempt_generation, ""} <- Integer.parse(generation),
         %{attempt_id: ^attempt_id, attempt_generation: ^attempt_generation} <-
           find_device_authorization(socket.assigns.device_authorizations, attempt_id),
         {:ok, _attempt} <-
           Integrations.cancel_device_authorization(
             socket.assigns.current_scope,
             attempt_id,
             attempt_generation
           ) do
      {:noreply,
       socket
       |> load_integrations()
       |> put_flash(:info, "Authorization cancelled.")}
    else
      _reason -> stale_action(socket)
    end
  end

  def handle_event("cancel_device_authorization", _params, socket), do: stale_action(socket)

  def handle_event("activate", %{"integration" => id, "generation" => generation}, socket) do
    socket = load_integrations(socket)

    with %{connection_status: "connected", credential_generation: current_generation} =
           integration <-
           Enum.find(socket.assigns.integrations, &(&1.id == id)),
         true <- Integer.to_string(current_generation) == generation,
         {:ok, activated} <-
           Integrations.activate(socket.assigns.current_scope, integration.id, current_generation) do
      {:noreply,
       socket
       |> load_integrations()
       |> put_flash(
         :info,
         "#{activated.display_name} is now active for #{provider_name(activated.provider)}."
       )}
    else
      _reason -> stale_action(socket)
    end
  end

  def handle_event("activate", _params, socket), do: stale_action(socket)

  def handle_event("disconnect", %{"modal-token" => modal_token}, socket) do
    with true <- socket.assigns.action == "disconnect",
         true <- modal_token == socket.assigns.modal_token,
         %{id: id, credential_generation: generation, connection_status: connection_status} <-
           socket.assigns.action_target,
         true <- connection_status in ~w(connected reauthorization_required),
         {:ok, integration} <-
           Integrations.disconnect(socket.assigns.current_scope, id, generation) do
      {:noreply,
       socket
       |> put_flash(:info, "#{integration.display_name} disconnected from Kodo.")
       |> push_patch(to: ~p"/integrations")}
    else
      _reason -> stale_action(socket)
    end
  end

  def handle_event("disconnect", _params, socket), do: stale_action(socket)

  @impl true
  def handle_info({reference, _result}, socket) when is_reference(reference) do
    cond do
      Map.has_key?(socket.assigns.validation_tasks, reference) ->
        Process.demonitor(reference, [:flush])
        {:noreply, socket |> drop_validation_task(reference) |> load_integrations()}

      Map.has_key?(socket.assigns.device_authorization_tasks, reference) ->
        Process.demonitor(reference, [:flush])

        {:noreply,
         socket
         |> drop_device_authorization_task(reference)
         |> load_integrations()
         |> resume_device_authorizations()}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, socket) do
    cond do
      Map.has_key?(socket.assigns.validation_tasks, reference) ->
        {:noreply, socket |> drop_validation_task(reference) |> load_integrations()}

      Map.has_key?(socket.assigns.device_authorization_tasks, reference) ->
        {:noreply,
         socket
         |> drop_device_authorization_task(reference)
         |> load_integrations()
         |> resume_device_authorizations()}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:integration_validation_finished, _id, _generation}, socket) do
    {:noreply, load_integrations(socket)}
  end

  def handle_info({:integration_changed, _id, _generation}, socket) do
    {:noreply, load_integrations(socket)}
  end

  def handle_info(
        {:device_authorization_changed, integration_id, attempt_generation, state, _error},
        socket
      ) do
    socket =
      socket
      |> maybe_clear_device_authorization_retry(integration_id, attempt_generation, state)
      |> load_integrations()

    if state == "failed" do
      {:noreply, put_flash(socket, :error, "Authorization failed. Try again.")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:retry_device_authorization, integration_id, attempt_generation}, socket) do
    socket =
      socket
      |> clear_device_authorization_retry(integration_id, attempt_generation)
      |> load_integrations()

    case socket.assigns.device_authorizations[integration_id] do
      %{attempt_generation: ^attempt_generation} ->
        {:noreply, resume_device_authorization(socket, integration_id, attempt_generation, true)}

      _terminal_or_replaced ->
        {:noreply, socket}
    end
  end

  defp save_api_key(
         %{assigns: %{action: "connect", action_target: :new}} = socket,
         %{"api_key" => api_key} = params
       ) do
    Integrations.connect(
      socket.assigns.current_scope,
      socket.assigns.action_provider,
      "api_key",
      %{"api_key" => api_key},
      display_name: Map.get(params, "display_name", "")
    )
  end

  defp save_api_key(
         %{
           assigns: %{
             action: "connect",
             action_target: %{
               id: id,
               credential_generation: generation,
               connection_status: "disconnected"
             }
           }
         } = socket,
         %{"api_key" => api_key}
       ) do
    Integrations.reconnect_api_key(
      socket.assigns.current_scope,
      id,
      generation,
      %{"api_key" => api_key}
    )
  end

  defp save_api_key(
         %{
           assigns: %{
             action: "replace",
             action_target: %{
               id: id,
               credential_generation: generation,
               connection_status: "connected"
             }
           }
         } = socket,
         %{"api_key" => api_key}
       ) do
    Integrations.replace_credentials(
      socket.assigns.current_scope,
      id,
      generation,
      %{"api_key" => api_key}
    )
  end

  defp save_api_key(_socket, _params), do: {:error, :stale_credential_generation}

  defp close_action(socket) do
    socket
    |> assign(:action, nil)
    |> assign(:action_provider, nil)
    |> assign(:action_target, nil)
    |> assign(:modal_token, nil)
    |> assign(:modal_error, nil)
    |> assign(:api_key_form, empty_form())
    |> load_integrations()
  end

  defp load_integrations(socket) do
    integrations =
      socket.assigns.current_scope
      |> Integrations.list_integrations()
      |> Enum.filter(&(&1.provider in @providers))
      |> Enum.map(&integration_metadata/1)

    device_authorizations = load_device_authorizations(socket.assigns.current_scope, integrations)

    socket
    |> assign(:integrations, integrations)
    |> assign(:device_authorizations, device_authorizations)
    |> reconcile_device_authorization_retries()
  end

  defp reconcile_device_authorization_retries(socket) do
    active_keys =
      MapSet.new(socket.assigns.device_authorizations, fn {integration_id, attempt} ->
        {integration_id, attempt.attempt_generation}
      end)

    retries =
      Enum.reduce(socket.assigns.device_authorization_retries, %{}, fn {key, timer}, kept ->
        if MapSet.member?(active_keys, key) do
          Map.put(kept, key, timer)
        else
          Process.cancel_timer(timer)
          kept
        end
      end)

    assign(socket, :device_authorization_retries, retries)
  end

  # Browser-facing state needs lifecycle metadata only. In particular, keeping
  # ciphertext in the LiveView would widen credential retention for no benefit.
  defp integration_metadata(integration) do
    Map.take(integration, [
      :id,
      :provider,
      :authentication_type,
      :display_name,
      :active,
      :connection_status,
      :validation_status,
      :credential_generation,
      :validated_at,
      :validation_error_code,
      :inserted_at
    ])
  end

  defp start_validation(socket, integration) do
    task =
      case integration.authentication_type do
        "oauth" -> OAuthAccessValidation.start(socket.assigns.current_scope, integration)
        "api_key" -> APIKeyValidation.start(socket.assigns.current_scope, integration)
      end

    update(socket, :validation_tasks, fn tasks ->
      Map.put(tasks, task.ref, {integration.id, integration.credential_generation})
    end)
  end

  defp drop_validation_task(socket, reference) do
    update(socket, :validation_tasks, &Map.delete(&1, reference))
  end

  defp track_device_authorization_task(socket, task, integration_id) do
    update(socket, :device_authorization_tasks, fn tasks ->
      Map.put(tasks, task.ref, integration_id)
    end)
  end

  defp drop_device_authorization_task(socket, reference) do
    update(socket, :device_authorization_tasks, &Map.delete(&1, reference))
  end

  defp resume_device_authorizations(socket) do
    Enum.reduce(socket.assigns.device_authorizations, socket, fn {integration_id, attempt}, acc ->
      resume_device_authorization(acc, integration_id, attempt.attempt_generation, true)
    end)
  end

  defp resume_device_authorization(socket, integration_id, attempt_generation, schedule_retry?) do
    case DeviceAuthorization.resume(socket.assigns.current_scope, integration_id) do
      {:ok, task} ->
        socket
        |> clear_device_authorization_retry(integration_id, attempt_generation)
        |> track_device_authorization_task(task, integration_id)

      {:error, :device_authorization_not_claimable} when schedule_retry? ->
        schedule_device_authorization_retry(socket, integration_id, attempt_generation)

      {:error, _reason} ->
        socket
    end
  end

  defp schedule_device_authorization_retry(socket, integration_id, attempt_generation) do
    key = {integration_id, attempt_generation}

    if Map.has_key?(socket.assigns.device_authorization_retries, key) do
      socket
    else
      timer =
        Process.send_after(
          self(),
          {:retry_device_authorization, integration_id, attempt_generation},
          @device_authorization_retry_ms
        )

      update(socket, :device_authorization_retries, &Map.put(&1, key, timer))
    end
  end

  defp maybe_clear_device_authorization_retry(socket, _integration_id, _generation, "active"),
    do: socket

  defp maybe_clear_device_authorization_retry(socket, integration_id, generation, _state),
    do: clear_device_authorization_retry(socket, integration_id, generation)

  defp clear_device_authorization_retry(socket, integration_id, attempt_generation) do
    key = {integration_id, attempt_generation}

    case Map.pop(socket.assigns.device_authorization_retries, key) do
      {nil, retries} ->
        assign(socket, :device_authorization_retries, retries)

      {timer, retries} ->
        Process.cancel_timer(timer)
        assign(socket, :device_authorization_retries, retries)
    end
  end

  defp load_device_authorizations(scope, integrations) do
    integrations
    |> Enum.filter(&(&1.provider == "openai_codex"))
    |> Enum.reduce(%{}, fn integration, attempts ->
      case Integrations.get_active_device_authorization(scope, integration.id) do
        {:ok, {attempt, %{"user_code" => user_code}}} ->
          Map.put(attempts, integration.id, %{
            attempt_id: attempt.id,
            attempt_generation: attempt.attempt_generation,
            stage: :polling,
            user_code: user_code,
            provider_deadline: attempt.provider_deadline
          })

        {:ok, {attempt, %{"authorization_code" => _code}}} ->
          Map.put(attempts, integration.id, %{
            attempt_id: attempt.id,
            attempt_generation: attempt.attempt_generation,
            stage: :exchanging,
            user_code: nil,
            provider_deadline: attempt.provider_deadline
          })

        _missing_or_exchanging ->
          attempts
      end
    end)
  end

  defp find_device_authorization(authorizations, attempt_id) do
    Enum.find_value(authorizations, fn {_integration_id, attempt} ->
      if attempt.attempt_id == attempt_id, do: attempt
    end)
  end

  defp device_authorization_target(
         %{assigns: %{action_target: :new, current_scope: scope}},
         params
       ) do
    Integrations.create_oauth_integration(scope, "openai_codex",
      display_name: Map.get(params, "display_name", "")
    )
  end

  defp device_authorization_target(
         %{assigns: %{action_target: %{provider: "openai_codex"} = integration}},
         _params
       ),
       do: {:ok, integration}

  defp device_authorization_target(_socket, _params),
    do: {:error, :stale_credential_generation}

  defp validate_api_key(api_key)
       when is_binary(api_key) and byte_size(api_key) > 0 and
              byte_size(api_key) <= @max_api_key_bytes,
       do: :ok

  defp validate_api_key(_api_key), do: {:error, :invalid_api_key_input}

  defp stale_action(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "The integration changed in another session. Review its current state.")
     |> push_patch(to: ~p"/integrations")}
  end

  defp unsupported_provider(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "This provider integration is not available.")
     |> push_patch(to: ~p"/integrations")}
  end

  defp action_target("connect", %{connection_status: "disconnected"} = integration),
    do: {:ok, target_metadata(integration)}

  defp action_target(
         "reauthorize",
         %{
           provider: "openai_codex",
           connection_status: connection_status
         } = integration
       )
       when connection_status in ~w(connected reauthorization_required),
       do: {:ok, target_metadata(integration)}

  defp action_target(
         "replace",
         %{authentication_type: "api_key", connection_status: "connected"} = integration
       ),
       do: {:ok, target_metadata(integration)}

  defp action_target("disconnect", %{connection_status: connection_status} = integration)
       when connection_status in ~w(connected reauthorization_required),
       do: {:ok, target_metadata(integration)}

  defp action_target(_action, _integration), do: :error

  defp target_metadata(integration) do
    Map.take(integration, [
      :id,
      :provider,
      :authentication_type,
      :display_name,
      :credential_generation,
      :connection_status,
      :active
    ])
  end

  defp validation_running?(tasks, %{id: id, credential_generation: generation}) do
    Enum.any?(tasks, fn {_ref, target} -> target == {id, generation} end)
  end

  defp validation_running?(_tasks, _integration), do: false

  defp integration_connected?(%{connection_status: "connected"}), do: true
  defp integration_connected?(_integration), do: false

  defp status_label(%{connection_status: "connected"}), do: "Connected"
  defp status_label(%{connection_status: "reauthorization_required"}), do: "Action required"
  defp status_label(%{connection_status: "disconnected"}), do: "Disconnected"

  defp validation_label(%{validation_status: "unverified"}), do: "Not checked"
  defp validation_label(%{validation_status: "valid"}), do: "Valid"
  defp validation_label(%{validation_status: "invalid"}), do: "Invalid"
  defp validation_label(%{validation_status: "unavailable"}), do: "Unable to verify"

  defp validation_class(%{validation_status: "valid"}), do: "text-green-700 dark:text-green-400"
  defp validation_class(%{validation_status: "invalid"}), do: "text-red-700 dark:text-red-400"
  defp validation_class(_integration), do: "text-zinc-900 dark:text-zinc-100"

  defp validation_detail(%{validation_status: "invalid"}) do
    "The provider rejected these credentials. Update the connection and check access again."
  end

  defp validation_detail(%{
         provider: "anthropic",
         validation_status: "unavailable",
         validation_error_code: "workspace_selection_required"
       }) do
    "Kodo supports workspace-scoped Anthropic Console keys. Create one for a workspace, then replace this key."
  end

  defp validation_detail(%{validation_status: "unavailable"}) do
    "We couldn't confirm access right now. The connection remains saved. Try again."
  end

  defp validation_detail(_integration), do: nil

  defp provider_config(provider), do: Enum.find(@provider_configs, &(&1.id == provider))

  defp provider_name(provider) do
    case provider_config(provider) do
      %{name: name} -> name
      nil -> "Provider"
    end
  end

  defp new_action_path(provider),
    do: ~p"/integrations?#{[provider: provider, action: "connect"]}"

  defp action_path(integration, action),
    do:
      ~p"/integrations?#{[provider: integration.provider, action: action, integration: integration.id]}"

  defp dom_id(integration, suffix), do: "integration-#{integration.id}-#{suffix}"

  defp card_selector(integration), do: "##{dom_id(integration, "card")}"

  defp modal_dom_id(provider, action, :new), do: "integration-#{provider}-#{action}-new"

  defp modal_dom_id(provider, action, target) do
    "integration-#{provider}-#{action}-#{target.id}-#{target.credential_generation}"
  end

  defp modal_remove(:new), do: JS.pop_focus()

  defp modal_remove(target) do
    JS.pop_focus() |> JS.focus(to: card_selector(target))
  end

  defp modal_token_valid?(socket, params) do
    Map.get(params, "modal_token") == socket.assigns.modal_token
  end

  defp empty_form(display_name \\ "", modal_token \\ "") do
    to_form(
      %{"display_name" => display_name, "api_key" => "", "modal_token" => modal_token},
      as: :integration
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      content_class=""
      main_class="px-3 py-5 sm:px-6 sm:py-8 lg:px-8"
    >
      <Layouts.settings_shell
        title="Integrations"
        subtitle="Connect the model provider accounts Kodo may use on your behalf. Credentials stay in the control plane."
        return_to={~p"/sessions"}
      >
        <:section
          id="settings-nav-account"
          label="Account"
          icon="hero-user-circle"
          navigate={~p"/users/settings"}
        />
        <:section
          id="settings-nav-integrations"
          label="Integrations"
          icon="hero-link"
          navigate={~p"/integrations"}
          current
        />

        <div id="integration-settings" class="space-y-5">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 class="text-base font-semibold text-zinc-950 dark:text-white">
                Model provider accounts
              </h2>
              <p class="mt-1 max-w-2xl text-sm leading-6 text-zinc-600 dark:text-zinc-400">
                Add multiple accounts and choose which connected account is active for each provider.
              </p>
            </div>
            <details id="add-integration-menu" class="group relative shrink-0">
              <summary class="flex cursor-pointer list-none items-center justify-center gap-2 rounded-xl bg-zinc-950 px-4 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:-translate-y-0.5 hover:bg-zinc-800 dark:bg-white dark:text-zinc-950 dark:hover:bg-zinc-200">
                <.icon name="hero-plus" class="size-4" /> Add integration
              </summary>
              <div class="mt-2 w-64 overflow-hidden rounded-xl border border-zinc-200 bg-white p-1.5 shadow-xl dark:border-zinc-700 dark:bg-zinc-900">
                <.link
                  :for={provider <- @provider_configs}
                  id={"add-#{provider.id}"}
                  patch={new_action_path(provider.id)}
                  phx-click={JS.push_focus()}
                  class="flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-semibold text-zinc-800 transition hover:bg-zinc-100 dark:text-zinc-200 dark:hover:bg-zinc-800"
                >
                  <span class="flex size-8 items-center justify-center rounded-lg bg-zinc-100 dark:bg-zinc-800">
                    <.icon name="hero-sparkles" class="size-4" />
                  </span>
                  {provider.name}
                </.link>
              </div>
            </details>
          </div>

          <div
            :if={@integrations == []}
            id="integrations-empty"
            class="rounded-2xl border border-dashed border-zinc-300 bg-zinc-50/70 px-6 py-12 text-center dark:border-zinc-700 dark:bg-zinc-950/40"
          >
            <div class="mx-auto flex size-11 items-center justify-center rounded-xl bg-white text-zinc-700 shadow-sm ring-1 ring-zinc-200 dark:bg-zinc-900 dark:text-zinc-200 dark:ring-zinc-800">
              <.icon name="hero-link" class="size-5" />
            </div>
            <h3 class="mt-4 font-semibold text-zinc-950 dark:text-white">No integrations yet</h3>
            <p class="mt-1 text-sm text-zinc-500">
              Use Add integration to connect your first provider account.
            </p>
          </div>

          <section
            :for={integration <- @integrations}
            id={dom_id(integration, "card")}
            tabindex="-1"
            class={[
              "overflow-hidden rounded-2xl border bg-white shadow-sm transition dark:bg-zinc-950/40",
              integration.active &&
                "border-emerald-300 ring-1 ring-emerald-200/60 dark:border-emerald-800 dark:ring-emerald-900/60",
              !integration.active && "border-zinc-200/80 dark:border-zinc-800"
            ]}
          >
            <% provider = provider_config(integration.provider) %>
            <p
              :if={validation_running?(@validation_tasks, integration)}
              id={dom_id(integration, "validation-progress")}
              class="flex items-center gap-2 border-b border-amber-100 bg-amber-50 px-5 py-2 text-xs font-medium text-amber-800 dark:border-amber-950 dark:bg-amber-950/30 dark:text-amber-300"
              role="status"
            >
              <span class="size-2 animate-pulse rounded-full bg-amber-500"></span> Checking access…
            </p>
            <div class="flex flex-col gap-5 p-5 sm:p-6 2xl:flex-row 2xl:items-start 2xl:justify-between">
              <div class="flex min-w-0 gap-4">
                <div class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-zinc-950 text-white shadow-sm dark:bg-white dark:text-zinc-950">
                  <.icon name="hero-sparkles" class="size-5" />
                </div>
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="font-semibold text-zinc-950 dark:text-white">
                      {integration.display_name}
                    </h3>
                    <span
                      :if={integration.active}
                      id={dom_id(integration, "active-badge")}
                      class="inline-flex items-center gap-1 rounded-full bg-emerald-100 px-2 py-0.5 text-[0.65rem] font-bold uppercase tracking-wide text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                    >
                      <span class="size-1.5 rounded-full bg-emerald-500"></span> Active
                    </span>
                    <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-[0.65rem] font-semibold uppercase tracking-wide text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                      {provider.name}
                    </span>
                    <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-[0.65rem] font-semibold text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400">
                      {provider.badge}
                    </span>
                  </div>
                  <p class="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-400">
                    {provider.description}
                  </p>
                  <dl
                    id={dom_id(integration, "status")}
                    aria-live="polite"
                    aria-atomic="true"
                    class="mt-3 flex flex-wrap gap-x-5 gap-y-2 text-xs"
                  >
                    <div>
                      <dt class="text-zinc-500">Connection</dt>
                      <dd class="mt-0.5 font-semibold text-zinc-900 dark:text-zinc-100">
                        {status_label(integration)}
                      </dd>
                    </div>
                    <div :if={integration_connected?(integration)}>
                      <dt class="text-zinc-500">Access</dt>
                      <dd class={["mt-0.5 font-semibold", validation_class(integration)]}>
                        {validation_label(integration)}
                      </dd>
                    </div>
                  </dl>
                  <p
                    :if={validation_detail(integration)}
                    id={dom_id(integration, "access-detail")}
                    class="mt-2 max-w-xl text-xs leading-5 text-zinc-500 dark:text-zinc-400"
                  >
                    {validation_detail(integration)}
                  </p>
                  <div
                    :if={authorization = @device_authorizations[integration.id]}
                    id={dom_id(integration, "device-authorization")}
                    class="mt-4 max-w-xl rounded-2xl border border-sky-200 bg-sky-50/80 p-4 dark:border-sky-900 dark:bg-sky-950/30"
                  >
                    <p class="text-xs font-bold uppercase tracking-wider text-sky-800 dark:text-sky-300">
                      {if(authorization.stage == :polling,
                        do: "Waiting for OpenAI authorization",
                        else: "Completing OpenAI authorization"
                      )}
                    </p>
                    <div :if={authorization.stage == :polling} class="mt-3 space-y-3">
                      <div>
                        <p class="text-xs font-medium text-zinc-500">Open this verification page</p>
                        <.link
                          id={dom_id(integration, "device-verification-link")}
                          href="https://auth.openai.com/codex/device"
                          target="_blank"
                          rel="noopener noreferrer"
                          class="mt-1 block break-all text-sm font-semibold text-sky-800 underline decoration-sky-300 underline-offset-2 hover:text-sky-950 dark:text-sky-300 dark:hover:text-sky-200"
                        >
                          https://auth.openai.com/codex/device
                          <span class="sr-only">(opens in a new tab)</span>
                        </.link>
                      </div>
                      <div>
                        <p class="text-xs font-medium text-zinc-500">One-time code</p>
                        <div class="mt-1 flex items-center gap-2">
                          <code class="select-all text-lg font-bold tracking-wider text-zinc-950 dark:text-white">
                            {authorization.user_code}
                          </code>
                          <button
                            id={dom_id(integration, "copy-device-code")}
                            type="button"
                            phx-hook=".CopyDeviceCode"
                            phx-update="ignore"
                            data-copy-text={authorization.user_code}
                            aria-label="Copy one-time code"
                            class="rounded-lg border border-sky-300 bg-white px-2.5 py-1.5 text-xs font-semibold text-sky-800 transition hover:bg-sky-100 dark:border-sky-800 dark:bg-zinc-900 dark:text-sky-300"
                          >
                            Copy
                          </button>
                        </div>
                      </div>
                    </div>
                    <p
                      :if={authorization.stage == :exchanging}
                      role="status"
                      class="mt-3 text-sm text-zinc-600 dark:text-zinc-400"
                    >
                      Authorization was approved. Securely exchanging credentials…
                    </p>
                    <div class="mt-3 flex flex-wrap items-center justify-between gap-3">
                      <p
                        role="status"
                        aria-live="polite"
                        class="text-xs text-zinc-600 dark:text-zinc-400"
                      >
                        Keep this page open. This attempt expires at <time datetime={
                          DateTime.to_iso8601(authorization.provider_deadline)
                        }>
                          {Calendar.strftime(authorization.provider_deadline, "%H:%M UTC")}
                        </time>.
                      </p>
                      <button
                        id={dom_id(integration, "cancel-device-authorization")}
                        type="button"
                        phx-click="cancel_device_authorization"
                        phx-value-device_authorization_attempt_id={authorization.attempt_id}
                        phx-value-generation={authorization.attempt_generation}
                        phx-disable-with="Cancelling…"
                        class="rounded-lg px-3 py-1.5 text-xs font-semibold text-red-700 transition hover:bg-red-100 disabled:opacity-60 dark:text-red-400 dark:hover:bg-red-950/40"
                      >
                        Cancel authorization
                      </button>
                    </div>
                  </div>
                </div>
              </div>

              <div class="flex shrink-0 flex-wrap gap-2 self-start">
                <.link
                  :if={integration.connection_status == "disconnected"}
                  id={dom_id(integration, "reconnect")}
                  patch={action_path(integration, "connect")}
                  phx-click={JS.push_focus()}
                  class="rounded-xl bg-zinc-950 px-3.5 py-2 text-sm font-semibold text-white transition hover:bg-zinc-800 dark:bg-white dark:text-zinc-950 dark:hover:bg-zinc-200"
                >
                  {if(integration.provider == "openai_codex", do: "Authorize", else: "Reconnect")}
                </.link>
                <button
                  :if={integration_connected?(integration) and !integration.active}
                  id={dom_id(integration, "activate")}
                  type="button"
                  phx-click={JS.push("activate") |> JS.focus(to: card_selector(integration))}
                  phx-value-integration={integration.id}
                  phx-value-generation={integration.credential_generation}
                  phx-disable-with="Activating…"
                  class="rounded-xl bg-emerald-700 px-3.5 py-2 text-sm font-semibold text-white transition hover:bg-emerald-800 disabled:cursor-wait disabled:opacity-60"
                >
                  Activate
                </button>
                <button
                  :if={integration_connected?(integration)}
                  id={dom_id(integration, "check-access")}
                  type="button"
                  phx-click="check_access"
                  phx-value-integration={integration.id}
                  phx-value-generation={integration.credential_generation}
                  disabled={validation_running?(@validation_tasks, integration)}
                  aria-describedby={dom_id(integration, "status")}
                  class="inline-flex items-center gap-1.5 rounded-xl border border-zinc-300 bg-white px-3.5 py-2 text-sm font-semibold text-zinc-700 transition hover:border-zinc-400 hover:text-zinc-950 disabled:cursor-wait disabled:opacity-60 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:text-white"
                >
                  <.icon
                    name="hero-arrow-path"
                    class={[
                      "size-4",
                      validation_running?(@validation_tasks, integration) &&
                        "motion-safe:animate-spin"
                    ]}
                  />
                  {if(validation_running?(@validation_tasks, integration),
                    do: "Checking…",
                    else: "Check access"
                  )}
                </button>
                <.link
                  :if={
                    integration_connected?(integration) and
                      integration.authentication_type == "api_key"
                  }
                  id={dom_id(integration, "replace")}
                  patch={action_path(integration, "replace")}
                  phx-click={JS.push_focus()}
                  class="rounded-xl border border-zinc-300 bg-white px-3.5 py-2 text-sm font-semibold text-zinc-700 transition hover:border-zinc-400 hover:text-zinc-950 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:text-white"
                >
                  Replace key
                </.link>
                <.link
                  :if={
                    integration.provider == "openai_codex" and
                      integration.connection_status in ~w(connected reauthorization_required)
                  }
                  id={dom_id(integration, "reauthorize")}
                  patch={action_path(integration, "reauthorize")}
                  phx-click={JS.push_focus()}
                  class="rounded-xl border border-zinc-300 bg-white px-3.5 py-2 text-sm font-semibold text-zinc-700 transition hover:border-zinc-400 hover:text-zinc-950 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:text-white"
                >
                  Reauthorize
                </.link>
                <.link
                  :if={integration.connection_status in ~w(connected reauthorization_required)}
                  id={dom_id(integration, "disconnect")}
                  patch={action_path(integration, "disconnect")}
                  phx-click={JS.push_focus()}
                  class="rounded-xl border border-red-200 bg-white px-3.5 py-2 text-sm font-semibold text-red-700 transition hover:border-red-300 hover:bg-red-50 dark:border-red-950 dark:bg-zinc-900 dark:text-red-400 dark:hover:bg-red-950/30"
                >
                  Disconnect
                </.link>
              </div>
            </div>
          </section>
        </div>

        <div
          :if={@action}
          id="integration-modal"
          class="fixed inset-0 z-50 flex items-end justify-center overflow-y-auto bg-zinc-950/50 p-3 backdrop-blur-sm sm:items-center sm:p-6"
          phx-remove={modal_remove(@action_target)}
        >
          <.focus_wrap
            id={modal_dom_id(@action_provider, @action, @action_target)}
            class="max-h-[calc(100dvh-1.5rem)] w-full max-w-lg overflow-y-auto rounded-2xl bg-white shadow-2xl ring-1 ring-zinc-950/10 dark:bg-zinc-900 dark:ring-white/10 sm:max-h-[calc(100dvh-3rem)]"
            role="dialog"
            aria-modal="true"
            aria-labelledby="integration-modal-title"
            phx-mounted={JS.focus_first()}
            phx-window-keydown={JS.patch(~p"/integrations")}
            phx-key="escape"
          >
            <div class="flex items-start justify-between gap-4 border-b border-zinc-200 px-5 py-4 dark:border-zinc-800 sm:px-6">
              <div>
                <p class="text-xs font-semibold uppercase tracking-wider text-zinc-500">
                  {provider_name(@action_provider)}
                </p>
                <h3
                  id="integration-modal-title"
                  class="mt-1 text-lg font-semibold text-zinc-950 dark:text-white"
                >
                  {modal_title(@action, @action_target)}
                </h3>
              </div>
              <.link
                id="close-integration-modal"
                patch={~p"/integrations"}
                aria-label="Close"
                class="rounded-lg p-2 text-zinc-500 transition hover:bg-zinc-100 hover:text-zinc-950 dark:hover:bg-zinc-800 dark:hover:text-white"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </.link>
            </div>

            <div
              :if={@action in ~w(connect replace) and @action_provider != "openai_codex"}
              class="p-5 sm:p-6"
            >
              <p class="text-sm leading-6 text-zinc-600 dark:text-zinc-400">
                The key is encrypted immediately and is never shown again.
              </p>
              <p
                :if={@modal_error}
                id="integration-modal-error"
                role="alert"
                class="mt-3 rounded-xl bg-red-50 px-3 py-2 text-sm font-medium text-red-800 dark:bg-red-950/30 dark:text-red-300"
              >
                {@modal_error}
              </p>
              <.form
                for={@api_key_form}
                id="integration-api-key-form"
                phx-submit="save_api_key"
                class="mt-4 space-y-4"
              >
                <input
                  type="hidden"
                  name={@api_key_form[:modal_token].name}
                  value={@api_key_form[:modal_token].value}
                />
                <.input
                  :if={@action_target == :new}
                  id={modal_dom_id(@action_provider, @action, @action_target) <> "-name"}
                  field={@api_key_form[:display_name]}
                  type="text"
                  label="Account name"
                  maxlength="80"
                  aria-describedby={@modal_error && "integration-modal-error"}
                  required
                />
                <.input
                  id={modal_dom_id(@action_provider, @action, @action_target) <> "-key"}
                  field={@api_key_form[:api_key]}
                  type="password"
                  label={provider_config(@action_provider).key_label}
                  autocomplete="off"
                  aria-describedby={@modal_error && "integration-modal-error"}
                  maxlength={@max_api_key_bytes}
                  required
                />
                <div class="flex flex-wrap justify-end gap-2 pt-1">
                  <.link
                    patch={~p"/integrations"}
                    class="rounded-xl px-4 py-2.5 text-sm font-semibold text-zinc-600 transition hover:bg-zinc-100 hover:text-zinc-950 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-white"
                  >
                    Cancel
                  </.link>
                  <button
                    id="save-integration"
                    type="submit"
                    phx-disable-with="Encrypting…"
                    class="rounded-xl bg-zinc-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-zinc-800 disabled:cursor-wait disabled:opacity-60 dark:bg-white dark:text-zinc-950 dark:hover:bg-zinc-200"
                  >
                    Save integration
                  </button>
                </div>
              </.form>
            </div>

            <div
              :if={@action_provider == "openai_codex" and @action in ~w(connect reauthorize)}
              class="p-5 sm:p-6"
            >
              <p class="text-sm leading-6 text-zinc-600 dark:text-zinc-400">
                Kodo will show a one-time code for OpenAI's fixed verification page. Approval connects this account using your ChatGPT subscription billing path.
              </p>
              <p
                :if={@modal_error}
                id="integration-modal-error"
                role="alert"
                class="mt-3 rounded-xl bg-red-50 px-3 py-2 text-sm font-medium text-red-800 dark:bg-red-950/30 dark:text-red-300"
              >
                {@modal_error}
              </p>
              <.form
                for={@api_key_form}
                id="device-authorization-form"
                phx-submit="start_device_authorization"
                class="mt-4 space-y-4"
              >
                <input
                  type="hidden"
                  name={@api_key_form[:modal_token].name}
                  value={@api_key_form[:modal_token].value}
                />
                <.input
                  :if={@action_target == :new}
                  id={modal_dom_id(@action_provider, @action, @action_target) <> "-name"}
                  field={@api_key_form[:display_name]}
                  type="text"
                  label="Account name"
                  maxlength="80"
                  aria-describedby={@modal_error && "integration-modal-error"}
                  required
                />
                <div class="flex flex-wrap justify-end gap-2 pt-1">
                  <.link
                    patch={~p"/integrations"}
                    class="rounded-xl px-4 py-2.5 text-sm font-semibold text-zinc-600 transition hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-800"
                  >
                    Cancel
                  </.link>
                  <button
                    id="start-device-authorization"
                    type="submit"
                    phx-disable-with="Starting…"
                    class="rounded-xl bg-zinc-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-zinc-800 disabled:cursor-wait disabled:opacity-60 dark:bg-white dark:text-zinc-950"
                  >
                    Continue with OpenAI
                  </button>
                </div>
              </.form>
            </div>

            <div :if={@action == "disconnect"} id="disconnect-confirmation" class="p-5 sm:p-6">
              <% provider = provider_config(@action_provider) %>
              <p class="text-sm leading-6 text-zinc-700 dark:text-zinc-300">
                Future Kodo requests will stop using this account. A provider operation already admitted or sent may finish and may still incur charges.
                <.link
                  id="revoke-key-link"
                  href={provider.revoke_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-semibold text-red-800 underline decoration-red-300 underline-offset-2 hover:text-red-950 dark:text-red-300 dark:hover:text-red-200"
                >
                  {revoke_action_label(@action_target)} in {provider.name}<span class="sr-only">(opens in a new tab)</span>
                </.link>
                if it must stop outside Kodo.
              </p>
              <p class="mt-3 rounded-xl bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900 dark:bg-amber-950/30 dark:text-amber-200">
                If this account is active when disconnected, {provider.name} will have no active account until you activate another one.
              </p>
              <div class="mt-5 flex flex-wrap justify-end gap-2">
                <.link
                  patch={~p"/integrations"}
                  class="rounded-xl px-4 py-2.5 text-sm font-semibold text-zinc-600 transition hover:bg-zinc-100 dark:text-zinc-400 dark:hover:bg-zinc-800"
                >
                  Keep connected
                </.link>
                <button
                  id="confirm-disconnect"
                  type="button"
                  phx-click="disconnect"
                  phx-value-modal-token={@modal_token}
                  phx-disable-with="Disconnecting…"
                  class="rounded-xl bg-red-700 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-red-800 disabled:cursor-wait disabled:opacity-60"
                >
                  Disconnect account
                </button>
              </div>
            </div>
          </.focus_wrap>
        </div>
      </Layouts.settings_shell>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyDeviceCode">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              await navigator.clipboard.writeText(this.el.dataset.copyText)
              this.el.textContent = "Copied"
              window.setTimeout(() => { this.el.textContent = "Copy" }, 1500)
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp modal_title("connect", :new), do: "Add provider account"
  defp modal_title("connect", target), do: "Reconnect #{target.display_name}"
  defp modal_title("replace", target), do: "Replace key for #{target.display_name}"
  defp modal_title("reauthorize", target), do: "Reauthorize #{target.display_name}"
  defp modal_title("disconnect", target), do: "Disconnect #{target.display_name}?"

  defp revoke_action_label(%{authentication_type: "oauth"}), do: "Revoke account access"
  defp revoke_action_label(_target), do: "Revoke the key"
end
