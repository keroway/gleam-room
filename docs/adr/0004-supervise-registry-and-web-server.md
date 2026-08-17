# ADR 0004: Supervise the registry and the web server as a rest-for-one tree

- Status: Superseded by [ADR 0008](0008-supervise-registry-and-web-server-as-one-for-one.md)
- Date: 2026-08-12
- Recorded retroactively for the change made in #23. The decision was taken and
  implemented before this ADR was written; see #89 for why the gap existed.

## Context

The registry and the mist web server were started independently with
`let assert Ok(...)`. Neither owned the other, and nothing restarted either one.

If the registry died, the web server kept serving. HTTP requests still returned
`200`, but every `join` silently failed because the handler held a subject
pointing at a dead process. The failure was invisible from outside.

## Decision

Start both under one `rest_for_one` supervisor, registry first, web server
second.

The registry is registered under a **name**; the HTTP handler resolves the
subject through that name on every request rather than capturing a subject at
startup.

## Consequences

### Positive

- A dead registry is restarted instead of leaving the system half-alive.
- `rest_for_one` restarts the web server when the registry is replaced, so no
  connection keeps a stale name resolution.
- Startup order is explicit and matches the dependency direction.

### Negative

- A registry restart drops all rooms. Participants must re-join. This is
  acceptable while state is in-memory only (ADR 0003).
- The web server is restarted even when it was healthy.

## Notes

Being supervised does not make the failure visible on its own. `/health`
returned an unconditional `200` for some time after this change, so the very
state this ADR set out to fix was still invisible to a health check. That was
fixed separately (#93) and is recorded in ADR 0005.

The "Positive" consequence above — `rest_for_one` restarts the web server
alongside the registry "so no connection keeps a stale name resolution" — was
never actually true. The registry is passed to the web server as a
`process.named_subject`, whose name resolves on every send, not once at
startup. Restarting the web server was unnecessary and, worse, dropped every
live WebSocket connection across all rooms on every registry crash, not just
the room that mattered. See ADR 0008 (#78).
