# Kodo Requests for Discussion

Requests for Discussion (RFDs) capture proposals early enough to shape them
through written review and preserve the reasoning behind project decisions. An
RFD is not authoritative merely because it exists; its `state` says how it
should be read.

| RFD | Topic |
|---|---|
| [1: Bound control-plane database load](0001/README.adoc) | Keep heartbeat, recovery, ownership, and session-index database work proportional to live replicas and active sessions |

## Source format

Each RFD lives at `rfd/NNNN/README.adoc`, where `NNNN` is a four-digit number.
The document starts with canonical AsciiDoc attributes and an unpadded title:

```asciidoc
:authors: Name <email@example.com>
:state: prediscussion
:discussion:
:labels: software, process

= RFD 2 Example title
```

`authors` contains semicolon-separated owners. `discussion` contains the RFD's
pull-request URL once discussion starts. `labels` is a comma-separated set of
searchable topics. The document is the single source of truth for this metadata;
the index intentionally does not duplicate it.

Implementation progress lives separately in `rfd/NNNN/IMPLEMENTATION.org`. The
RFD and checklist link to each other, keeping the design and decision record
stable while implementation tasks are checked off.

## States

- `prediscussion`: actively being written and not ready for broad review.
- `ideation`: a narrowly scoped topic or scratchpad without active revision.
- `discussion`: under active review in the linked pull request.
- `published`: discussion has converged and the RFD expresses project direction.
- `committed`: the proposal is fully implemented and describes current behavior.
- `abandoned`: deliberately not proceeding or otherwise retained only for history.

The usual path is `prediscussion` or `ideation` to `discussion`, then
`published`, and eventually `committed`. `abandoned` is an off-ramp at any stage.
Implementation checklist progress does not determine the RFD's state.

## Lifecycle

Reserve the next unused four-digit number and create `rfd/NNNN/README.adoc` and
`rfd/NNNN/IMPLEMENTATION.org` on a branch. Cross-link the two documents. Use
`prediscussion` while writing or `ideation` for a topic placeholder. When the
document is ready for review, open a pull request, set the state to `discussion`,
and add that pull request as the discussion URL.

Before merging a proposal that represents project direction, move it to
`published`. Once the described work is entirely implemented, update it to
`committed`. Material changes to a published or committed RFD go through a new
pull request and retain the original discussion link unless the RFD explicitly
documents a replacement.

## Relationship to the MVP plan

The [MVP plan](../docs/mvp.org) remains Kodo's delivery roadmap and acceptance
sequence. RFDs document durable design decisions, boundaries, and tradeoffs that
need focused discussion. An MVP milestone may link to an RFD without moving its
task checklist into the design document.

## Shared principles

- Session durability must not make recovery cost grow without bound.
- Database work should be proportional to live replicas and active sessions,
  not historical sessions, completed coordinators, total users, or unrelated
  event traffic.
- Ownership checks and recovery optimization must preserve fencing and the
  documented failure-detection bound.
- User-owned collections are scoped in the database query rather than fetched
  and filtered afterward.
- Protocol changes remain compatible across rolling control-plane and runner
  upgrades unless an RFD explicitly defines a migration boundary.
