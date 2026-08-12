# ADR 0007: Use `monitor` to observe, `link` only for shared fate

- Status: Accepted
- Date: 2026-08-12
- Recorded retroactively for #39, #56, and #69.

## Context

Two supervision relationships in this system are one-directional:

- the registry needs to know when a room dies, but must survive it;
- a room needs to know when a connection process dies, but must survive it.

BEAM offers two primitives that are easy to confuse. `link` is **bidirectional**
and propagates exit signals. `monitor` is **one-directional** and only delivers
a message.

Both were got wrong here, in opposite directions:

- The registry used `monitor` and still died with its rooms — because
  `actor.start` **links** the started actor to its starter. The monitor did not
  cancel the link that already existed.
- A room used `link` on its session processes, with a comment claiming a
  one-directional interest. `trap_exits` was in place, so nothing broke, but the
  structure would have taken the room down the moment that trap was removed.

## Decision

| Intent | Primitive |
|---|---|
| Know that another process died | `monitor` |
| Share fate deliberately | `link` |
| A link already exists (e.g. `actor.start`) but death must not propagate | `trap_exits` + `select_trapped_exits` |

Monitors are released with `demonitor_process` when the relationship ends, so a
later termination of that process does not deliver an irrelevant `Down`.

**A link that a component creates for itself is almost always wrong here.**
Neutralising it with `trap_exits` leaves a design that breaks when the
neutraliser is removed.

## Consequences

### Positive

- Failure containment is a property of the structure, not of a flag.
- The registry survives room crashes; rooms survive connection crashes.

### Negative

- `actor.start` still creates a link, so `trap_exits` remains necessary in the
  registry. The rule cannot be applied uniformly.
- Monitor bookkeeping (pid → participant) has to be maintained by hand, because
  `Down` messages carry only the pid.

## Notes

Neither error was found by reading. The registry case surfaced when a test
killed a room and **the test process died too**; the link comment was found
while reading adjacent code. Tests that actually kill processes are what make
this class of mistake visible.
