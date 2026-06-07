# Handoff: VirtuCade Nakama/PocketBase Infrastructure Spike

## Session Metadata
- Created: 2026-06-06 18:34:16
- Project: C:\Programming_Files\Shilocity\Godot\Tests\multi-server-test
- Branch: main
- Session duration: Long-running architecture/research session spanning Godot multi-server MVP implementation, MMO prior-art research, VirtuCade infrastructure design, and Nakama option research.

### Recent Commits (for context)
  - c6c5559 Document VirtuCade infrastructure options and Nakama research
  - 01c6e3d Document VirtuCade master traffic and caching policy
  - 904f7fa Document VirtuCade ghost guest hub rules
  - 6c80cd0 Document VirtuCade infrastructure plan
  - b4fdb8c Document Intersect Engine architecture research

## Handoff Chain

- **Continues from**: None (fresh start)
- **Supersedes**: None

> This is the first handoff for the VirtuCade infrastructure continuation.

## Current State Summary

The repo currently contains a working Godot 4 multi-server MVP spike plus extensive documentation. The live Godot spike proves one shared project with client, master, chat, and world server roles using WebSocket-based Godot high-level multiplayer, separate client multiplayer contexts, persistent chat while swapping active world connections, and portal-based travel. The newest research focused on how VirtuCade should evolve from this spike. The current documented recommendation in `docs/virtucade-infrastructure-options.md` is to spike Nakama as backend/control/social/database while keeping Godot headless dedicated world servers authoritative for gameplay, with a custom Master Backend as fallback. The user then corrected the option set: Option 2 should explicitly include PocketBase embedded in or paired with the custom Master server if possible, because PocketBase may provide authentication, database, admin UI, and HTTP REST login/register support. The next session should continue research, challenge assumptions, update documentation, and then proceed toward the recommended spike.

## Codebase Understanding

### Architecture Overview

Current project:

- One Godot project.
- `launcher/Launcher.tscn` selects runtime role by CLI args.
- Client uses branch-local/sibling multiplayer contexts for master, chat, and active world.
- Master server coordinates route/world registration.
- Chat server proves persistent cross-world chat.
- World server role is launched multiple times with `--world`.
- World scenes are minimal and inherit/shared enough to allow spawner/synchronizer experimentation.
- Documentation is now a major output of the project, not just implementation notes.

VirtuCade target architecture is still undecided. The conceptual roles are:

- Gateway/Auth/API: public HTTP entry, guest/login/register.
- Master/Coordinator/Database: durable truth, world registry, tokens, persistence.
- Social/Chat: live chat, presence, friends/guilds later.
- Godot World servers: authoritative gameplay scenes/instances.

However, the current decision question is whether those conceptual roles should be separate deployable services or collapsed into a backend platform.

### Critical Files

| File | Purpose | Relevance |
|------|---------|-----------|
| `README.md` | Main project index and documentation links. | Must be updated if new research docs are added or renamed. |
| `docs/virtucade.md` | Current proposed VirtuCade infrastructure guide. | Needs update if final recommendation changes around PocketBase or Nakama. |
| `docs/virtucade-infrastructure-options.md` | Current option comparison and Nakama research. | Primary doc to update with PocketBase Option 2 and any challenged findings. |
| `docs/godot-multi-server-architecture-guide.md` | Canonical explanation of the current working Godot spike. | Useful baseline for how current server/client code works. |
| `docs/godot-tiny-mmo-comparison.md` | Prior research on Godot Tiny MMO architecture. | Important comparison point for gateway/master/world and SQLite/chat design. |
| `docs/godot-tiny-mmo-database-resource-vs-sqlite-research.md` | Research on Resources vs SQLite and old MMO persistence patterns. | Relevant to PocketBase/SQLite/database ownership decisions. |
| `docs/intersect-engine-research.md` | Research on Intersect Engine. | Useful prior art for single authoritative server, map instances, DB split, and old MMO style. |
| `C:\Users\shilo\Downloads\virtucade_infrustructure_research.txt` | External research note from user. | Must be read and challenged; do not treat as authoritative. |

### Key Patterns Discovered

- Use `rg` first for repo searches.
- Use `apply_patch` for manual file edits.
- Keep documentation ASCII-only unless the file already uses Unicode.
- The user strongly values deep research, subagent challenge/review, and documentation before implementation.
- The user wants practical infrastructure with minimal workflow burden, not theoretical microservice purity.
- The project has a history of committing documentation milestones. Continue committing meaningful checkpoints.

## Work Completed

### Tasks Finished

- [x] Implemented and validated the Godot multi-server MVP earlier in the thread.
- [x] Documented Godot multi-server architecture.
- [x] Researched Godot Tiny MMO, JDungeon, Godot 4 network tutorial, and Intersect Engine.
- [x] Added `docs/virtucade.md` with Gateway/Master/World/Social conceptual architecture.
- [x] Added ghost guest hub rules to `docs/virtucade.md`.
- [x] Added live request, caching, Master traffic, and RAM/SQLite guidance to `docs/virtucade.md`.
- [x] Added `docs/virtucade-infrastructure-options.md` comparing full custom split, custom Master Backend, and Nakama + Godot World servers.
- [x] Used two subagents for the last options research:
  - Custom options 1 and 2 review.
  - Nakama + Godot dedicated world server review.

### Files Modified

| File | Changes | Rationale |
|------|---------|-----------|
| `docs/virtucade.md` | Added VirtuCade infrastructure guide, ghost guests, caching/Master traffic sections. | Capture target game infrastructure and gameplay entry rules. |
| `docs/virtucade-infrastructure-options.md` | Added Nakama/options research and recommendation. | Compare three possible directions before implementing next spike. |
| `README.md` | Linked new docs. | Keep docs discoverable. |
| `.claude/handoffs/2026-06-06-183416-virtucade-nakama-pocketbase-spike.md` | This handoff. | Enable fresh Codex session continuation. |

### Decisions Made

| Decision | Options Considered | Rationale |
|----------|-------------------|-----------|
| Keep Godot World servers authoritative for gameplay. | Nakama authoritative matches, Nakama relay, custom Godot worlds. | User wants normal Godot scene gameplay and dedicated world servers; Nakama relay is not authoritative enough. |
| Do not start with full custom Gateway + Master + Social split unless proven necessary. | Full custom split vs combined backend. | 100-300 CCU does not justify custom microservice sprawl at MVP stage. |
| Treat Nakama as promising but unproven for VirtuCade. | Commit to Nakama vs custom backend. | Nakama has auth/social/storage/chat, but Godot dedicated world admission/ticket flow must be spiked. |
| Keep external research note as input, not truth. | Trust it vs challenge it. | It argues for custom backend first; this may be right, but it conflicts with current repo doc recommendation. |

## Pending Work

## Immediate Next Steps

1. Re-read `docs/virtucade-infrastructure-options.md`, `docs/virtucade.md`, and `C:\Users\shilo\Downloads\virtucade_infrustructure_research.txt`.
2. Deeply research **PocketBase for Option 2**:
   - Can PocketBase be embedded in the same process as a Godot-based Master server?
   - If not, can a custom Go Master Backend embed PocketBase while Godot remains only World servers?
   - What auth/REST/admin/database features does PocketBase provide?
   - What are limitations for realtime chat/social, server-to-server world validation, and scaling?
3. Deeply research **Nakama + Godot dedicated world servers**:
   - Session-based dedicated server docs.
   - Server-to-server RPC.
   - Godot client library.
   - Admission ticket validation pattern.
   - Whether Nakama can cleanly replace Gateway + Master + Social for VirtuCade.
4. Use subagents heavily:
   - One agent for PocketBase feasibility and architecture.
   - One agent for Nakama dedicated server integration.
   - One agent to review/challenge the final docs before edits are committed.
5. Update `docs/virtucade-infrastructure-options.md` so the options are correctly framed:
   - Option 1: full custom infrastructure.
   - Option 2: custom infrastructure with PocketBase helping auth/database/HTTP REST, if feasible.
   - Option 3: Nakama for non-gameplay backend + Godot headless dedicated world servers.
6. Challenge the current recommendation. Do not assume Nakama wins just because it currently looks promising.
7. After research, decide the next implementation spike:
   - likely either Nakama admission-ticket spike, or PocketBase/custom backend proof.

### Blockers/Open Questions

- [ ] Can PocketBase truly run in the same process as Godot? Initial suspicion: probably not directly, because PocketBase is Go and Godot is not a Go host. It may need to be a separate process, or the "Master Backend" may need to be a Go service embedding PocketBase rather than a Godot process.
- [ ] If PocketBase runs separately, does it still satisfy the user's "minimal workflow" goal?
- [ ] Can PocketBase handle realtime social/chat needs, or only auth/database/REST/admin?
- [ ] Does Nakama's session-based dedicated server model fit persistent world servers rather than match-style sessions?
- [ ] What is the cleanest way for a Godot headless world server to validate Nakama/PocketBase-issued tickets?
- [ ] Should the next spike be Nakama first, PocketBase first, or a small comparison prototype of both?

### Deferred Items

- Full custom Gateway + Master + Social split. Defer until load or complexity proves it necessary.
- Production orchestration, Docker/Kubernetes/fleet management. Defer until backend choice is clearer.
- Custom packet protocol. Defer; current Godot high-level networking is still the relevant gameplay path.
- Full auth/password/security implementation in current Godot spike. Defer to selected backend approach.

## Context for Resuming Agent

## Important Context

The user is struggling with the infrastructure decision and wants the next session to continue research, not blindly implement. They specifically requested deep research and subagents. They now define the options as:

```text
Option 1:
Full custom infrastructure
Gateway + Master/Database + Social + World servers
Too much work, largest custom scalability.

Option 2:
Custom infrastructure, but with PocketBase embedded/used in Master if possible.
Goal: inherit account authentication, database, admin UI, and HTTP REST login/register support.
Needs heavy feasibility challenge.

Option 3:
Nakama for non-gameplay backend.
Godot headless dedicated servers for each world server.
Currently seems most promising and least workload.
```

The user also provided:

```text
C:\Users\shilo\Downloads\virtucade_infrustructure_research.txt
```

That note recommends Option 2 first with a Nakama spike in parallel. It argues:

- Nakama is not "Godot world servers in a box."
- Nakama authoritative multiplayer usually means writing Nakama runtime match logic.
- External headless Godot servers are possible, but require an orchestration/admission bridge.
- One custom backend + Godot world servers may be best MVP.
- Nakama could replace the backend if auth/chat/storage/RPC integration feels clean.

Challenge this note. It may be correct, but it is not authoritative. Compare it against official PocketBase and Nakama docs.

### Assumptions Made

- VirtuCade target scale is roughly 100-300 CCU, possibly dozens of world servers, likely never 1000 CCU.
- Godot world servers should remain authoritative for active gameplay.
- The user prefers minimal workflow over maximum theoretical scalability.
- Social/chat should persist across world travel.
- Guest players appear as ghosts in hub and cannot enter other worlds until login.
- World servers should not own durable character data if characters can transfer.

### Potential Gotchas

- "Nakama handles 20k connections" does not mean it can run 20k Godot gameplay players. That benchmark is mostly idle/open WebSocket connections.
- Nakama uses a real database. It is not a no-database backend.
- Nakama realtime sockets are not Godot `MultiplayerAPI`; Godot high-level nodes still need a Godot world server connection.
- PocketBase may be easy to run as a service but not easy or sensible to embed inside a Godot process.
- If PocketBase is used, it might become the backend database/auth/admin service, but another custom layer may still be needed for world registry, transfer tickets, and world-server trust.
- TCP/WebSocket head-of-line blocking is per connection, but server CPU/bandwidth and send queues can still become shared bottlenecks.
- Do not add docs without linking them from `README.md`.
- If making commits, emit git directives in the final response after successful stage/commit.

## Environment State

### Tools/Services Used

- PowerShell shell in `C:\Programming_Files\Shilocity\Godot\Tests\multi-server-test`.
- Web search/open for official docs research.
- `multi_agent_v1` subagents for architecture review.
- `session-handoff` skill for this file.
- `apply_patch` for file edits.

### Active Processes

- No known active Godot servers or background processes from this handoff creation.

### Environment Variables

- No relevant environment variable values were used or should be preserved.

## Related Resources

- [VirtuCade Infrastructure](../../docs/virtucade.md)
- [VirtuCade Infrastructure Options And Nakama Research](../../docs/virtucade-infrastructure-options.md)
- [Godot Multi-Server Architecture Guide](../../docs/godot-multi-server-architecture-guide.md)
- [Godot Tiny MMO Comparison Research](../../docs/godot-tiny-mmo-comparison.md)
- [Godot Tiny MMO Database Research](../../docs/godot-tiny-mmo-database-resource-vs-sqlite-research.md)
- [Intersect Engine Research](../../docs/intersect-engine-research.md)
- External note to challenge: `C:\Users\shilo\Downloads\virtucade_infrustructure_research.txt`
- Nakama docs to re-check:
  - https://heroiclabs.com/docs/nakama/getting-started/architecture/
  - https://heroiclabs.com/docs/nakama/concepts/multiplayer/session-based/
  - https://heroiclabs.com/docs/nakama/server-framework/runtime-examples/server-to-server/
  - https://heroiclabs.com/docs/nakama/client-libraries/godot/
- PocketBase docs to research:
  - https://pocketbase.io/docs/
  - https://pocketbase.io/docs/go-overview/
  - https://pocketbase.io/docs/authentication/
  - https://pocketbase.io/docs/api-records/

---

**Security Reminder**: Before finalizing, run `validate_handoff.py` to check for accidental secret exposure.
