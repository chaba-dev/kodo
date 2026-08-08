defmodule KodoWeb.Router do
  use KodoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KodoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", KodoWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/api", KodoWeb do
    pipe_through :api

    post "/runners", RunnerRegistrationController, :create
    post "/sessions", SessionController, :create
    get "/sessions/:id", SessionController, :show
    post "/sessions/:id/messages", SessionController, :message
    post "/sessions/:id/cancel", SessionController, :cancel
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
end
