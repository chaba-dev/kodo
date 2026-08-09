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

The live test can also be run locally:

```sh
LIVE_LLM_MODEL=openai:gpt-4o-mini OPENAI_API_KEY=... \
  mix test test/e2e/live_provider_full_stack_test.exs --include live_provider
```
