defmodule KodoWeb.Router do
  use KodoWeb, :router

  import KodoWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KodoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated_agent do
    plug :fetch_current_scope_for_agent
    plug :require_authenticated_agent
  end

  scope "/", KodoWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", KodoWeb do
    pipe_through :api

    post "/auth/token", AgentSessionController, :create
  end

  scope "/api", KodoWeb do
    pipe_through [:api, :authenticated_agent]

    post "/runners", RunnerRegistrationController, :create
    delete "/auth/token", AgentSessionController, :delete
    get "/model-settings", ModelSettingsController, :show
    put "/model-settings/roles/:role", ModelSettingsController, :put_user
    delete "/model-settings/roles/:role", ModelSettingsController, :delete_user

    put "/model-settings/repositories/:runner_id/roles/:role",
        ModelSettingsController,
        :put_repository

    delete "/model-settings/repositories/:runner_id/roles/:role",
           ModelSettingsController,
           :delete_repository

    post "/sessions", SessionController, :create
    get "/sessions/:id", SessionController, :show
    post "/sessions/:id/messages", SessionController, :message
    post "/sessions/:id/cancel", SessionController, :cancel
    post "/sessions/:id/approvals/:approval_id", SessionController, :resolve_approval
    post "/cluster/placement-overrides", ClusterPlacementController, :create_override
  end

  # Other scopes may use custom stacks.
  # scope "/api", KodoWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:kodo, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: KodoWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", KodoWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{KodoWeb.UserAuth, :require_authenticated}] do
      live "/sessions", SessionLive.Index, :index
      live "/sessions/:id", SessionLive.Show, :show
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/integrations", IntegrationsLive, :index
    end

    get "/users/reauthenticate/:provider/:action", UserSessionController, :reauthenticate
    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", KodoWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{KodoWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
