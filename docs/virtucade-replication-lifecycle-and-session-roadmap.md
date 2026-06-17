# VirtuCade Replication, Lifecycle, And Session Roadmap

This note turns the Godot Tiny MMO research into a small set of future-facing
follow-ups for this project and for VirtuCade.

The key conclusion is simple:

```text
multi-server-test does not need a major architecture change from Tiny MMO.
VirtuCade does need a clear roadmap for replication scale, world lifecycle,
and authenticated session/reconnect behavior.
```

This project is already on the better path for the intended goals:

- master-owned durable truth
- separate control-plane and gameplay connections
- temporary world processes
- master-issued travel authorization
- PackRat world downloads before join

So the right next move is documentation and future design guidance, not a large
code rewrite.

## 1. Replication Roadmap

## Current Recommendation

Keep the current replication model for now.

It is appropriate for this prototype because:

- player counts are still small
- worlds are simple
- the project already proves multi-world transfer, chat, persistence, and PackRat
- more networking complexity right now would slow down higher-value work

Do not copy Tiny MMO's byte-packed replication system into this project yet.

## Future Trigger

Revisit replication only when one or more of these become true:

- a single world regularly has many visible players at once
- movement/state bandwidth becomes noisy
- hub scenes become crowded
- mini-games need stricter authoritative scoring or collision handling
- profiler data shows RPC/state traffic becoming a bottleneck

## Recommended Future Direction

When the current model stops being enough, move toward:

```text
1. compact message encoding
2. hot vs cold state split
3. area-of-interest filtering
4. stricter server authority for competitive interactions
```

### Hot vs Cold State Split

```text
hot state  = changes very often and must update quickly
cold state = changes less often and can update slower
```

Examples:

- hot:
  - position
  - velocity
  - facing
  - current animation/motion flags
- cold:
  - display name
  - appearance loadout
  - interactable state
  - scoreboard/container/state that changes less often

The point is to avoid treating every field as equally urgent.

### Area Of Interest

Do not send every entity to every client forever.

Later, add visibility filtering based on:

- same world
- same room/instance
- nearby cells/grid
- explicitly subscribed shared state

This matters most for hub-like spaces and social worlds.

## 2. World Lifecycle Roadmap

This project already behaves like a small world orchestration system, but the
intended world lifecycle should be explicit.

## Recommended Lifecycle

```text
stopped
  -> spawning
  -> ready
  -> reserved
  -> active
  -> draining
  -> stopped
```

Suggested meanings:

- `stopped`
  - no process is running
- `spawning`
  - process launch requested, registration not complete yet
- `ready`
  - process registered, empty, joinable
- `reserved`
  - a client has travel authorization and is preparing assets
- `active`
  - at least one player is inside
- `draining`
  - world should not accept new joins and is waiting to empty/shutdown

## Why This Matters

This keeps several concerns clear:

- when the master may hand out a route
- when idle shutdown is allowed
- when a PackRat download should block world startup
- when maintenance/redeploy should refuse new entries
- how reconnect and transfer recovery should behave

## Practical Rule For VirtuCade

The master should remain the only source of truth for world eligibility.

World processes should be treated as:

```text
ephemeral execution nodes
```

They should register, heartbeat, accept only master-approved joins, report
results/state back, then shut down cleanly.

## 3. Session, Identity, And Reconnect Roadmap

This is the biggest future gap compared with a real production-ready game.

## Current State

Current MVP is intentionally light:

- guest flow
- name-only login
- master-owned SQLite persistence
- TravelLease + one-use world join ticket

That is enough for the current prototype, but not enough for long-term user
identity or maintenance reconnect behavior.

## Needed Later

VirtuCade should add:

- authenticated accounts
- hashed passwords
- durable session records
- session expiry/revocation
- reconnect/resume flow
- maintenance restart messaging
- client/server version rejection with friendly recovery

## Recommended Model

Keep identity and world entry as separate layers:

```text
authenticated session = who the player is
world join ticket     = permission to enter one specific world right now
```

Do not collapse those into one token.

That separation keeps world processes simple and avoids giving them long-lived
account authority.

## Reconnect Direction

Future reconnect flow should look like:

```text
1. client loses gameplay/world connection
2. master/control connection survives if possible, or reconnects first
3. client resumes authenticated session
4. master decides whether resume is valid
5. master issues fresh travel/join authorization
6. client rejoins the appropriate world or fallback hub
```

The world server should not become the durable owner of the player's identity.

## What Not To Copy From Tiny MMO

Do not pull these patterns directly into VirtuCade:

- resource-file account/auth storage
- per-world durable ownership of player/account truth
- broad MMO framework complexity before it is needed
- prediction/reconciliation work before the game design actually requires it

## Recommended Near-Term Documentation Rule

For this repository:

```text
document the roadmap now
implement only when a measured need appears
```

That keeps the project lightweight while still leaving a clear path for
VirtuCade.

## Concrete Next Triggers

Only elevate this roadmap into code work when one of these happens:

- crowded hub visibility becomes expensive
- chat/control/gameplay timing starts stepping on itself
- reconnect after restart becomes a real need
- identity/security becomes important beyond local trusted testing
- per-world gameplay starts needing stronger anti-cheat or deterministic scoring

Until then, the current architecture is the right amount of complexity.
