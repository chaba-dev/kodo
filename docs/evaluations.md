# MVP evaluations

The pinned `mvp-v1` suite contains 10 search, 10 review, and 10 implementation tasks. Fixtures are purpose-built and stored in [`priv/evals/mvp-v1/suite.json`](../priv/evals/mvp-v1/suite.json), including hidden implementation checks that must not be exposed to the agent under evaluation.

Validate the suite and print the artifact fingerprint with:

```console
mix kodo.eval.validate
```

Every recorded run must include the printed SHA-256 fingerprint, the fully resolved role mapping, role contract and toolset versions, event trace, latency, token usage, estimated cost, and per-task metrics described in `docs/mvp.org`. Materialize only `fixture.files` before an implementation attempt; add `fixture.hidden_files` immediately before hidden verification.

Results belong in `priv/evals/mvp-v1/results/<mapping>-<date>.json`. Do not record a recommendation from structural validation alone: all 30 tasks must have actual outcomes, and failures or skipped tasks must remain visible.

## Balanced baseline — 2026-08-25

The first live baseline is recorded in [`balanced-2026-08-25.json`](../priv/evals/mvp-v1/results/balanced-2026-08-25.json) for suite fingerprint `9fe83a629c90af1c663f700ec291140d1a04d4cceef37727917a14a3fea36599`. It ran all roles on `openai:gpt-4o-mini` with no reasoning and completed all 30 tasks without reported harness errors.

The old suite invoked hidden checks as `elixir -r lib/example.ex test/public_test.exs test/hidden_test.exs`. Elixir executed the public test script and treated the hidden test path as a command-line argument, so the hidden tests did not run. The recorded hidden-check pass rate is invalid. Public-check, search, review, latency, usage, and cost results remain usable.

| Metric | Result |
| --- | ---: |
| Search relevant-file recall | 30% |
| Search evidence-citation recall | 30% |
| Review defect and location recall | 80% |
| Review false positives | 1 |
| Implementation public-check pass rate | 50% |
| Implementation hidden-check pass rate | Invalid — hidden tests did not execute |
| Implementation scope compliance | 100% |
| Mean / p95 task latency | 8.42s / 18.35s |
| Total tokens | 152,859 |
| Provider-estimated cost | $0.021951 |
| Harness failure rate | 0% |

This artifact is historical evidence, not a valid complete baseline and not evidence that the current balanced profile is a useful default. Search recall and public implementation success are too low to close the Phase 7 recommendation criterion.

## Rejected stronger-model candidate — 2026-08-25

[`gpt5-mini-primary-search-2026-08-25.json`](../priv/evals/mvp-v1/results/gpt5-mini-primary-search-2026-08-25.json) overrides only the primary and search roles with `openai:gpt-5-mini`; the review role inherits the balanced recommendation. This directly exercises partial role override inheritance against the same suite fingerprint.

This run has the same hidden-check defect as the balanced artifact. Its hidden implementation metric is invalid; its public implementation, search, review, latency, usage, and cost results remain usable.

| Metric | Balanced baseline | GPT-5 mini candidate |
| --- | ---: | ---: |
| Search relevant-file recall | 30% | 0% |
| Review defect and location recall | 80% | 80% |
| Implementation public-check pass rate | 50% | 50% |
| Implementation hidden-check pass rate | Invalid | Invalid |
| Mean task latency | 8.42s | 10.92s |
| Provider-estimated cost | $0.021951 | $0.059196 |
| Harness failure rate | 0% | 0% |

Reject this candidate based on the still-valid comparison: it reduced search recall to zero while preserving review recall and public implementation success, and increased latency and cost. Its search traces consistently consumed the four-continuation budget on tool calls without producing a final answer. The implementation traces also confirm that model substitution alone does not resolve repeated invalid unified patches.

## Corrected suite

The hidden commands now explicitly require the public test file before executing the hidden test script. The corrected suite fingerprint is `e73ad35df41b5defd6d390e3b941066a42bf6b1fd2bb06ba712271fa7b0881d9`.

The valid corrected baseline is recorded in [`balanced-corrected-2026-08-25.json`](../priv/evals/mvp-v1/results/balanced-corrected-2026-08-25.json). It ran profile revision 4 at revision `91a7eb71f865a20375b9f78157cd31e0b3936e81`, completed all 30 tasks, and executed both public and hidden implementation checks.

| Metric | Corrected result |
| --- | ---: |
| Search relevant-file recall | 55% |
| Search evidence-citation recall | 45% |
| Review defect and location recall | 90% |
| Review false positives | 1 |
| Implementation public-check pass rate | 50% |
| Implementation hidden-check pass rate | 10% |
| Implementation scope compliance | 100% |
| Mean / p95 task latency | 10.24s / 24.27s |
| Total tokens | 214,375 |
| Provider-estimated cost | $0.029367 |
| Harness failure rate | 0% |

This satisfies the requirement to record a complete baseline, but the balanced recommendation is not ready to close Phase 7. Only one of 25 authored patches applied; the other 24 had invalid unified-diff hunk counts. All 10 implementation tasks and four search tasks also ended without a final answer after spending their last available model turn on tools.

Profile revision 5 addresses those observed contract failures by adding an exact, single-match `replace_text` tool and withholding tools on the final model turn. A fresh paid run is required to measure whether those changes improve quality; do not compare the corrected implementation metrics directly with the invalid hidden-check metrics from the older fingerprint.
