# MVP evaluations

The pinned `mvp-v1` suite contains 10 search, 10 review, and 10 implementation tasks. Fixtures are purpose-built and stored in [`priv/evals/mvp-v1/suite.json`](../priv/evals/mvp-v1/suite.json), including hidden implementation checks that must not be exposed to the agent under evaluation.

Validate the suite and print the artifact fingerprint with:

```console
mix kodo.eval.validate
```

Every recorded run must include the printed SHA-256 fingerprint, the fully resolved role mapping, role contract and toolset versions, event trace, latency, token usage, estimated cost, and per-task metrics described in `docs/mvp.org`. Materialize only `fixture.files` before an implementation attempt; add `fixture.hidden_files` immediately before hidden verification.

Results belong in `priv/evals/mvp-v1/results/<mapping>-<date>.json`. Do not record a recommendation from structural validation alone: all 30 tasks must have actual outcomes, and failures or skipped tasks must remain visible.
