# ADR 0008: Supervise the registry and the web server as a one-for-one tree

- Status: Accepted
- Date: 2026-08-17
- Supersedes [ADR 0004](0004-supervise-registry-and-web-server.md).

## Context

ADR 0004 put the registry and the mist web server under one `rest_for_one`
supervisor, registry first. The stated reason was that the web server
"depends on" the registry and needed to be rebuilt whenever the registry
restarted, "to avoid holding stale name resolution".

That reasoning does not match the implementation. The web server never holds
a registry subject captured at startup; it holds a `process.named_subject`,
and `gleam_erlang` resolves a named subject's target process on every send.
When the registry restarts under the same name, the next message sent through
that subject reaches the new process automatically — no rebuild required.

`rest_for_one` restarts every child added after the crashed one. `mist`'s
supervised child (`mist.supervised`) is itself a supervisor whose subtree
holds the listener, the acceptor pool, and **every live WebSocket connection
process**. So every registry crash — regardless of cause, and regardless of
which room (if any) was involved — force-closed every WebSocket connection in
every room. That contradicts the per-room failure isolation this repository
otherwise designs for (ADR 0002): a fault in the registry became a fault
visible to all participants in all rooms, not just the room whose state was
actually affected.

## Decision

Use `one_for_one` instead. The registry and the web server restart
independently; killing one does not touch the other.

## Consequences

### Positive

- A registry crash restarts only the registry. Existing WebSocket connections
  and rooms are unaffected; the next registry-bound operation from any
  connection is served by the newly restarted registry via name resolution.
- Failure containment now matches the stated design principle that one room's
  (or the registry's) fault should not propagate to unrelated connections.

### Negative

- If a bug ever made the web server hold a captured registry subject instead
  of the named one, this change would silently start routing to a dead
  process instead of loudly restarting. Nothing currently does this — the
  handler always resolves through the name — but it is a property to preserve
  rather than re-derive next time this code is touched.

## Notes

Verified with a supervisor test that starts the real `gleamroom.start`
configuration, kills the registry child, and asserts the web server child's
pid is unchanged after the registry has been observed to restart
(`test/gleamroom/supervisor_test.gleam`,
`one_for_one_does_not_restart_the_web_server_when_registry_crashes_test`).
