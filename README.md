# Kodo コード

Kodo is a durable coding-agent control plane built with Phoenix and a confined
Rust workspace runner. The MVP supports a shared CLI and LiveView session,
approval policies, resumable command execution, final-diff review, and durable
replay after a client or server restart.

## Install

Tagged releases publish the `kodo` CLI for Linux x86-64, Linux ARM64, and
Apple Silicon macOS, with a shell installer and checksums. The Phoenix server
is published as `ghcr.io/chaba-dev/kodo` for Linux x86-64 and ARM64. See the
[release guide](docs/releasing.md) for the artifact and image lifecycle.
The GNU/Linux CLI archives require glibc 2.34 or newer.

Building from source on Linux or macOS requires:

- Erlang/OTP 28 and Elixir 1.20;
- stable Rust (the Nix shell pins Rust 1.96);
- PostgreSQL 17;
- Docker with the Compose plugin;
- Git, `ripgrep`, and `jq`.

Nix users can enter the complete development shell with `nix develop`.
Otherwise install those prerequisites with the platform package manager, then
run:

```sh
git clone https://github.com/chaba-dev/kodo.git
cd kodo
mix local.hex --force
mix local.rebar --force
mix deps.get
docker compose up -d db
mix setup
cargo build --release -p kodo
```

The CLI binary is `target/release/kodo`. Add it to `PATH` or invoke it by that
path. Start the Phoenix control plane with `mix phx.server`; it listens on
`http://localhost:4451` in development and uses the PostgreSQL instance exposed
by `docker compose` on port 5435.

## Configure a model provider

The balanced MVP profile uses OpenAI `gpt-4o-mini` for its primary, search, and
review roles. Export the provider credential before starting Phoenix so ReqLLM
can dispatch those requests:

```sh
export OPENAI_API_KEY="..."
mix phx.server
```

Keep provider keys only in the control-plane environment; do not pass them to
the runner. `--model provider:model` overrides the primary role for one session.
The selected model must support the role contract's tool use and context
requirements, and its provider's standard ReqLLM credential must be configured.
The live-provider smoke test below is the quickest configuration check.

## Start and resume CLI sessions

Create an account in the web application and request a 30-day agent token:

```sh
export KODO_TOKEN="$(curl --fail --silent --show-error \
  -H 'content-type: application/json' \
  -d '{"email":"you@example.com","password":"..."}' \
  http://localhost:4451/api/auth/token | jq -r .token)"
```

Treat this bearer token as a secret. Run Kodo from the target Git worktree. The
CLI registers and hosts that worktree's local runner for the command's duration:

```sh
kodo start "Fix the failing greeting test"
```

Resume the same durable event stream later with the session identifier printed
by the start command:

```sh
kodo resume SESSION_ID
```

Use `--approval-policy standard` (the default), `safe`, or `read-only`. The CLI
shows the exact command for approval-gated process requests, defaults approval
prompts to denial, and sends an agent cancellation when interrupted with
Ctrl-C. `KODO_CONTROL_PLANE` defaults to `http://localhost:4451`.

Tool output is bounded. Both clients label partial results with
`[output truncated]`; request a narrower read, search, or diff before drawing a
conclusion. Failed patches are recorded as `tool_failed` events with Git's error
and leave the failed patch unapplied.

## End-to-end tests

The hermetic full-stack test runs with the normal Elixir suite. It starts a real
HTTP/WebSocket server and Rust runner against a temporary Git repository while
using a deterministic model:

```sh
mix test test/e2e/hermetic_full_stack_test.exs
```

The release-candidate workflow repeats this acceptance test on Linux and macOS.
Pull requests can run the opt-in live OpenAI smoke test when a repository owner,
member, or collaborator comments exactly `/live-smoke-test`. Configure a
protected GitHub Environment named `live-smoke` with an `OPENAI_API_KEY` secret
and, optionally, a `LIVE_LLM_MODEL` variable. Require environment approval and
use a low-quota key: the workflow intentionally executes the requested PR
revision with that credential.

## Deployment boundary

Kodo supports multiple clustered Phoenix replicas. PostgreSQL ownership epochs fence every durable
session transition and external effect, while BEAM discovery routes live control and proactively
rehomes sessions away from a draining replica. Replicas must share PostgreSQL, an Erlang cookie,
DNS discovery, and compatible protocol capabilities.

Production releases must identify their immutable artifact and ordered deployment generation. See
the [server operations guide](docs/operations.org) for required values, rollback semantics, startup
failure behavior, BEAM networking, and Kubernetes rollout requirements.

The live test can also be run locally:

```sh
LIVE_LLM_MODEL=openai:gpt-4o-mini OPENAI_API_KEY=... \
  mix test test/e2e/live_provider_full_stack_test.exs --include live_provider
```

## Amp orb development

Fresh Amp orbs include the project toolchains, PostgreSQL, the built application and runner, and a
local clone of [`chaba-dev/kodo-work`](https://github.com/chaba-dev/kodo-work) for agent sessions.

Start the supervised development server and print its portal URL with:

```sh
amp orb services ensure
```

Log in with the development-only account `dev@kodo.local` and password `supersecure!`. To run an
agent against the target repository, issue an agent token with `POST /api/auth/token`, then run:

```sh
KODO_TOKEN="..." cargo run -p kodo -- start \
  --workspace tmp/kodo-work \
  "Complete the requested task and verify the Git diff"
```
