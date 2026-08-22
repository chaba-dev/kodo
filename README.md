# Kodo コード

WIP

## CLI sessions

Create an agent token with `POST /api/auth/token`, then run Kodo from the Git
worktree. The CLI registers and hosts that worktree's local runner for the
duration of the command:

```sh
export KODO_TOKEN="..."
cargo run -p kodo -- start "Fix the failing greeting test"
```

Resume the same durable event stream later with the session identifier printed
by the start command:

```sh
cargo run -p kodo -- resume SESSION_ID
```

Use `--approval-policy standard` (the default), `safe`, or `read-only`. The CLI
shows the exact command for approval-gated process requests, defaults approval
prompts to denial, and sends an agent cancellation when interrupted with
Ctrl-C. `KODO_CONTROL_PLANE` defaults to `http://localhost:4451`.

## End-to-end tests

The hermetic full-stack test runs with the normal Elixir suite. It starts a real HTTP/WebSocket
server and Rust runner against a temporary Git repository while using a deterministic model:

```sh
mix test test/e2e/hermetic_full_stack_test.exs
```

Pull requests can run the opt-in live OpenAI smoke test when a repository owner, member, or
collaborator comments exactly `/live-smoke-test`. Configure a protected GitHub Environment named
`live-smoke` with an `OPENAI_API_KEY` secret and, optionally, a `LIVE_LLM_MODEL` variable. Require
environment approval and use a low-quota key: the workflow intentionally executes the requested PR
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

Register a throwaway user at `/users/register`. To run an agent against the target repository,
issue an agent token with `POST /api/auth/token`, then run:

```sh
KODO_TOKEN="..." cargo run -p kodo -- start \
  --workspace tmp/kodo-work \
  "Complete the requested task and verify the Git diff"
```
