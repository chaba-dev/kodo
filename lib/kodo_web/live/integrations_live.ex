defmodule KodoWeb.IntegrationsLive do
  use KodoWeb, :live_view

  alias Kodo.Accounts
  alias Kodo.Integrations

  @provider "openai"
  @sensitive_actions ~w(connect replace disconnect)
  @max_api_key_bytes 4_096

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:action, nil)
     |> assign(:max_api_key_bytes, @max_api_key_bytes)
     |> assign(:api_key_form, to_form(%{"api_key" => ""}, as: :integration))
     |> load_integration()}
  end

  @impl true
  def handle_params(%{"action" => action}, _uri, socket) when action in @sensitive_actions do
    if sudo_mode?(socket) do
      {:noreply, socket |> assign(:action, action) |> load_integration()}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Re-authenticate before continuing. Your API key was not retained.")
       |> redirect(to: reauthentication_path(action))}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(:action, nil) |> load_integration()}
  end

  @impl true
  def handle_event("save_api_key", %{"integration" => %{"api_key" => api_key}}, socket) do
    with true <- socket.assigns.action in ~w(connect replace),
         true <- sudo_mode?(socket),
         :ok <- validate_api_key(api_key),
         {:ok, _integration} <- save_api_key(socket, api_key) do
      {:noreply,
       socket
       |> put_flash(:info, "OpenAI API key saved. Validation is pending.")
       |> push_patch(to: ~p"/integrations")}
    else
      false ->
        reauthenticate(socket)

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

  def handle_event("disconnect", _params, socket) do
    with true <- socket.assigns.action == "disconnect",
         true <- sudo_mode?(socket),
         %{id: id, credential_generation: generation} <- socket.assigns.integration,
         {:ok, _integration} <-
           Integrations.disconnect(socket.assigns.current_scope, id, generation) do
      {:noreply,
       socket
       |> put_flash(:info, "OpenAI disconnected from Kodo.")
       |> push_patch(to: ~p"/integrations")}
    else
      false ->
        reauthenticate(socket)

      nil ->
        stale_action(socket)

      {:error, :stale_credential_generation} ->
        stale_action(socket)

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "OpenAI could not be disconnected.")}
    end
  end

  defp save_api_key(%{assigns: %{integration: nil}} = socket, api_key) do
    Integrations.connect(socket.assigns.current_scope, @provider, "api_key", %{
      "api_key" => api_key
    })
  end

  defp save_api_key(socket, api_key) do
    integration = socket.assigns.integration

    Integrations.replace_credentials(
      socket.assigns.current_scope,
      integration.id,
      integration.credential_generation,
      %{"api_key" => api_key}
    )
  end

  defp load_integration(socket) do
    integration =
      case Integrations.get_integration_by_provider(socket.assigns.current_scope, @provider) do
        {:ok, integration} -> integration
        {:error, :integration_not_found} -> nil
      end

    assign(socket, :integration, integration)
  end

  defp validate_api_key(api_key)
       when is_binary(api_key) and byte_size(api_key) > 0 and
              byte_size(api_key) <= @max_api_key_bytes,
       do: :ok

  defp validate_api_key(_api_key), do: {:error, :invalid_api_key_input}

  defp sudo_mode?(socket), do: Accounts.sudo_mode?(socket.assigns.current_scope.user, -10)

  defp reauthenticate(socket) do
    action = socket.assigns.action || "connect"

    {:noreply,
     socket
     |> put_flash(:error, "Re-authenticate and enter the API key again.")
     |> redirect(to: reauthentication_path(action))}
  end

  defp stale_action(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "The integration changed in another session. Review its current state.")
     |> push_patch(to: ~p"/integrations")}
  end

  defp reauthentication_path(action),
    do: ~p"/users/reauthenticate/#{@provider}/#{action}"

  defp integration_connected?(%{connection_status: "connected"}), do: true
  defp integration_connected?(_integration), do: false

  defp status_label(nil), do: "Not connected"
  defp status_label(%{connection_status: "connected"}), do: "Connected"
  defp status_label(%{connection_status: "reauthorization_required"}), do: "Action required"
  defp status_label(%{connection_status: "disconnected"}), do: "Disconnected"

  defp validation_label(%{validation_status: "unverified"}), do: "Pending validation"
  defp validation_label(%{validation_status: "valid"}), do: "Validated"
  defp validation_label(%{validation_status: "invalid"}), do: "Invalid credential"
  defp validation_label(%{validation_status: "unavailable"}), do: "Validation unavailable"

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

          <section
            id="openai-integration"
            class="overflow-hidden rounded-2xl border border-zinc-200/80 bg-zinc-50/70 dark:border-zinc-800 dark:bg-zinc-950/40"
          >
            <div class="flex flex-col gap-5 p-5 sm:flex-row sm:items-start sm:justify-between sm:p-6">
              <div class="flex min-w-0 gap-4">
                <div class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-zinc-950 text-white shadow-sm dark:bg-white dark:text-zinc-950">
                  <.icon name="hero-sparkles" class="size-5" />
                </div>
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="font-semibold text-zinc-950 dark:text-white">OpenAI API</h3>
                    <span class="rounded-full bg-zinc-200/80 px-2 py-0.5 text-[0.65rem] font-semibold uppercase tracking-wide text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                      Platform billing
                    </span>
                  </div>
                  <p class="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-400">
                    Use a user-owned OpenAI Platform API key for compatible model requests.
                  </p>
                  <dl id="openai-status" class="mt-3 flex flex-wrap gap-x-5 gap-y-2 text-xs">
                    <div>
                      <dt class="text-zinc-500">Connection</dt>
                      <dd class="mt-0.5 font-semibold text-zinc-900 dark:text-zinc-100">
                        {status_label(@integration)}
                      </dd>
                    </div>
                    <div :if={integration_connected?(@integration)}>
                      <dt class="text-zinc-500">Validation</dt>
                      <dd class="mt-0.5 font-semibold text-zinc-900 dark:text-zinc-100">
                        {validation_label(@integration)}
                      </dd>
                    </div>
                  </dl>
                </div>
              </div>

              <div :if={!integration_connected?(@integration)} class="shrink-0">
                <.link
                  id="openai-connect"
                  patch={~p"/integrations?action=connect"}
                  class="inline-flex items-center justify-center rounded-xl bg-zinc-950 px-4 py-2.5 text-sm font-semibold text-white transition hover:-translate-y-0.5 hover:bg-zinc-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-zinc-900 dark:bg-white dark:text-zinc-950 dark:hover:bg-zinc-200"
                >
                  Connect
                </.link>
              </div>
              <div :if={integration_connected?(@integration)} class="flex shrink-0 gap-2">
                <.link
                  id="openai-replace"
                  patch={~p"/integrations?action=replace"}
                  class="rounded-xl border border-zinc-300 bg-white px-3.5 py-2 text-sm font-semibold text-zinc-700 transition hover:border-zinc-400 hover:text-zinc-950 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:text-white"
                >
                  Replace
                </.link>
                <.link
                  id="openai-disconnect"
                  patch={~p"/integrations?action=disconnect"}
                  class="rounded-xl border border-red-200 bg-white px-3.5 py-2 text-sm font-semibold text-red-700 transition hover:border-red-300 hover:bg-red-50 dark:border-red-950 dark:bg-zinc-900 dark:text-red-400 dark:hover:bg-red-950/30"
                >
                  Disconnect
                </.link>
              </div>
            </div>

            <div
              :if={@action in ~w(connect replace)}
              id="openai-api-key-panel"
              class="border-t border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900 sm:p-6"
            >
              <h4 class="font-semibold text-zinc-950 dark:text-white">
                {if(@action == "replace", do: "Replace API key", else: "Connect OpenAI")}
              </h4>
              <p class="mt-1 text-sm leading-6 text-zinc-600 dark:text-zinc-400">
                The key is encrypted immediately and is never shown again.
              </p>
              <.form
                for={@api_key_form}
                id="openai-api-key-form"
                phx-submit="save_api_key"
                class="mt-4 max-w-xl"
              >
                <.input
                  field={@api_key_form[:api_key]}
                  type="password"
                  label="OpenAI API key"
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
                    id="openai-save-api-key"
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
              :if={@action == "disconnect" and @integration}
              id="openai-disconnect-panel"
              class="border-t border-red-100 bg-red-50/60 p-5 dark:border-red-950 dark:bg-red-950/20 sm:p-6"
            >
              <h4 class="font-semibold text-zinc-950 dark:text-white">Disconnect OpenAI?</h4>
              <p class="mt-1 max-w-2xl text-sm leading-6 text-zinc-700 dark:text-zinc-300">
                Future Kodo requests will stop. A provider operation already admitted or sent may finish and may still incur charges. Revoke the key in OpenAI if it must stop outside Kodo.
              </p>
              <div class="mt-4 flex flex-wrap justify-end gap-2">
                <.link
                  patch={~p"/integrations"}
                  class="rounded-xl px-4 py-2.5 text-sm font-semibold text-zinc-600 transition hover:bg-white dark:text-zinc-400 dark:hover:bg-zinc-800"
                >
                  Keep connected
                </.link>
                <button
                  id="openai-confirm-disconnect"
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
        </div>
      </Layouts.settings_shell>
    </Layouts.app>
    """
  end
end
