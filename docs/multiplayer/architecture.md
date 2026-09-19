# Multiplayer Architecture

Living architecture record for the multiplayer effort (Jira epic **TGM-16**).

**How this relates to Jira.** Jira holds *how we got here* — per-ticket methodology comments,
investigation paths, wrong turns, files changed. This document holds *where we are now*: the
current set of decisions and what they imply. When a decision changes, this document is edited
in place and the superseded entry is struck through rather than deleted, so the record still
reads as a history. Each entry links the ticket whose comment carries the full reasoning.

**Status:** pre-implementation. No multiplayer code exists yet. Decisions D1–D16 are settled, each as a v1 answer that can be revisited;
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

### ~~D8 — World-mutating dev console commands become host-only in a session~~
*TGM-21, 2026-09-17 — implementation tracked on **TGM-27***

**Superseded 2026-09-18 by D13**, which makes the whole console host-only. Original entry kept below
for the record.

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

### D9 — Run ownership: one host-owned run, and multiplayer runs are single-sitting
*TGM-22, 2026-09-18 — v1, revisitable*

The host owns the one authoritative run: floor, `RNG` channels, items in play and every toon, all in
memory. Joining players' toons are materialised into it. This follows from D3 (host owns shared
state) and D5 (host keeps a disconnected toon alive in memory). The alternative — each machine
carrying its own toon state with only the floor shared — would contradict both.

A multiplayer run is **not saved**. `SaveFile.get_run_info()` reads `Util.get_player()` and builds a
single-toon file (`player_stats`, `player_dna`, `game_time`); it stays a single-player path. So v1
needs **no save-format change**, which was the expensive-to-undo outcome this spike existed to
avoid: there are no saved multiplayer runs to get the format wrong for. Rejoining after the host
restarts, and resuming with a different set of players, stay out of scope (D5).

Consequence: hosting a session must not touch the host's own single-player `current_save.tres`.
`title_screen.gd`'s `begin_game()` and `SaveFileService.on_game_over()` both call
`delete_run_file()`, so the multiplayer entry and game-over paths must not route through them.

### D10 — Progress and achievements count; each client writes its own file
*TGM-22, 2026-09-18 — v1, revisitable*

Progress and achievements earned in a session someone else hosted count. Each machine's
`ProgressFile` keeps listening to its own local signals and saving to its own `progress.tres`;
nobody writes another machine's file. `SettingsFile` likewise never crosses the wire.

This depends on TGM-24. `BattleService` signals carry no player identity, and code that reads
`Util.get_player()` attributes events to whichever toon that resolves to, so "my kills" is only
correct once identity is in those payloads. There are about 70 `progress_file` references outside
`mods-unpacked/`. A client that inflates its own progress only affects its own file, which is
consistent with D3.

### D11 — Session settings: host-owned values are declared, and every setting gets classified
*TGM-22, 2026-09-18 — v1, revisitable*

A setting is **host-owned** if its value changes anything the host computes, or any wall-clock timing
the host waits on. Everything else is local. Every setting is classified when it is added; there is
deliberately no "everything else stays local" default, because that lets a gameplay-relevant setting
slip through unnoticed.

Classification of the current `SettingsFile`, read 2026-09-18:

- **Host-owned:** `battle_speed` (D7); `use_custom_cogs`, forced **off** in multiplayer; `skip_intro`,
  see D12.
- **Host-only:** `dev_tools`, see D13.
- **Local:** `fullscreen`, `fps_idx`, `anti_aliasing`, `camera_shake_setting`, `color_blind_mode`,
  `master_volume`, `music_volume`, `sfx_volume`, `ambient_sfx_enabled`, `control_style`,
  `camera_sensitivity`, `item_reactions`, `item_descriptions`, `item_popups`, `auto_sprint`,
  `show_timer`, `button_prompts`, `saved_controls`.

*Why custom cogs are off.* Custom cogs are `.cog` files in `user://save/custom_cogs/`, so a joining
player does not have the host's files. If floor generation is seed-driven (TGM-25), the cog pools must
match in content and order on every peer. `Globals.clear_custom_cogs()` already exists. The settings
menu's toggle calls `Globals.import_custom_cogs()` at runtime, so that toggle must be disabled inside
a session.

*Why the three item settings are local.* `item_reactions` only sets the local toon's emotion in
`item_description.gd`. `item_popups` gates a fire-and-forget UI in `WorldItem.collect()` that is never
awaited, so it has no timing effect. `item_descriptions` picks `big_description` or `item_description`
in `Util.do_item_hover()` and toggles the description bubble's `force_hide`. None of them changes state
or timing. Some descriptions are built at runtime (for example the jellybean item), so both machines
must agree on item values, but that is an item-sync concern rather than a settings one.

### D12 — Multiplayer always starts on the falling scene; boss cutscene skips are votes
*TGM-22, 2026-09-18 — v1, revisitable*

There are two different things called "skip intro".

**The `skip_intro` setting** is read only in `title_screen.gd`, where it chooses between
`falling_scene.tscn` (skip) and `cog_building_floor.tscn` (the tutorial floor) as the first scene.
Multiplayer always uses the falling scene and avoids the tutorial floor entirely, so players can never
start in different scenes. The accepted cost is that a new player joining a friend will not have seen
the tutorial; experienced friends can guide them. The existing tutorial is weak onboarding and would
need a rework before any wide release regardless.

**In-run cutscene skips** (for example `factory_silo_paint_boss.gd`, where `%SkipButton` calls
`skip_intro(tween)`) become a vote: the cutscene skips only once every connected player has pressed
skip. Disconnected players do not count, and the host owns the cutscene timeline, in line with D7. If
the vote proves troublesome, fall back to the host deciding. Implementation is deferred: the paint boss
room assumes a single `player` variable (`body_entered` sets `player = body`), so these rooms need
rework with the rest of the boss content. Only the paint boss code has been read; the other boss rooms
with skip code (`cgc_fairway_parkour_boss.gd`, `molten_lava_boss_chase.gd`,
`office_head_of_security_boss.gd`, `golden_goose_manager.gd`) were located but not read.

### D13 — The dev console is host-only; supersedes D8
*TGM-22, 2026-09-18 — implementation tracked on **TGM-27***

Only the host has the dev console. Clients have none, in release and debug builds alike; a client who
needs a debug action asks the host. This is simpler than D8's per-command split and there is no
exception for debug builds.

The `dev_tools` getter returns true in any debug build (`or OS.has_feature("debug")`), so the check
must be "am I the host" and must not consult that setting. Implementation is one guard in
`Command._attempt_run()`, which is already marked *do not override*, rejecting when not the host. D8's
per-command `is_host_only()` and its overrides are no longer needed. Whether the console UI is hidden
on clients or opens and rejects commands is left to TGM-27.

D3 still explains why this is a simplification rather than a security boundary: a client cheating on
its own toon was already accepted. For testing host and client on one machine, use the host
instance's console.

### D14 — Downed toons: idle, then revived; all downed ends the run
*TGM-22, 2026-09-18 — v1, revisitable*

In multiplayer, a toon reaching 0 laff never calls `Player.lose()`. That function calls
`SaveFileService.on_game_over()`, which deletes the local `current_save.tres`, then
`progress_file.on_player_died()`, and ends in `Util.on_player_died()`, which pauses the tree, shows the
lose menu and returns to the title. Running it on a client would delete that client's own single-player
save, so it must not run.

Instead the toon becomes **downed**: it stays idle until the current battle is over, and the host then
revives it at **10% of max laff**. A downed toon outside a battle (for example from a hazard) is revived
by the host **after a timer**; the duration is not decided and can be tuned during implementation. The
same rules apply to a player who is downed while disconnected. A downed toon **cannot be targeted** for
the rest of that battle and is revived only once the battle is over.

The run is over for everyone once **every connected player** is downed, even if a disconnected toon is
still alive: a game-over screen on every machine and back to the title. Nothing is saved or deleted,
since D9 means there is no multiplayer save.

For progress, `ProgressFile.on_player_died()` only adjusts `win_streak` (reset to 0 after a win streak,
otherwise one step further into a loss streak), and `deaths` is the lifetime "Times Gone Sad" counter
shown in the statistics panel. Both describe a run ending, so each client fires them **once, at run
over, on its own `progress.tres`**, not when its toon is merely downed and will be revived.

### D15 — Players are identified by a persistent id, not by peer id
*TGM-22, 2026-09-18 — v1, revisitable*

Godot assigns a client a new peer id each time it reconnects, so peer id cannot identify a returning
player. Each client generates a random UUID once, stores it locally, and sends it when joining. The
host keeps a map from that id to the toon; D5's reattach works through this map. The host refuses a join
whose id is already connected.

The id is a claim, not proof: anyone who knows another player's id could claim their toon while that
player is disconnected. That is the same accepted trust as D3 and is fine for a session of friends over
direct IP.

The id stays out of `SettingsFile`, because D10 says settings never cross the wire. Where it is stored is
left to implementation. Two instances on one machine share `user://` and would read the same id, so
testing needs an override such as a command-line argument.

### D16 — Battle rewards are per-player chests
*TGM-22, 2026-09-18 — v1, revisitable*

After each battle, every player gets their own chest. Only its owner can open it and collect the item.
This is because items, stats and gag tracks come only from chests, so sharing one chest among several
players would leave everyone underpowered.

`BattleManager.spawn_reward()` today spawns one chest that any `Player` body can open once, and
`Util.make_boss_chests()` builds the boss rewards from the single player's inventory (a toon-up only if
they lack one, beans only under 20). `spawn_reward()` also reads `player.better_battle_rewards`. All of
these are per-player, so each player gets their own chest or chest set.

An unopened chest waits for a disconnected player, but chests live in the floor scene, so a chest not
opened before the floor ends is **lost**. That is accepted for v1.

This covers battle rewards only. Chests found while exploring, and whether `ItemService.seen_items`
(one list per run) is shared across players' rolls, belong to TGM-23.

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

Added 2026-09-18 under TGM-22, from the same tree:

**Battle stats are keyed by the player node.** `Util.get_relevant_player_stats()` returns
`BattleService.ongoing_battle.battle_stats[get_player()]`. With every toon held on the host (D9),
`get_player()` has to mean the acting player here, which is another silently-wrong-but-compiling read
site for TGM-24.

**Item proximity is global and not scoped to the local player.** `WorldItem.body_reacted()` adds itself
to `ItemService.items_in_proximity` for any `Player` body, and `item_description.gd` picks the closest
item to `Util.get_player()`. A remote toon walking near an item could drive the local HUD's reaction
and description. `WorldItem.collect()` similarly shows its popup on whichever machine runs it, and uses
`Util.get_player()` in places rather than its `player` parameter.

**Run timer decay, unverified.** `game_timer.gd` calls `ScoreTally.modify_score(ChannelTimeBonus, -1)`
every second from `_process()`, and `player.tscn` bundles one per player. If every player's HUD is
instantiated, the time bonus could decay once per player. Not traced; verify under TGM-24.

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

## Constraints from TGM-22 on battle sync

These answers constrain the battle-sync work, since battle state has to know what is authoritative and
where it lives.

**Battle state lives on the host, in memory, for the session (D9).** Nothing about a battle needs a
serialised or saved representation in v1, so battle sync does not have to define one.

**Disconnected participants stay in the battle (D5).** A disconnected toon keeps its slot, remains a
valid target and does not act. Battle sync has to represent "present but not acting" instead of removing
the participant.

**Participants need a session identity that survives reconnection (D15).** Battle stats and participants
are keyed by `Player` node today. A reconnecting client gets a new peer id, so battle sync should key by
the persistent player id and not by peer id.

**Downed is a participant state (D14).** A downed toon stays in the battle, cannot be targeted, and is revived by the host when
it ends. The battle needs a "downed" state distinct from being removed via `someone_died()`, and an
"every connected player downed" check that ends the run even if a disconnected toon is alive.

**Rewards are issued per player (D16).** The end-of-battle reward step creates one chest per player and
records its owner.

**Progress attribution needs player identity in `BattleService` signals (D10).**

**Battle speed is a host-broadcast session value (D7, D11).** There is no per-client speed to sync.

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
- **Cog scaling by player count** (TGM-23). Whether cog HP and lure stacks scale with the number of
  players, and whether a disconnected toon counts. Player power scaling is settled: it comes only from
  chests (D16). A disconnected toon stays a valid target (D5), so counting it is the natural default.
- **Revive timer length** (D14). How long a downed toon outside a battle waits before the host revives it.
  Tune during implementation.
- **Player id storage and test override** (D15). Where the id lives, and how two instances on one machine
  get different ids.
- **Exploration chests and shared seen-items** (TGM-23). First-come or per-player, and whether
  `ItemService.seen_items` is shared across players' rolls.
- **Pool mutation by items.** `seed_misty.gd` adds a golden goose cog to `GRUNT_COG_POOL` on pickup and
  removes it on exit, so one player's item changes a pool that must agree across peers. Belongs to
  TGM-25.
- **Console targeting.** D13 says a client asks the host for a debug action. The console commands seen
  so far act on the local player, so how a host applies one to a client's toon is not decided. How
  commands pick their subject has not been read. Planned as a separate research ticket.

---

## Not yet decided

Floor generation determinism and the `RNG` sync model (TGM-25), and the multiplayer design ruleset — turn economy, cog scaling, group Lure, revival,
item buckets (TGM-23).

Run ownership and save state (TGM-22) is settled as D9–D16; its leftover edge cases are listed under
*Open questions*.
