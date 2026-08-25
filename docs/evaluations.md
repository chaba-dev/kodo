# MVP evaluations

The pinned `mvp-v1` suite contains 10 search, 10 review, and 10 implementation tasks. Fixtures are purpose-built and stored in [`test/evals/mvp-v1/suite.json`](../test/evals/mvp-v1/suite.json), including hidden implementation checks that must not be exposed to the agent under evaluation.

Validate the suite and print the artifact fingerprint with:

```console
mix kodo.eval.validate
```

Every recorded run must include the printed SHA-256 fingerprint, the fully resolved role mapping, role contract and toolset versions, event trace, latency, token usage, estimated cost, and per-task metrics described in `docs/mvp.org`. Materialize only `fixture.files` before an implementation attempt; add `fixture.hidden_files` immediately before hidden verification.

Results belong in `test/evals/mvp-v1/results/<mapping>-<date>.json`. Do not record a recommendation from structural validation alone: all 30 tasks must have actual outcomes, and failures or skipped tasks must remain visible.

## Benchmark criteria

The [benchmark reference](../test/evals/README.adoc) documents the artifact model, suite lifecycle, governance, and stable AsciiDoc sections available to reference-generation tooling. The top-level [`criteria.json`](../test/evals/criteria.json) remains the machine-readable benchmark catalog. Its named, immutable standards define metric paths, meanings, comparison directions, and improvement targets shared by suite generations. Each registered suite has a smaller contract—such as [`mvp-v1/criteria.json`](../test/evals/mvp-v1/criteria.json)—that references a standard and defines fingerprint-bound regression thresholds anchored to its accepted result.

`test/evals/benchmark_test.exs` validates every standard and registered suite, then verifies that each accepted baseline meets all of its regression thresholds. Add future suites to the catalog and preserve standards referenced by historical suites; introduce a new named standard when metric semantics or cross-generation targets change. When a better result is accepted, update that suite's `baseline_result` and raise thresholds where the new evidence supports doing so. Thresholds must not be lowered merely to admit a regressing candidate. The mvp-v1 cost and latency thresholds allow approximately 20% run-to-run variance over revision 8, while correctness, scope, and harness thresholds remain direct quality gates.

## Balanced baseline — 2026-08-25

The first live baseline is recorded in [`balanced-2026-08-25.json`](../test/evals/mvp-v1/results/balanced-2026-08-25.json) for suite fingerprint `9fe83a629c90af1c663f700ec291140d1a04d4cceef37727917a14a3fea36599`. It ran all roles on `openai:gpt-4o-mini` with no reasoning and completed all 30 tasks without reported harness errors.

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

[`gpt5-mini-primary-search-2026-08-25.json`](../test/evals/mvp-v1/results/gpt5-mini-primary-search-2026-08-25.json) overrides only the primary and search roles with `openai:gpt-5-mini`; the review role inherits the balanced recommendation. This directly exercises partial role override inheritance against the same suite fingerprint.

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

The valid corrected baseline is recorded in [`balanced-corrected-2026-08-25.json`](../test/evals/mvp-v1/results/balanced-corrected-2026-08-25.json). It ran profile revision 4 at revision `91a7eb71f865a20375b9f78157cd31e0b3936e81`, completed all 30 tasks, and executed both public and hidden implementation checks.

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

Profile revision 5 addresses those observed contract failures by adding an exact, single-match `replace_text` tool and withholding tools on the final model turn. Its results follow; do not compare corrected implementation metrics with the invalid hidden-check metrics from the older fingerprint.

## Balanced profile revision 5 — 2026-08-25

[`balanced-profile-v5-2026-08-25.json`](../test/evals/mvp-v1/results/balanced-profile-v5-2026-08-25.json) evaluates profile revision 5 against the corrected suite at revision `634f610d154dd377634ff3070c76fa96aefda292`.

| Metric | Revision 4 | Revision 5 |
| --- | ---: | ---: |
| Search relevant-file recall | 55% | 76.7% |
| Search evidence-citation recall | 45% | 35% |
| Review defect and location recall | 90% | 100% |
| Review severity accuracy | 90% | 70% |
| Review false positives | 1 | 1 |
| Implementation public-check pass rate | 50% | 50% |
| Implementation hidden-check pass rate | 10% | 20% |
| Implementation scope compliance | 100% | 100% |
| Empty final answers | 14 | 0 |
| Mean / p95 task latency | 10.24s / 24.27s | 14.83s / 43.20s |
| Total tokens | 214,375 | 300,161 |
| Provider-estimated cost | $0.029367 | $0.041681 |
| Harness failure rate | 0% | 0% |

The final-turn fix worked: every task produced an answer. Exact replacement also gave the primary a reliable mutation path, with 12 of 13 calls succeeding. The model still attempted 10 malformed unified patches, all of which were rejected. Implementation quality remains below an acceptable default: public success did not improve, hidden success reached only 20%, and six final reviews remained non-clean. Search file recall improved, but evidence citation regressed while latency, token use, and cost increased.

Trace inspection also found two harness divergences from the runner contract: evaluation reads treated offsets and limits as bytes instead of lines, and verification rejected the root-equivalent `./` working directory. Both made the model consume turns on fragmented reads or rejected exact public commands. Final-diff review also lacked the original task, allowing unsupported findings to trigger harmful correction attempts. All three issues were corrected after this artifact. Keep Phase 7 open and evaluate those fixes before accepting or rejecting the mapping.

## Harness-corrected profile revision 5 — 2026-08-25

[`balanced-profile-v5-harness-corrected-2026-08-25.json`](../test/evals/mvp-v1/results/balanced-profile-v5-harness-corrected-2026-08-25.json) evaluates the same profile after aligning evaluation reads, root working directories, and final-diff review context with the runner contract. It completed all 30 tasks without harness errors at revision `e72a38892ac1b39669fa834d08c01460deb01290`.

| Metric | Earlier revision 5 | Harness-corrected revision 5 |
| --- | ---: | ---: |
| Search relevant-file recall | 76.7% | 81.7% |
| Search evidence-citation recall | 35% | 70% |
| Review defect and location recall | 100% | 80% |
| Review severity accuracy | 70% | 80% |
| Review false positives | 1 | 1 |
| Implementation public-check pass rate | 50% | 70% |
| Implementation hidden-check pass rate | 20% | 50% |
| Implementation clean-review rate | 40% | 40% |
| Implementation scope compliance | 100% | 100% |
| Empty final answers | 0 | 0 |
| Mean / p95 task latency | 14.83s / 43.20s | 13.95s / 58.19s |
| Total tokens | 300,161 | 302,109 |
| Provider-estimated cost | $0.041681 | $0.042832 |
| Harness failure rate | 0% | 0% |

The harness corrections materially improved search evidence and implementation outcomes: seven public and five hidden implementation checks passed. Seventeen of 21 exact replacements succeeded. All 10 unified patches were still rejected, so exact replacement remains the only reliable mutation path for this model.

Trace inspection found two remaining contract issues. The synchronous evaluation harness advertised `poll_command` and `stop_command` despite supporting neither. Final-diff review also emitted findings for correct changes, including one whose explanation and suggested fix explicitly said no fix was needed; those false findings triggered unnecessary correction loops. Evaluation turns now omit asynchronous command tools, and review contract version 3 requires actionable defects and internally consistent clean results. These changes advance the balanced profile to revision 6. Keep Phase 7 open pending evidence for revision 6; the current 50% hidden-check success is improved but not yet an acceptable default recommendation.

## Balanced profile revision 6 — 2026-08-25

[`balanced-profile-v6-2026-08-25.json`](../test/evals/mvp-v1/results/balanced-profile-v6-2026-08-25.json) completed all 30 tasks without harness errors. Search file/evidence recall improved to 85%/80%, and standalone review reached 100% defect and location recall with one false positive. Implementation regressed to 60% public and 40% hidden success, while no implementation received a clean final review. Mean latency rose to 16.67 seconds, total tokens to 349,685, and provider-estimated cost to $0.048249.

The stricter review prompt overcorrected. It raised findings on every implementation, including correct implementations, speculative performance suggestions, and a finding whose text explicitly concluded that no change was needed. One review recommended reverting the required `add/2` fix, turning a passing implementation back into subtraction. Primary traces also spent 11 calls on malformed `apply_patch` requests despite 22 successful exact replacements, and frequently substituted disallowed `mix` commands or invented working directories for the exact public command.

Profile revision 7 responds directly: review contract version 4 makes the original task authoritative and excludes speculative or optional findings; primary contract version 6 requires rereading and exact public verification after each edit and treats review feedback as an untrusted claim. Toolset `workspace-v5` removes `apply_patch`, which has a 0/31 success record across the three profile revision 5–6 runs for this model, while retaining exact replacement and all inspection and verification tools.

## Balanced profile revision 7 — 2026-08-25

[`balanced-profile-v7-2026-08-25.json`](../test/evals/mvp-v1/results/balanced-profile-v7-2026-08-25.json) completed all 30 tasks without errors. Removing `apply_patch` reduced mean latency from 16.67 to 13.46 seconds, tokens from 349,685 to 285,099, and cost from $0.048249 to $0.039358. Review clean rate recovered from 0% to 30%, but search file/evidence recall fell to 73.3%/65% and implementation fell to 50% public and 30% hidden success.

Trace inspection identified a concrete evaluation bug behind the implementation regression: correction turns received only review findings, not the original task, allowed paths, or exact public command. Consequently, every correction verification attempt used a disallowed command or working directory. The reviewer also continued to return internally contradictory findings such as “the code is correct” with “No change needed,” despite the prompt prohibition.

Profile revision 8 retains the cheaper toolset but restores the complete implementation contract in correction turns. A shared review-result gate now drops findings outside the actual diff and findings whose suggested fix explicitly requires no change, preventing those results from triggering harmful correction loops in both live sessions and evaluations.

## Accepted balanced profile revision 8 — 2026-08-25

[`balanced-profile-v8-2026-08-25.json`](../test/evals/mvp-v1/results/balanced-profile-v8-2026-08-25.json) completed all 30 tasks without errors and is the accepted Phase 7 recommendation.

| Metric | Revision 7 | Revision 8 |
| --- | ---: | ---: |
| Search relevant-file recall | 73.3% | 86.7% |
| Search evidence-citation recall | 65% | 55% |
| Review defect and location recall | 100% | 90% |
| Review false positives | 1 | 2 |
| Implementation public-check pass rate | 50% | 90% |
| Implementation hidden-check pass rate | 30% | 80% |
| Implementation scope compliance | 100% | 100% |
| Mean / p95 task latency | 13.46s / 35.63s | 14.11s / 45.00s |
| Total tokens | 285,099 | 274,841 |
| Provider-estimated cost | $0.039358 | $0.038445 |
| Harness failure rate | 0% | 0% |

Restoring correction context produced the decisive improvement: nine of ten implementations passed public verification and eight passed hidden verification, while every correction command used the allowed exact command rather than being rejected. The remaining implementation failures were slug whitespace handling and path parent-traversal handling. Final review remains overcritical and often reports optional or unsupported concerns, but the primary now checks those claims against the task and preserves verified behavior; standalone review still achieved 90% defect/location recall. Further review-precision tuning can proceed independently and does not block the Phase 7 mapping recommendation.
