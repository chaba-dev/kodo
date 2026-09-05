defmodule KodoWeb.IntegrationsLive do
  use KodoWeb, :live_view

  alias Kodo.Integrations
  alias Kodo.Integrations.APIKeyValidation

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
    }
  ]
  @providers Enum.map(@provider_configs, & &1.id)
  @actions ~w(connect replace disconnect)
  @max_api_key_bytes 4_096

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kodo.PubSub, "integration:#{socket.assigns.current_scope.user.id}")
    end

    {:ok,
     socket
     |> assign(:action, nil)
     |> assign(:action_provider, nil)
     |> assign(:action_target, nil)
     |> assign(:provider_configs, @provider_configs)
     |> assign(:max_api_key_bytes, @max_api_key_bytes)
     |> assign(:api_key_form, to_form(%{"api_key" => ""}, as: :integration))
     |> assign(:validation_tasks, %{})
     |> load_integrations()}
  end

  @impl true
  def handle_params(%{"provider" => provider, "action" => action}, _uri, socket)
      when provider in @providers and action in @actions do
    open_action(socket, provider, action)
  end

  # Keep existing OpenAI action links valid while provider-qualified links roll out.
  def handle_params(%{"action" => action}, _uri, socket) when action in @actions do
    open_action(socket, "openai", action)
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:action, nil)
     |> assign(:action_provider, nil)
     |> assign(:action_target, nil)
     |> load_integrations()}
  end

  defp open_action(socket, provider, action) do
    socket = load_integrations(socket)

    case action_target(action, integration_for(socket.assigns.integrations, provider)) do
      {:ok, target} ->
        {:noreply,
         socket
         |> assign(:action, action)
         |> assign(:action_provider, provider)
         |> assign(:action_target, target)}

      :error ->
        stale_action(socket)
    end
  end

  @impl true
  def handle_event("save_api_key", %{"integration" => %{"api_key" => api_key}}, socket) do
    with true <- socket.assigns.action in ~w(connect replace),
         :ok <- validate_api_key(api_key),
         {:ok, integration} <- save_api_key(socket, api_key) do
      {:noreply,
       socket
       |> start_validation(integration)
       |> put_flash(
         :info,
         "#{provider_name(socket.assigns.action_provider)} API key saved. Checking access."
       )
       |> push_patch(to: ~p"/integrations")}
    else
      false ->
        stale_action(socket)

      {:error, :invalid_api_key_input} ->
        {:noreply, put_flash(socket, :error, "Enter an API key.")}

      {:error, :integration_already_exists} ->
        stale_action(socket)

      {:error, :stale_credential_generation} ->
        stale_action(socket)

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The API key could not be saved.")}
    end
  end

  def handle_event("check_access", %{"provider" => provider}, socket)
      when provider in @providers do
    socket = load_integrations(socket)

    case integration_for(socket.assigns.integrations, provider) do
      %{connection_status: "connected"} = integration ->
        if validation_running?(socket.assigns.validation_tasks, integration) do
          {:noreply, socket}
        else
          {:noreply, start_validation(socket, integration)}
        end

      _integration ->
        stale_action(socket)
    end
  end

  def handle_event("check_access", _params, socket), do: stale_action(socket)

  def handle_event("disconnect", _params, socket) do
    with provider when provider in @providers <- socket.assigns.action_provider,
         true <- socket.assigns.action == "disconnect",
         %{id: id, credential_generation: generation, connection_status: "connected"} <-
           socket.assigns.action_target,
         {:ok, _integration} <-
           Integrations.disconnect(socket.assigns.current_scope, id, generation) do
      {:noreply,
       socket
       |> put_flash(:info, "#{provider_name(provider)} disconnected from Kodo.")
       |> push_patch(to: ~p"/integrations")}
    else
      false ->
        stale_action(socket)

      nil ->
        stale_action(socket)

      {:error, :stale_credential_generation} ->
        stale_action(socket)

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{provider_name(socket.assigns.action_provider)} could not be disconnected."
         )}
    end
  end

  @impl true
  def handle_info({reference, _result}, socket) when is_reference(reference) do
    if Map.has_key?(socket.assigns.validation_tasks, reference) do
      Process.demonitor(reference, [:flush])
      {:noreply, socket |> drop_validation_task(reference) |> load_integrations()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, socket) do
    if Map.has_key?(socket.assigns.validation_tasks, reference) do
      {:noreply, socket |> drop_validation_task(reference) |> load_integrations()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:integration_validation_finished, _id, _generation}, socket) do
    {:noreply, load_integrations(socket)}
  end

  defp save_api_key(
         %{assigns: %{action: "connect", action_target: :missing}} = socket,
         api_key
       ) do
    Integrations.connect(
      socket.assigns.current_scope,
      socket.assigns.action_provider,
      "api_key",
      %{
        "api_key" => api_key
      }
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
         api_key
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
         api_key
       ) do
    Integrations.replace_credentials(
      socket.assigns.current_scope,
      id,
      generation,
      %{"api_key" => api_key}
    )
  end

  defp save_api_key(_socket, _api_key), do: {:error, :stale_credential_generation}

  defp load_integrations(socket) do
    integrations =
      socket.assigns.current_scope
      |> Integrations.list_integrations()
      |> Map.new(fn integration -> {integration.provider, integration_metadata(integration)} end)

    assign(socket, :integrations, integrations)
  end

  # Browser-facing state needs lifecycle metadata only. In particular, keeping
  # ciphertext in the LiveView would widen credential retention for no benefit.
  defp integration_metadata(integration) do
    Map.take(integration, [
      :id,
      :provider,
      :connection_status,
      :validation_status,
      :credential_generation,
      :validated_at,
      :validation_error_code
    ])
  end

  defp start_validation(socket, integration) do
    task = APIKeyValidation.start(socket.assigns.current_scope, integration)

    update(socket, :validation_tasks, fn tasks ->
      Map.put(tasks, task.ref, {integration.id, integration.credential_generation})
    end)
  end

  defp drop_validation_task(socket, reference) do
    update(socket, :validation_tasks, &Map.delete(&1, reference))
  end

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

  defp action_target("connect", nil), do: {:ok, :missing}

  defp action_target("connect", %{connection_status: "disconnected"} = integration),
    do: {:ok, target_metadata(integration)}

  defp action_target(action, %{connection_status: "connected"} = integration)
       when action in ~w(replace disconnect),
       do: {:ok, target_metadata(integration)}

  defp action_target(_action, _integration), do: :error

  defp target_metadata(integration) do
    Map.take(integration, [:id, :credential_generation, :connection_status])
  end

  defp validation_running?(tasks, %{id: id, credential_generation: generation}) do
    Enum.any?(tasks, fn {_ref, target} -> target == {id, generation} end)
  end

  defp validation_running?(_tasks, _integration), do: false

  defp integration_connected?(%{connection_status: "connected"}), do: true
  defp integration_connected?(_integration), do: false

  defp status_label(nil), do: "Not connected"
  defp status_label(%{connection_status: "connected"}), do: "Connected"
  defp status_label(%{connection_status: "reauthorization_required"}), do: "Action required"
  defp status_label(%{connection_status: "disconnected"}), do: "Disconnected"

  defp validation_label(%{validation_status: "unverified"}), do: "Not checked"
  defp validation_label(%{validation_status: "valid"}), do: "Valid"
  defp validation_label(%{validation_status: "invalid"}), do: "Invalid"
  defp validation_label(%{validation_status: "unavailable"}), do: "Unable to verify"

  defp validation_class(%{validation_status: "valid"}),
    do: "text-green-700 dark:text-green-400"

  defp validation_class(%{validation_status: "invalid"}),
    do: "text-red-700 dark:text-red-400"

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

  defp integration_for(integrations, provider), do: Map.get(integrations, provider)

  defp provider_config(provider) do
    Enum.find(@provider_configs, &(&1.id == provider))
  end

  defp provider_name(provider) do
    case provider_config(provider) do
      %{name: name} -> name
      nil -> "Provider"
    end
  end

  defp action_path(provider, action),
    do: ~p"/integrations?#{[provider: provider, action: action]}"

  defp dom_id(provider, suffix), do: "#{provider}-#{suffix}"

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
        subtitle="Connect the model providers Kodo may use on your behalf. Credentials stay in the control plane."
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
          <div>
            <h2 class="text-base font-semibold text-zinc-950 dark:text-white">Model providers</h2>
            <p class="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-400">
              Connecting a provider does not change existing model routes or billing choices.
            </p>
          </div>

          <%= for provider <- @provider_configs do %>
            <% integration = integration_for(@integrations, provider.id) %>
            <p
              :if={validation_running?(@validation_tasks, integration)}
              id={dom_id(provider.id, "validation-progress")}
              class="flex items-center gap-2 text-xs font-medium text-zinc-500"
              role="status"
            >
              <span class="size-2 animate-pulse rounded-full bg-amber-500"></span> Checking access…
            </p>

            <section
              id={dom_id(provider.id, "integration")}
              class="overflow-hidden rounded-2xl border border-zinc-200/80 bg-zinc-50/70 dark:border-zinc-800 dark:bg-zinc-950/40"
            >
              <div class="flex flex-col gap-5 p-5 sm:p-6 2xl:flex-row 2xl:items-start 2xl:justify-between">
                <div class="flex min-w-0 gap-4">
                  <div class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-zinc-950 text-white shadow-sm dark:bg-white dark:text-zinc-950">
                    <.icon name="hero-sparkles" class="size-5" />
                  </div>
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <h3 class="font-semibold text-zinc-950 dark:text-white">{provider.name}</h3>
                      <span class="rounded-full bg-zinc-200/80 px-2 py-0.5 text-[0.65rem] font-semibold uppercase tracking-wide text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                        {provider.badge}
                      </span>
                    </div>
                    <p class="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-400">
                      {provider.description}
                    </p>
                    <dl
                      id={dom_id(provider.id, "status")}
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
                      id={dom_id(provider.id, "access-detail")}
                      class="mt-2 max-w-xl text-xs leading-5 text-zinc-500 dark:text-zinc-400"
                    >
                      {validation_detail(integration)}
                    </p>
                  </div>
                </div>

                <div :if={!integration_connected?(integration)} class="shrink-0 self-start">
                  <.link
                    id={dom_id(provider.id, "connect")}
                    patch={action_path(provider.id, "connect")}
                    class="inline-flex items-center justify-center rounded-xl bg-zinc-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:-translate-y-0.5 hover:bg-zinc-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-zinc-900 dark:bg-white dark:text-zinc-950 dark:hover:bg-zinc-200"
                  >
                    Connect
                  </.link>
                </div>
                <div
                  :if={integration_connected?(integration)}
                  class="flex shrink-0 flex-wrap gap-2 self-start"
                >
                  <button
                    id={dom_id(provider.id, "check-access")}
                    type="button"
                    phx-click="check_access"
                    phx-value-provider={provider.id}
                    disabled={validation_running?(@validation_tasks, integration)}
                    aria-describedby={dom_id(provider.id, "status")}
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
                    id={dom_id(provider.id, "replace")}
                    patch={action_path(provider.id, "replace")}
                    class="rounded-xl border border-zinc-300 bg-white px-3.5 py-2 text-sm font-semibold text-zinc-700 transition hover:border-zinc-400 hover:text-zinc-950 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:text-white"
                  >
                    Replace
                  </.link>
                  <.link
                    id={dom_id(provider.id, "disconnect")}
                    patch={action_path(provider.id, "disconnect")}
                    class="rounded-xl border border-red-200 bg-white px-3.5 py-2 text-sm font-semibold text-red-700 transition hover:border-red-300 hover:bg-red-50 dark:border-red-950 dark:bg-zinc-900 dark:text-red-400 dark:hover:bg-red-950/30"
                  >
                    Disconnect
                  </.link>
                </div>
              </div>

              <div
                :if={@action_provider == provider.id and @action in ~w(connect replace)}
                id={dom_id(provider.id, "api-key-panel")}
                class="border-t border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900 sm:p-6"
              >
                <h4 class="font-semibold text-zinc-950 dark:text-white">
                  {if(@action == "replace", do: "Replace API key", else: "Connect #{provider.name}")}
                </h4>
                <p class="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-400">
                  The key is encrypted immediately and is never shown again.
                </p>
                <.form
                  for={@api_key_form}
                  id={dom_id(provider.id, "api-key-form")}
                  phx-submit="save_api_key"
                  class="mt-4 max-w-xl"
                >
                  <.input
                    field={@api_key_form[:api_key]}
                    type="password"
                    label={provider.key_label}
                    autocomplete="off"
                    maxlength={@max_api_key_bytes}
                    required
                  />
                  <div class="mt-4 flex flex-wrap justify-end gap-2">
                    <.link
                      patch={~p"/integrations"}
                      class="rounded-xl px-4 py-2.5 text-sm font-semibold text-zinc-600 transition hover:bg-zinc-100 hover:text-zinc-950 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-white"
                    >
                      Cancel
                    </.link>
                    <button
                      id={dom_id(provider.id, "save-api-key")}
                      type="submit"
                      phx-disable-with="Encrypting…"
                      class="rounded-xl bg-zinc-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-zinc-800 disabled:cursor-wait disabled:opacity-60 dark:bg-white dark:text-zinc-950 dark:hover:bg-zinc-200"
                    >
                      Save API key
                    </button>
                  </div>
                </.form>
              </div>

              <div
                :if={@action_provider == provider.id and @action == "disconnect" and integration}
                id={dom_id(provider.id, "disconnect-panel")}
                class="border-t border-red-100 bg-red-50/60 p-5 dark:border-red-950 dark:bg-red-950/20 sm:p-6"
              >
                <h4 class="font-semibold text-zinc-950 dark:text-white">
                  Disconnect {provider.name}?
                </h4>
                <p class="mt-1 max-w-2xl text-sm leading-6 text-zinc-700 dark:text-zinc-300">
                  Future Kodo requests will stop. A provider operation already admitted or sent may finish and may still incur charges.
                  <.link
                    id={dom_id(provider.id, "revoke-key-link")}
                    href={provider.revoke_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="font-semibold text-red-800 underline decoration-red-300 underline-offset-2 hover:text-red-950 dark:text-red-300 dark:hover:text-red-200"
                  >
                    Revoke the key in {provider.name}<span class="sr-only">(opens in a new tab)</span>
                  </.link>
                  if it must stop outside Kodo.
                </p>
                <div class="mt-4 flex flex-wrap justify-end gap-2">
                  <.link
                    patch={~p"/integrations"}
                    class="rounded-xl px-4 py-2.5 text-sm font-semibold text-zinc-600 transition hover:bg-white dark:text-zinc-400 dark:hover:bg-zinc-800"
                  >
                    Keep connected
                  </.link>
                  <button
                    id={dom_id(provider.id, "confirm-disconnect")}
                    type="button"
                    phx-click="disconnect"
                    phx-disable-with="Disconnecting…"
                    class="rounded-xl bg-red-700 px-4 py-2.5 text-sm font-semibold text-white transition hover:bg-red-800 disabled:cursor-wait disabled:opacity-60"
                  >
                    Disconnect
                  </button>
                </div>
              </div>
            </section>
          <% end %>
        </div>
      </Layouts.settings_shell>
    </Layouts.app>
    """
  end
end
