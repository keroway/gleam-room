# ADR 0005: A synchronous call to an actor must not crash the caller

- Status: Accepted
- Date: 2026-08-12
- Recorded retroactively for #33, #58, #70, and #92.

## Context

`actor.call` (via `process.call`) **crashes the calling process** when the reply
does not arrive in time. In this system the callers are WebSocket connection
processes and the HTTP handler.

A room actor that was merely slow — garbage collection, a backlog of messages —
therefore killed the connection. The client got no message and nothing was
logged. The same hazard existed wherever a synchronous call was made.

## Decision

All synchronous actor calls go through `gleamroom/call`.

- `try_call` wraps `actor.call` in `exception.rescue` and returns
  `Result(reply, Nil)`. The caller decides what to do; it does not die.
- Every failure is classified into `Timeout`, `ActorDown`, or `Unknown(detail)`
  and logged at warning level with that distinction.
- `try_call_classified` returns the classification to callers **that act on it**.
  It is not used everywhere: a caller that would handle every failure the same
  way takes `try_call` and ignores the reason.

Classification is derived from the exception message produced by
`process.call` (`callee did not send reply before timeout` /
`callee exited: ...`). When neither matches, the result is `Unknown` carrying
the raw detail — it is **never assumed to be a timeout**.

## Consequences

### Positive

- A slow or dead actor degrades one call instead of killing a connection.
- Operators can tell "wedged" from "gone" and look in the right place.
- `/health` reports the two cases differently (`registry not responding` vs
  `registry down`).

### Negative

- Failures become values that callers must handle; some call sites flatten two
  layers of `Result`.
- The classification depends on string matching against a dependency's message.
  If `gleam_erlang` changes the wording, results become `Unknown` — degraded but
  not wrong.

## Notes

The rule is only as good as its coverage. `registry.lookup` kept a raw
`actor.call` for some time after #33 and reintroduced the original crash (#58).
Adding the helper did not remove the hazard; **auditing every call site did.**
