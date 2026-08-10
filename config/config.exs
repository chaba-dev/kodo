# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :kodo, :scopes,
  user: [
    default: true,
    module: Kodo.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Kodo.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

default_max_continuations = 8
default_max_tokens = 100_000
default_model_timeout_ms = 60_000
default_tool_timeout_ms = 60_000

config :kodo,
  ecto_repos: [Kodo.Repo],
  generators: [timestamp_type: :utc_datetime],
  agent_budgets: [
    max_continuations: default_max_continuations,
    max_tokens: default_max_tokens,
    model_timeout: default_model_timeout_ms,
    tool_timeout: default_tool_timeout_ms
  ]

config :kodo, Kodo.Cluster.InstanceManager,
  artifact_revision: "development",
  deployment_generation: 0,
  protocol_capabilities: ["session-events-v1", "runner-v3"],
  heartbeat_interval: 5_000

config :kodo, start_instance_manager: true

# Phoenix messages are capped at the cross-language protocol limit. Bandit counts the largest
# possible WebSocket header in its frame size, while fragmented-message size counts payload bytes.
runner_wire_bytes = 4 * 1024 * 1024
websocket_header_bytes = 14

# Configure the endpoint
config :kodo, KodoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [
    websocket_options: [
      max_frame_size: runner_wire_bytes + websocket_header_bytes,
      max_fragmented_message_size: runner_wire_bytes
    ]
  ],
  render_errors: [
    formats: [html: KodoWeb.ErrorHTML, json: KodoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Kodo.PubSub,
  live_view: [signing_salt: "Xfp234km"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :kodo, Kodo.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kodo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  kodo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
