# Multiplayer Architecture

Living architecture record for the multiplayer effort (Jira epic **TGM-16**).

**How this relates to Jira.** Jira holds *how we got here* — per-ticket methodology comments,
investigation paths, wrong turns, files changed. This document holds *where we are now*: the
current set of decisions and what they imply. When a decision changes, this document is edited
in place and the superseded entry is struck through rather than deleted, so the record still
reads as a history. Each entry links the ticket whose comment carries the full reasoning.

**Status:** pre-implementation. No multiplayer code exists yet. Decisions D1–D6 are settled;
implementation starts at TGM-26 (M1).

---

## Decision record

### D1 — Ship as a fork, not a mod-loader mod
*TGM-16, 2026-09-17*

Multiplayer is built as direct changes to the `grindworks` repo on the `multiplayer/main`
integration branch, not as a mod under `mods-unpacked/` the way Endless Mode
(`Aallen170-EndlessMode`) is.

Multiplayer has to change autoloads, battle flow and scene structure, which script hooks cannot
reach cleanly. Script hooks also do not run under the editor's Play button — only in an exported
`.exe` — which would make iterating on a networking prototype painful.

### D2 — Transport: `ENetMultiplayerPeer`, behind a swappable interface
*TGM-21, 2026-09-17*

Use Godot's built-in high-level multiplayer with `ENetMultiplayerPeer` over direct IP. The
transport must sit behind a thin project-level interface so it can be replaced without touching
game code.

Godot's `MultiplayerPeer` is already an abstraction with multiple implementations, so keeping our
own seam thin costs almost nothing now and preserves the option to move to a relay later (D4)
without a rewrite.

### D3 — Authority: host owns world state, trusts client actions
*TGM-21, 2026-09-17*

The host is the single owner of shared state — cog HP, floor contents, turn resolution, item
rolls. Clients send their chosen actions and the host applies them **without validating that the
client was entitled to take them**.

This is not a one-way door. Validation can be added per-action later without re-architecting,
because the message on the wire is identical either way (*"I used gag X on target Y"*); the only
difference is whether the host checks the claim before applying it.

What this already protects: a modified client cannot corrupt another player's toon or desync the
run. Worst case it inflates itself. What it does not protect: a modified client claiming absurd
damage. Accepted, because this is co-op PvE with no ladder, economy or persistent ranking — the
harm is self-limiting and the remedy is social. It is also difficult to justify validating gag
damage over the network while the game ships a dev console whose `godmode` command maxes damage,
defense, gag tracks and jumps in single player.

Revisit if public matchmaking with actual strangers ever becomes a goal.

### D4 — Connection: direct IP and port forwarding for v1
*TGM-21, 2026-09-17*

v1 is host-enters-nothing, joiner-types-an-address. Players who cannot port forward use a virtual
LAN tool (ZeroTier, Tailscale). Frictionless "click a friend's name" joining is explicitly a
later goal, not abandoned — D2 exists to keep it reachable.

Surveyed for later: Epic Online Services is free, engine-agnostic, does not require shipping on
the Epic store, and provides NAT punchthrough with a free relay fallback plus lobbies; Godot
GDExtension integrations exist for 4.2+. Steam networking is effectively unavailable, since a
Toontown fangame will not ship on Steam. A self-hosted relay is not worth paying for while EOS
is free.

**Open, and deliberately not decided here:** adopting EOS means registering a product with Epic
and accepting a developer agreement, which attaches an identifiable developer account to a fan
project built on someone else's IP. That is a judgment call to make consciously before building
on it, not a technical blocker.

### D5 — Disconnect and rejoin: in-memory reattach
*TGM-21 / TGM-22, 2026-09-17*

When a player disconnects, the host keeps their toon alive in memory for the rest of the session.
Reconnecting reattaches their peer to a body that never left. No disk serialization, no world
snapshot — the run is still running.

Behaviour while disconnected: the toon stands and idles. If it happens mid-battle, the toon
simply does not act; it is still a valid target and still occupies its slot.

Consequence, which belongs to the turn economy rather than here: the battle needs a turn clock so
a missing or AFK player cannot stall the round, plus a host command to force a turn to end. See
*Open questions* below. Rejoining after the **host** restarts, or resuming a saved multiplayer
run, is a different and much more expensive problem and is explicitly out of scope for v1.

### D6 — Mod loader keeps working; Endless Mode multiplayer deferred
*TGM-21, 2026-09-17*

The mod loader stays functional in multiplayer builds so the fork does not lose modability.
Endless Mode is not expected to work inside a multiplayer session yet; combining them becomes its
own ticket once battle and floor sync exist.

### D7 — Battle speed is host-controlled; the host drives round advancement
*TGM-21 / TGM-23, 2026-09-17*

Two separate things, settled together because they were confused for alternatives:

**Round advancement is host-driven.** The host decides when round resolution ends and the next
selection phase begins. This is not extra work — it falls directly out of D3, since the host
already owns turn resolution. Clients play their animations and follow. The host does **not** wait
on per-client "finished animating" acknowledgements; that is a more expensive design and is not
needed for v1.

**Battle speed becomes a session value owned by the host.** `battle_manager.gd:109` currently reads
`SaveFileService.settings_file.battle_speed`, a per-player setting. In multiplayer it reads a
host-broadcast session value instead, and `battle_speed_control.set_speed()` is gated so only the
host can change it — clients see the control as read-only or hidden.

Without this, a client at 4x finishes the round's animations in a quarter of the host's wall-clock
time and then idles until the host advances, which makes the slider feel broken rather than fast.
Forcing the host's value keeps local playback aligned with the timeline the host is actually
running. Note that identical `Engine.time_scale` does not give frame-identical timing — frame rates
and `delta` accumulation still drift — but because advancement is host-driven, that drift is
cosmetic rather than a desync.

Per-player battle speed could return later if clients ever drive their own playback independently.
Not worth the complexity for v1.

### D8 — World-mutating dev console commands become host-only in a session
*TGM-21, 2026-09-17 — implementation tracked on **TGM-27***

The dev console stays available in multiplayer, but commands that mutate world state the host owns
are rejected on clients.

The distinction that matters is **cheating vs. desyncing**, and D3 already settled the first one:
a client running `godmode` or `give item` is cheating, which is accepted. The commands that have to
be blocked are the ones that make the two machines disagree about the world — `TimeScaleCommand`
and `PersistTimescaleCommand` (which deliberately carries a scaled `Engine.time_scale` past the
normal resets), plus `NukeCommand`, `NextFloorCommand`, `SpawnItemCommand` and
`OverrideNextChestItemCommand`, and anything that consumes `RNG` channels.

Implementation is small. Every command funnels through `Command._attempt_run()`, which is already
marked *do not override*, so this is one virtual `is_host_only()` on the `Command` base class, a
single guard in `_attempt_run()`, and a one-line override on the affected commands. The
`command_types` registry does not need restructuring.

---

## Codebase findings that shape the design

Measured against repo version `1.2.7`, Godot `4.6`, on 2026-09-17.

**`Util.player` has exactly one assignment site.** `Util.player = self` in `_ready()` at
`objects/player/player.gd:152`. The 711 references across 226 files are all *reads*. This is much
better news than the raw count suggests: gating that single assignment on
`is_multiplayer_authority()` makes `Util.player` mean "the local player" and leaves every read
site working. It strongly favours the registry option under TGM-24 over a broad refactor.

**`player.tscn` bundles per-player camera and the entire HUD.** The scene contains
`PlayerCamera` and a `GUI` subtree (`LaffMeter`, `BeanJar`, `FloorLabel`, `GameTimer`,
`ItemDescriptions`, `ActiveItemUI`, `QuestNotification`). Instantiating it for a remote player
would produce four cameras and four HUDs. The scene has to be split into a replicated toon body
and a local-only camera/HUD layer before any replication work. This is the largest structural
change M1 implies.

**The player is instantiated at runtime in two places**, both via `load(...).instantiate()`:
`scenes/elevator_scene/elevator_scene.gd:32` and `scenes/game_floor/game_floor.gd:144`. Under a
`MultiplayerSpawner` these become spawn-function calls instead.

**The battle authority seam is narrow and clean.** `battle_ui.gd:56 gag_selected(gag: BattleAction)`
is where a chosen action enters the system, and `battle_manager.append_action()` is where it lands
in `round_actions: Array[BattleAction]`. A client's action becomes one RPC to the host, which calls
`append_action()` locally and broadcasts the resolved round. The battle system does not need to be
rewritten to be host-authoritative — it needs one interception point.

That same function is also the clearest example of the risk TGM-24 has to manage: `gag_selected()`
sets `gag.user = Util.get_player()`, which today means "me" and must come to mean "the acting
player". It compiles and runs unchanged under a registry migration while being silently wrong.
Read sites like this one are the real work, not the mechanical ones.

**Player movement state is already a replicable property.** `Player.state` is an exported enum
routed through a `FiniteStateMachine3D`, so movement sync is roughly position, velocity and one
enum rather than animation state by hand.

**`BattleService` signals carry no player identity** — around twenty of them
(`s_round_started`, `s_toon_dealt_damage`, `s_battle_participant_died`, …). Adding identity to
these payloads is a known, bounded piece of work under TGM-24.

---

## Known hazards

**Runtime-created `MultiplayerSynchronizer` node paths.** Godot issue
[#87426](https://github.com/godotengine/godot/issues/87426) reports that a `MultiplayerSynchronizer`
created at runtime can initialise before its scene is in the tree and fail to resolve its root
path. Reported against `4.2.1`; **status on `4.6` is unconfirmed and should be verified before
relying on runtime-spawned synchronizers.** This matters here because floors and players are both
built at runtime.

**Autoload property sync needs absolute paths.** Syncing a property on an autoload through a
`MultiplayerSynchronizer` requires the `/root/AutoloadName:property` form; the shorter spellings
silently fail. For this codebase, host-broadcast RPCs are likely a better fit than synchronizing
autoload properties directly.

**`@rpc` defaults are wrong for client→host messages.** The default is
`@rpc("authority", "call_remote", "unreliable", 0)`. A client sending its chosen action to the host
needs `@rpc("any_peer", "call_local", "reliable")`. Getting this wrong fails quietly.

**Multiplayer authority must be assigned before `_ready()`** and must be set consistently on every
peer, or RPCs targeting the node fail.

---

## Open questions

- **Battle turn clock** (TGM-23). Needed for AFK and disconnected players alike. Shape follows
  original Toontown: the clock runs **only during gag/cog selection**, disappears during attack
  animations, and resets for each toon's turn. Also needs a host command to force a turn to end.

  An earlier draft of this document claimed the clock had to use unscaled time because the battle
  speed slider drives `Engine.time_scale`. That was wrong, and the code says so: `apply_battle_speed()`
  is called at `battle_manager.gd:122` alongside `is_round_ongoing = true`, and `revert_battle_speed()`
  at line 232 — so `Engine.time_scale` is already `1.0` throughout the selection phase, which is the
  only phase the clock runs in. A `delta`-derived timer is fine. The one residual case is the dev
  console: `persist_timescale` sets `Globals.debug_persist_timescale`, which deliberately carries a
  scaled `Engine.time_scale` past the normal resets, so a scaled value *can* reach the selection
  phase during testing. `Time.get_ticks_msec()` is immune to that for free, but this is a robustness
  preference now, not a correctness requirement.

- **EOS developer account** (see D4).
- ~~**Player count ceiling.**~~ **Settled 2026-09-17: hard cap of 4.** Two players is the real
  near-term target; 4 is the design ceiling. Nothing in D2 or D3 is sensitive at this scale.
- **TGM-14 interaction.** Room streaming already breaks when skipping past chunk boundaries. Two
  players in different rooms is a routine version of that condition, so it will likely resurface
  during M1. Fixing it first may be cheaper than debugging it through a network layer.

---

## Not yet decided

Floor generation determinism and the `RNG` sync model (TGM-25), run ownership and save state
(TGM-22), and the multiplayer design ruleset — turn economy, cog scaling, group Lure, revival,
item buckets (TGM-23).
