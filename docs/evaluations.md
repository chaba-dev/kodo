# MVP evaluations

The pinned `mvp-v1` suite contains 10 search, 10 review, and 10 implementation tasks. Fixtures are purpose-built and stored in [`priv/evals/mvp-v1/suite.json`](../priv/evals/mvp-v1/suite.json), including hidden implementation checks that must not be exposed to the agent under evaluation.

Validate the suite and print the artifact fingerprint with:

```console
mix kodo.eval.validate
```

Every recorded run must include the printed SHA-256 fingerprint, the fully resolved role mapping, role contract and toolset versions, event trace, latency, token usage, estimated cost, and per-task metrics described in `docs/mvp.org`. Materialize only `fixture.files` before an implementation attempt; add `fixture.hidden_files` immediately before hidden verification.

Results belong in `priv/evals/mvp-v1/results/<mapping>-<date>.json`. Do not record a recommendation from structural validation alone: all 30 tasks must have actual outcomes, and failures or skipped tasks must remain visible.

## Balanced baseline — 2026-08-25

The first complete live baseline is recorded in [`balanced-2026-08-25.json`](../priv/evals/mvp-v1/results/balanced-2026-08-25.json) for suite fingerprint `9fe83a629c90af1c663f700ec291140d1a04d4cceef37727917a14a3fea36599`. It ran all roles on `openai:gpt-4o-mini` with no reasoning and completed all 30 tasks without harness errors.

| Metric | Result |
| --- | ---: |
| Search relevant-file recall | 30% |
| Search evidence-citation recall | 30% |
| Review defect and location recall | 80% |
| Review false positives | 1 |
| Implementation public and hidden pass rate | 50% |
| Implementation scope compliance | 100% |
| Mean / p95 task latency | 8.42s / 18.35s |
| Total tokens | 152,859 |
| Provider-estimated cost | $0.021951 |
| Harness failure rate | 0% |

This is a reproducible baseline, not evidence that the current balanced profile is a useful default. Search recall and implementation success are too low to close the Phase 7 recommendation criterion. Compare a revised profile or role contract against this artifact before changing the recommendation.
