defmodule KodoWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use KodoWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :content_class, :any, default: "mx-auto max-w-2xl space-y-4"
  attr :main_class, :any, default: "px-3 py-3 sm:px-5 sm:py-5 lg:px-6"
  attr :session_stream, :any, default: nil
  attr :sessions_cursor, :map, default: nil
  attr :selected_session_id, :string, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#f4f6ef] text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100 lg:flex">
      <aside
        :if={@current_scope}
        class="flex flex-wrap border-b border-[#dce2d5] bg-[#eef2e9] dark:border-zinc-800 dark:bg-zinc-900 lg:sticky lg:top-0 lg:h-screen lg:w-80 lg:shrink-0 lg:flex-col lg:flex-nowrap lg:border-b-0 lg:border-r"
      >
        <.link
          navigate={~p"/sessions"}
          class="flex shrink-0 items-center gap-2.5 border-r border-[#dce2d5] px-4 py-3.5 dark:border-zinc-800 lg:border-b lg:border-r-0"
        >
          <span class="flex size-8 items-center justify-center rounded-lg bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900">
            <.icon name="hero-command-line" class="size-4" />
          </span>
          <span class="text-sm font-semibold tracking-tight">Kodo</span>
        </.link>

        <nav
          class="order-last flex min-w-0 basis-full items-center gap-1 overflow-auto border-t border-[#dce2d5] px-3 py-2 dark:border-zinc-800 lg:order-none lg:block lg:basis-auto lg:space-y-1 lg:border-t-0 lg:px-3 lg:py-4"
          aria-label="Application navigation"
        >
          <.link
            navigate={~p"/sessions"}
            class="flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium text-zinc-700 transition hover:bg-white/70 hover:text-zinc-950 dark:text-zinc-300 dark:hover:bg-zinc-800 dark:hover:text-white"
          >
            <.icon name="hero-chat-bubble-left-right" class="size-4 text-zinc-500" />
            <span>Sessions</span>
          </.link>

          <div
            :if={@session_stream}
            id="sessions"
            phx-update="stream"
            aria-label="Session navigation"
            class="flex min-w-56 gap-1 lg:mt-5 lg:block lg:min-w-0 lg:space-y-1"
          >
            <p
              id="sessions-empty"
              class="hidden only:block px-3 py-2 text-xs leading-5 text-zinc-500"
            >
              No sessions yet
            </p>
            <.link
              :for={{dom_id, session} <- @session_stream}
              id={dom_id}
              navigate={~p"/sessions/#{session.id}"}
              aria-current={if(session.id == @selected_session_id, do: "page", else: nil)}
              class={[
                "group block rounded-lg px-3 py-2 transition",
                session.id == @selected_session_id &&
                  "bg-white text-zinc-950 shadow-sm dark:bg-zinc-800 dark:text-white",
                session.id != @selected_session_id &&
                  "text-zinc-600 hover:bg-white/70 hover:text-zinc-950 dark:text-zinc-400 dark:hover:bg-zinc-800 dark:hover:text-white"
              ]}
            >
              <span class="flex items-center gap-2 text-[0.65rem] text-zinc-500">
                <span class={[
                  "size-1.5 rounded-full",
                  if(Kodo.Runners.online?(session.runner_id),
                    do: "bg-emerald-400",
                    else: "bg-zinc-400"
                  )
                ]}></span>
                <span class="sr-only">
                  {if Kodo.Runners.online?(session.runner_id), do: "Online", else: "Offline"}
                </span>
                <span class="truncate">{repository_name(session.runner)}</span>
                <span class="ml-auto capitalize">{String.replace(session.status, "_", " ")}</span>
              </span>
              <span class="mt-1 block truncate text-xs font-medium">{session.title}</span>
            </.link>
          </div>
          <button
            :if={@sessions_cursor}
            id="load-more-sessions"
            type="button"
            phx-click="load_more_sessions"
            phx-value-before-updated-at={DateTime.to_iso8601(@sessions_cursor.updated_at)}
            phx-value-before-id={@sessions_cursor.id}
            class="mt-1 shrink-0 rounded-lg px-3 py-2 text-left text-xs font-medium text-zinc-500 transition hover:bg-white/70 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-white"
          >
            Load older sessions
          </button>
        </nav>

        <div class="ml-auto flex items-center gap-1 px-3 lg:ml-0 lg:border-t lg:border-[#dce2d5] lg:px-3 lg:py-3 dark:lg:border-zinc-800">
          <.link
            navigate={~p"/users/settings"}
            class="min-w-0 flex-1 rounded-lg px-3 py-2 transition hover:bg-white/70 dark:hover:bg-zinc-800"
          >
            <span class="block truncate text-xs font-medium">{@current_scope.user.email}</span>
            <span class="hidden text-[0.65rem] text-zinc-500 lg:block">Account settings</span>
          </.link>
          <div class="shrink-0 scale-75">
            <.theme_toggle />
          </div>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="flex size-8 shrink-0 items-center justify-center rounded-lg text-zinc-500 transition hover:bg-white/70 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-white"
            aria-label="Log out"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
          </.link>
        </div>
      </aside>

      <div class="min-w-0 flex-1">
        <header
          :if={!@current_scope}
          class="flex items-center justify-between border-b border-[#dce2d5] bg-[#f7f8f4] px-4 py-3 sm:px-6 dark:border-zinc-800 dark:bg-zinc-900"
        >
          <.link navigate={~p"/"} class="flex items-center gap-2.5">
            <img src={~p"/images/logo.svg"} width="32" />
            <span class="text-sm font-semibold tracking-tight">Kodo</span>
          </.link>
          <nav class="flex items-center gap-2" aria-label="Account navigation">
            <.link
              href={~p"/users/register"}
              class="rounded-lg px-3 py-2 text-sm font-medium text-zinc-600 transition hover:bg-white hover:text-zinc-950 dark:text-zinc-300 dark:hover:bg-zinc-800 dark:hover:text-white"
            >
              Register
            </.link>
            <.link
              href={~p"/users/log-in"}
              class="rounded-lg bg-zinc-900 px-3 py-2 text-sm font-semibold text-white transition hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white"
            >
              Log in
            </.link>
            <div class="hidden sm:block"><.theme_toggle /></div>
          </nav>
        </header>

        <main class={@main_class}>
          <div class={@content_class}>
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc "Renders the responsive navigation and detail surface shared by user settings pages."
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :return_to, :string, required: true

  slot :section, required: true do
    attr :id, :string, required: true
    attr :label, :string, required: true
    attr :icon, :string, required: true
    attr :navigate, :string, required: true
    attr :current, :boolean
  end

  slot :inner_block, required: true

  def settings_shell(assigns) do
    ~H"""
    <section id="settings-shell" class="mx-auto max-w-6xl">
      <header class="mb-5 flex items-start gap-4 sm:mb-7 sm:items-center">
        <.link
          id="settings-return"
          navigate={@return_to}
          class="mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-xl border border-[#d7ddd0] bg-white text-zinc-500 shadow-sm transition hover:-translate-x-0.5 hover:border-zinc-400 hover:text-zinc-950 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-zinc-900 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400 dark:hover:border-zinc-600 dark:hover:text-white sm:mt-0"
          aria-label="Return to sessions"
        >
          <.icon name="hero-arrow-left" class="size-4" />
        </.link>
        <div class="min-w-0">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-emerald-700 dark:text-emerald-400">
            Settings
          </p>
          <h1 class="mt-1 text-2xl font-semibold tracking-tight text-zinc-950 dark:text-white sm:text-3xl">
            {@title}
          </h1>
          <p class="mt-1 max-w-2xl text-sm leading-6 text-zinc-600 dark:text-zinc-400">
            {@subtitle}
          </p>
        </div>
      </header>

      <div class="overflow-hidden rounded-2xl border border-[#d7ddd0] bg-white shadow-[0_18px_55px_-38px_rgba(24,24,27,0.45)] dark:border-zinc-800 dark:bg-zinc-900 lg:grid lg:min-h-[34rem] lg:grid-cols-[13rem_minmax(0,1fr)]">
        <nav
          id="settings-sections"
          aria-label="Settings sections"
          class="flex gap-1 overflow-x-auto border-b border-[#e2e7dc] bg-[#f8faf5] p-2 dark:border-zinc-800 dark:bg-zinc-900/70 lg:block lg:space-y-1 lg:border-b-0 lg:border-r lg:p-3"
        >
          <.link
            :for={section <- @section}
            id={section.id}
            navigate={section.navigate}
            aria-current={if(section[:current], do: "page", else: nil)}
            class={[
              "group flex shrink-0 items-center gap-2.5 rounded-xl px-3 py-2.5 text-sm font-medium transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-zinc-900 lg:w-full",
              section[:current] &&
                "bg-white text-zinc-950 shadow-sm ring-1 ring-zinc-950/5 dark:bg-zinc-800 dark:text-white dark:ring-white/10",
              !section[:current] &&
                "text-zinc-600 hover:bg-white/70 hover:text-zinc-950 dark:text-zinc-400 dark:hover:bg-zinc-800/70 dark:hover:text-white"
            ]}
          >
            <.icon
              name={section.icon}
              class={[
                "size-4",
                section[:current] && "text-emerald-700 dark:text-emerald-400",
                !section[:current] && "text-zinc-400 group-hover:text-zinc-600"
              ]}
            />
            <span>{section.label}</span>
          </.link>
        </nav>

        <div id="settings-detail" class="min-w-0 p-4 sm:p-6 lg:p-8">
          {render_slot(@inner_block)}
        </div>
      </div>
    </section>
    """
  end

  defp repository_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp repository_name(%{workspace_root: root}), do: Path.basename(root)

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
