# CursedGems — Phase 1 architecture

Version `0.1.0-phase1` (`Config.VERSION`). This document describes what exists in the
repository *today*, not what is planned. Where something is declared but not yet
used, it says so explicitly — see [Known gaps](#15-known-gaps). The procedure for
putting a build in front of a human being, and the sheet results are recorded on, live
in [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md).

---

## 1. The game in one paragraph

Gems are simultaneously your currency and your life. Every gem in the world can be
picked up, and every gem you pick up is both a payment and a heartbeat: a curse
drains your balance continuously, and the balance **is** your health bar. Summoning
a creature from an altar costs gems and grants a permanent follower — but that
follower raises your drain *forever*. Collecting is therefore a difficulty dial the
player turns themselves, and the drain rate on the HUD is the readout of how far
they have turned it.

The whole economy is a single equation, documented in
[§9 Economy model](#9-economy-model) and derived in
[`PHASE1_DESIGN.md` §2](PHASE1_DESIGN.md#2-the-model):

```
drain/min = (7.5 + 2.5 x creatures)  x  mercy  x  shrine
income    ~= 12.5 gems/min           (design assumption, not yet playtested)
```

0 creatures nets `+5/min`, 2 creatures is break-even, 4 or more loses. The player
chooses which of those states they are in, one summon at a time.

---

## 2. The one-command gate

Everything in this repository is validated **offline** — no Studio, no Roblox
account, no network. One command proves it:

```powershell
.\check.ps1          # verify everything (read-only)
.\check.ps1 -Fix     # reformat with stylua first, then verify
```

`check.ps1` runs four tools in order and exits `0` **only** if all four pass, so it
drops into a pre-commit hook or CI unchanged:

| # | Tool | What it proves | Failure means |
|---|------|----------------|---------------|
| 1 | `stylua` (`--check`, or format with `-Fix`) | Formatting is not a matter of taste here; it is checked. | Unformatted file — run with `-Fix`. |
| 2 | `rojo sourcemap` | Regenerates `sourcemap.json`, the file tree Luau actually sees. | A stale sourcemap makes the analyzer silently blind, so it is rebuilt every run. |
| 3 | `luau-compile` | Every `src/**/*.luau` parses and compiles, individually. | A syntax error or an illegal construct. |
| 4 | `luau-lsp analyze` | Strict type checking across the whole tree. **Zero diagnostics is the gate.** | Any diagnostic — the script prints each one and exits 1. |

Two traps are handled inside the script, and both are worth knowing before you
write your own tooling:

* **Explicit file arguments are mandatory.** `luau-lsp analyze` takes the file list
  on the command line; it does not discover `src` on its own.
* **The analyzer is routed through `cmd /c ... > log 2>&1`.** PowerShell surfaces
  luau-lsp's `[INFO]` lines on stderr as *terminating* errors, which would abort the
  script for no reason at all. The log is then parsed for diagnostics, and the
  process exit code is checked separately.

Expected output on a healthy tree:

```
[1/4] stylua       : clean
[2/4] rojo         : sourcemap.json regenerated
[3/4] luau-compile : 26 files compile
[4/4] luau-lsp     : 0 diagnostics

gate: PASS
```

Tool binaries live in `tools/` and are deliberately **not** part of the repository: four
third-party executables plus an 850 KB engine type-definitions file, ~64 MB in total once
the release zips and the Rojo Studio plugin are in there. `tools/README.md` records the
layout this script expects and where each file comes from, so a fresh clone is
`git clone` plus that one fetch — and until the fetch happens the gate stops with
`Missing toolchain component`. The trade-off is logged in [§15](#15-known-gaps).



---

## 3. The trust boundary

The server owns **all** state. Clients send *intent* and receive *facts*. There is
no client-side prediction of anything that matters, and the client never decides
what it owns.

The complete wire is three instances, created on demand by `src/shared/Remotes.luau`
(which creates them when running on the server and waits for them when running on
the client, so neither side can race the other):

| Instance | Class | Direction | Purpose | Used? |
|----------|-------|-----------|---------|-------|
| `StateSync` | RemoteEvent | server -> client | Coalesced snapshot at 4 Hz (`Config.Net.STATE_SYNC_HZ`). | yes |
| `Feedback` | RemoteEvent | server -> client | Batched cosmetic results (pops, reveals, banners). | yes |
| `RequestState` | RemoteFunction | client -> server -> client | One-shot full snapshot for a joining (or suspicious) client. | yes |

There is no client -> server channel at all, and that is a considered decision rather
than an omission. Both interactive verbs are driven by `ProximityPrompt`, and a prompt is
a server-side instance: `ProximityPromptService.PromptTriggered` fires on the server, the
binding is resolved from server-owned data, and the distance is re-measured server-side.
There is nothing for the client to lie about, so there is nothing to validate and no
reason for the client to send intent in the first place.

An `Action` RemoteEvent — plus `src/server/RateLimiter.luau`, a token bucket written to
guard it, and `Config.Net.MAX_ACTIONS_PER_10_SECONDS` to size it — was built first and
then **removed**. An inert channel is not free scaffolding: nothing in the tree would
have called it, its config value would have had no reader, and a later phase could
easily have trusted a channel that was never wired. All three land together with the
first verb that genuinely needs client intent — fishing in Phase 2, or a quest hand-in
in Phase 3 — which is the change that also restores an action budget to `Config.Net`.

`Config.Net.MAX_POSITION_SLACK` (6 studs) is the slack allowed between what the
prompt implies and what the server measures:

```
gem pickup : COLLECT_RADIUS (7)  + slack (6) = 13 studs
summon     : INTERACT_RADIUS (9) + slack (6) = 15 studs
```

Both are wider than the prompt's own range (9 and 11), so an honest player is never
rejected while a teleporting one still is. Pickups are additionally throttled by
`Config.Net.MIN_SECONDS_BETWEEN_COLLECTS`, and summons by
`Config.Summon.ACTION_COOLDOWN_SECONDS` (a denial does **not** consume the cooldown,
because the pad requirement and the 0.35 s hold already bound the ask rate).

---

## 4. Layering and dependency direction

```
Config, Util, GemCatalog, CreatureCatalog, CreatureFactory, Remotes, Pool
                    (leaf modules; no dependencies at all)
                                ^
                                |
                             Modules                 one require-chain per side
                                |
                 +--------------+---------------+
                 |                              |
           server modules                 client modules
           (own the world)                (draw the world)
```

`src/shared/Modules.luau` requires every shared module **once**, in dependency
order, and returns them as a package. `src/server/Imports.luau` and
`src/client/Imports.luau` each perform the single long
`ReplicatedStorage:WaitForChild("CursedGems"):WaitForChild("Modules")` chain, so no
other file needs one:

```luau
local Shared = require(script.Parent.Imports)
local Config, Util, Remotes = Shared.Config, Shared.Util, Shared.Remotes
```

**The rule that matters:** the require direction is strictly one-way. No shared
module may ever require `Modules` itself, or the cycle fails at runtime the moment
the first script requires it. The gate cannot catch that class of mistake for you —
it is a runtime failure by construction, so it stays a convention, not a check.

---

## 5. Repository layout

`default.project.json` is the only place the Roblox tree is declared. Rojo maps the
three source folders into three services:

```
CursedGems/                            (rojo project name; the GitHub repository)
├─ check.ps1                           the gate: stylua + rojo + luau-compile + luau-lsp
├─ default.project.json                src/shared -> ReplicatedStorage.CursedGems
│                                      src/server -> ServerScriptService.CursedGems
│                                      src/client -> StarterPlayer.StarterPlayerScripts.CursedGems
├─ .stylua.toml                        100 cols, 4-space indent, Unix endings, double quotes
├─ .gitattributes                      forces LF on checkout; marks places and models binary
├─ .gitignore                          keeps tools/, build/ and generated files out of the repo
├─ .cursorignore                       keeps the same paths out of editor indexing
├─ README.md                           the front door: gate, build, play, status
├─ sourcemap.json                      generated by the gate; never hand-edit
├─ build/                              generated: CursedGems.rbxlx, analyze.txt
├─ docs/                               this document, DESIGN, PLAYTEST
├─ tools/                              ignored: stylua, rojo, luau-compile, luau-lsp + globalTypes.d.luau
└─ src/
   ├─ shared/   8 modules -> ReplicatedStorage.CursedGems
   ├─ server/   10 files  -> ServerScriptService.CursedGems
   └─ client/   8 files   -> StarterPlayer.StarterPlayerScripts.CursedGems
```

The two dotfiles are load-bearing rather than decorative. `.gitattributes` pins `eol=lf`
because `stylua --check` reads `line_endings = "Unix"` from `.stylua.toml` while Git for
Windows defaults to `core.autocrlf=true` — without it, a fresh clone fails step 1 of the
gate on files nobody edited. `.gitignore` deliberately does **not** list `*.rbxm`: models
are the first assets this project will own, so they have to stay committable, and the one
`.rbxm` in the tree is a tool.

The `.luau` suffix drives the class mapping: `*.server.luau` becomes a `Script`,
`*.client.luau` becomes a `LocalScript`, and a plain `*.luau` becomes a
`ModuleScript`. `rojo build default.project.json --output build/CursedGems.rbxlx`
builds a place file from exactly the same tree, so what the gate checks and what
Studio opens cannot drift apart.

**Rojo writes the API dump's defaults, not just the tree.** Each service the project
*declares* is serialized with the full property set from the Roblox API dump, so a
property the project never mentions is written at the dump's default rather than at
Studio's new-place default — and Studio applies whatever is in the file when it opens.
Two of those defaults quietly contradicted this design before they were declared
explicitly:

* `Players.CharacterAutoLoads` defaults to `true`. This game loads a player's state
  *before* the character exists ([§10](#10-persistence)), so the flag is now declared
  `false`; `A2` in [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) is the check that proves
  the load path actually completes.
* `TextChatService.ChatVersion` defaults to `LegacyChatService` (`0`). The place is now
  pinned to `TextChatService` (`1`), and `A17` is the check.

Neither is visible in `src/`, which is exactly why they are worth a paragraph: no amount
of type checking can catch a property that Studio supplies from the project file. The
proof lives in the *built* place, not the project file — 35 items, five services,
`<bool name="CharacterAutoLoads">false</bool>` and `<token name="ChatVersion">1</token>`.
If you change `default.project.json`, rebuild before you play: Studio plays the place,
not the project.

---

## 6. Module inventory

26 files, all `--!strict`, all formatted, zero analyzer diagnostics.

### Shared (`src/shared`)

| Module | LOC | Job | Public surface |
|--------|----:|-----|----------------|
| `Config.luau` | 255 | The single source of truth for every tunable. Logic files must contain **no** magic numbers. | `VERSION`, `Economy`, `Gems`, `Tags`, `Summon`, `Curse`, `World`, `Follower`, `Net`, `Data`, `Debug` |
| `Util.luau` | 70 | Small pure helpers. | `weightedPick`, `shuffle`, `round`, `distanceXZ`, `isFiniteNumber`, `abbreviate` |
| `Pool.luau` | 105 | Instance pooling, so the gem field never allocates during play. | `new`, `prewarm`, `acquire`, `release`, `releaseAll`, `stats`, `destroy` |
| `GemCatalog.luau` | 94 | The two Phase 1 gem kinds and their odds. | `Kinds`, `ById`, `get`, `roll`, `expectedValue` |
| `CreatureCatalog.luau` | 489 | The five Phase 1 creatures, assembled from primitives rather than meshes. | `List`, `ById`, `get`, `roll`, `byRarity` + `CreatureDef` |
| `CreatureFactory.luau` | 127 | Turns a `CreatureDef` into a `Model`, or a `CFrame` for one. | `build(def, parent?)`, `pivotCFrame(def, ground, facing)`, `highestPoint(def)` |
| `Remotes.luau` | 97 | Creates the remotes on the server, waits for them on the client. | `Folder`, `StateSync`, `Feedback`, `RequestState` |
| `Modules.luau` | 32 | Requires all seven above once, in dependency order. | a package table: `Config`, `Util`, `Pool`, `GemCatalog`, `CreatureCatalog`, `CreatureFactory`, `Remotes` |

### Server (`src/server`)

| Module | LOC | Job | Public surface |
|--------|----:|-----|----------------|
| `Main.server.luau` | 61 | Bootstrap. The start order *is* the content of this file. | — |
| `Imports.luau` | 5 | The one `WaitForChild` chain for shared modules. | the package |
| `DataStoreLite.luau` | 441 | Persistence: session locks, schema merge, batched autosave, retries, memory fallback. | `new`, `acquire`, `getSession`, `markDirty`, `save`, `saveWithRetry`, `release`, `isMemoryOnly`, `getStats` |
| `PlayerDataService.luau` | 514 | The **only** place a player's currency, collection or stats change. | `load`, `awaitSession`, `getSession`, `getData`, `getGems`, `addGems`, `spendGems`, `applyDrain`, `recordPickup`, `getCreatures`, `creatureCount`, `addCreature`, `lifetimeSummons`, `getSummonCost`, `getUpkeepPerMinute`, `getGraceRemaining`, `addCursedSeconds`, `getStoreStats`, `isMemoryOnly`, `start` |
| `WorldBuilder.luau` | 748 | Deterministic, seeded construction of the whole map. | `build() -> BuildResult { folder, gemSpawnPoints, pens, shrineCenter }` |
| `GemSystem.luau` | 453 | The gem field: spawn legality, pool target, prompts, pickup validation, respawn. | `start(points)`, `stop`, `getStats`, `forceReconcile` |
| `SummonSystem.luau` | 220 | The altars: spend gems, roll a creature, reveal it, notify witnesses. | `start(pens)`, `stop`, `getAltarCount` |
| `CurseSystem.luau` | 241 | The drain: ticks the debt, escalates warnings, applies the curse. | `start(center)`, `stop`, `isCursed(player)`, `currentRatePerMinute(player)` |
| `FollowerSystem.luau` | 205 | Keeps up to `MAX_VISIBLE_FOLLOWERS` creatures trailing each player. | `start`, `stop`, `getStats` |
| `StateSync.luau` | 150 | The one place server truth becomes client-visible. | `start`, `stop` |

### Client (`src/client`)

| Module | LOC | Job | Public surface |
|--------|----:|-----|----------------|
| `Main.client.luau` | 44 | Bootstrap: `ClientState` -> `Hud` -> `EffectFx` -> `SpinFx`, plus its two tag registrations. | — |
| `Imports.luau` | 5 | The one `WaitForChild` chain for shared modules. | the package |
| `ClientState.luau` | 251 | The client's mirror of server truth. No independent copy of any number; the one value it projects between snapshots is the run-dry countdown, from the rate the server sent. | `get()`, `remainingSeconds()`, `isLoaded()`, `onChanged(cb)`, `start()` + `Snapshot`, `CollectionEntry` |
| `Theme.luau` | 199 | Colours, fonts, rarity palette and widget factories. Asset-free. | `Color`, `Font`, `Rarity`, `RarityOrder`, `rarityColor`, `rarityRank`, `corner`, `stroke`, `pad`, `tween`, `frame`, `label`, `button` |
| `Hud.luau` | 701 | The UI composition root: builds every widget, owns `CollectionPanel`, repaints at 4 Hz — plus the countdown every frame. | `start()` |
| `CollectionPanel.luau` | 267 | The grid of collection cards, each with a live 3D preview; undiscovered species are silhouettes. | `create(parent)`, `setEntries(entries)`, `toggle()`, `isOpen()` |
| `EffectFx.luau` | 206 | World-space feedback: pickup pops, reveal flashes, witness flashes. | `start()` |
| `SpinFx.luau` | 137 | The one ambient animation loop, driven by CollectionService tags. | `track(tag, spin, bobHeight, bobSpeed)`, `start()`, `count()` |

---

## 7. Boot sequence

Both bootstraps encode an order that is a design decision, not an accident. Neither
one simulates anything.

### Server (`Main.server.luau`)

```
1. PlayerDataService.start()          data first: a player joining mid-build still
   + isMemoryOnly() warning           gets a session, and no gameplay system will
                                      act on a player whose data is not authoritative
2. WorldBuilder.build()               world second: every system is HANDED positions
                                      from the result instead of rediscovering them
3. GemSystem.start(build.gemSpawnPoints)
   SummonSystem.start(build.pens)
   CurseSystem.start(build.shrineCenter)
   FollowerSystem.start()
4. StateSync.start()                  last, so the first snapshot is a complete one
```

The final `print` reports the ready time in ms, the legal gem positions, the altar
count, and the base/mercy/shrine drain rates — a one-line health check in the
output window.

### Client (`Main.client.luau`)

```
1. ClientState.start()    the mirror every other module reads. Started first, so no
                          view can paint a default balance the player never had
2. Hud.start()            builds the widgets and subscribes to that mirror
3. EffectFx.start()       world-space feedback; second subscriber to the same events
4. SpinFx.track(PEN_MARKER, ...)   the two ambient tags, registered here rather than
   SpinFx.track(GEM, ...)          inside SpinFx, which knows nothing about this game
   SpinFx.start()          the one ambient loop, started last: it only needs the
                          world to exist, and it sweeps for tagged instances
                          rather than requiring them at start
```

`Hud` is the client's composition root: it registers `CollectionPanel` as well, so
the panel never needs to be started by the bootstrap.

---

## 8. Replication model

Two update shapes, deliberately different sizes.

### The stream: `Remotes.StateSync` (4 Hz)

`StateSync.step()` walks the players and sends a **summary** to each one:

```luau
{
    gems         = number,   -- balance; the HUD never keeps its own copy
    drainPerMinute = number, -- read from CurseSystem.currentRatePerMinute
    grace        = number,   -- remaining spawn-grace seconds
    creatureCount = number,
    cursed       = boolean,
    summonCost   = number,   -- the price the prompt should display
    collection   = { { slot, id, obtainedAt } }?,  -- only when its signature changes
}
```

The summary is tiny and changes constantly, so it goes out every tick. The
**collection** changes a handful of times per session and its payload grows with the
collection, so it is attached only when `collectionSignature(player)` (the ids
joined with `|`) differs from the last one sent. Sending it four times a second
would buy no new information at a cost that grows with playtime.

Only ids, slots and timestamps travel. Names, rarities and colours live in the
shared `CreatureCatalog`, which the client already loads in order to build the
reveal animation; shipping them too would create a second source of truth for the
same string.

`Remotes.RequestState` covers the moments the stream is not enough: a client that
has just joined, or one that suspects it missed something. It answers from the same
`buildSnapshot` builder as the stream — so the two can never disagree — and it
deliberately returns `nil` when there is no authoritative session yet (the client's
job is then to ask again, not to apply half a snapshot).

### The events: `Remotes.Feedback` (never state-bearing)

`Feedback` carries *cosmetics only*. The HUD's balance always comes from the
stream; a feedback payload's `balance` field exists so a pop or a toast can be
consistent with the change that caused it, not to update state.

| `kind` | Sender | Fields | Consumer |
|--------|--------|--------|----------|
| `gemCollected` | `GemSystem.handleTriggered` | `gemKind`, `value`, `balance`, `position` | `EffectFx` (world-space pop) |
| `summonReveal` | `SummonSystem` (to the summoner) | `penIndex`, `position`, `cost`, `balance`, `creatureId`, `displayName`, ... | `Hud` (reveal card), `EffectFx` (flash) |
| `witnessSummon` | `SummonSystem` (to everyone within `BROADCAST_RADIUS`) | `penIndex`, `position`, `creatureId`, `displayName`, ... | `Hud` (banner), `EffectFx` (flash) |
| `curseWarning` | `CurseSystem.step` | `level`, `balance`, `drainPerMinute` | `Hud` (escalating banner) |
| `curseChanged` | `CurseSystem.updateCurseState` | `cursed`, `balance` | `Hud` (banner + gradient tint) |
| `summonDenied` | `SummonSystem` | `reason = "gems"`, `cost`, `balance` | `Hud` (toast) |

`summonReveal` and `witnessSummon` both carry `creatureId`, so a witness renders the
**same** creature the summoner saw rather than a lookalike — one field, and the
whole class of "my friend's pet looks different on my screen" bugs disappears.

### Client side of the contract

`ClientState` is the only module that touches the remotes. It applies each snapshot
to one `Snapshot` table and notifies subscribers (`Hud`, `CollectionPanel` and any
future view) through `onChanged`. `Hud` repaints from
`ClientState.get()` on the same 4 Hz tick, which is why the HUD keeps **no**
independent balance copy: there is exactly one number on the client, and it arrived
from the server.

The one value the client moves between snapshots is the run-dry countdown, and it
is still not an independent number: `ClientState.remainingSeconds()` projects
`balance - rate/60 * age` from the last anchor at the rate the server sent with it
(see [§12](#12-the-client-presentation-layer)). The anchor moves only when a
snapshot disagrees with that projection by more than one billing tick
(`CurseSystem` bills at 1 Hz, the stream runs at 4 Hz) or when the rate itself
changes — re-anchoring on every snapshot would hand the label back the drain it
had already accounted for and make it tick *backwards*. A dead stream freezes the
projection 1.5 s after the last snapshot instead of walking a disconnected player
to zero.

---

## 9. Economy model

Every number below comes from `Config.luau`; the arithmetic is reproduced here so
the balance can be re-derived without reading five files.

### The drain

```luau
-- PlayerDataService.getUpkeepPerMinute
base   = BASE_DECAY_PER_MINUTE + UPKEEP_PER_CREATURE_PER_MINUTE * creatures
       = 7.5 + 2.5 * creatures

-- CurseSystem.currentRatePerMinute
rate   = base
rate  *= MERCY_MULTIPLIER          if gems < MERCY_THRESHOLD      (5)  -> 0.5
rate  *= SHRINE_DECAY_MULTIPLIER   if inside SHRINE_SAFE_RADIUS   (48) -> 0.25
```

`currentRatePerMinute` is a single function, exported, read by both the tick that
**charges** and by `StateSync` that **displays**. A HUD showing a different number
from the one being charged would be worse than no HUD at all.

The multipliers stack (a broke player standing at the shrine pays `0.125x`), which
is the intended reading: the shrine is where you go to think, and being broke there
is survivable rather than fatal.

### The tick

`CurseSystem` runs a 1 s tick. Per player, in order:

1. Skip if there is no session (data still loading) — never mutate a table that is
   not yet authoritative.
2. Skip entirely while `SPAWN_GRACE_SECONDS` (60) remains, so onboarding is safe.
3. `applyDrain(rate / 60 * delta)` — the amount is **fractional** and floored at
   zero. Rounding to whole gems every tick would turn a 7.5/min drain into a 60/min
   drain, and gems must never go negative or the mercy rule would read as a debt.
4. If the balance is already 0, count the time instead
   (`addCursedSeconds(delta)`) and keep the curse showing.
5. Warn on threshold crossings only. `WARN_AT = { 25, 10 }` is authored descending,
   so the last threshold crossed wins and the client escalates. Recovering back
   above a threshold resets silently — a player who hovers on the line is not warned
   over and over.
6. `delta` is clamped to `TICK_SECONDS * 3`: a server hitch must never be billed to
   the player as several minutes of drain in a single tick.

### Income

```luau
expectedValue = (COMMON_WEIGHT * COMMON_VALUE + CURSED_WEIGHT * CURSED_VALUE) / 100
              = (92 * 1 + 8 * 5) / 100
              = 1.32 gems per pickup
```

The field targets `POOL_BASE` (12) plus `POOL_PER_PLAYER` (4) per player, clamped
between `POOL_MIN` (16) and `POOL_MAX` (44) and never above the number of legal points.
Sixteen live gems is four per pocket, and that density is load-bearing: the income model
is a function of how far the average gem is, so multiplying pocket area without adding
gems divides income (measured: twelve gems in the widened pockets pays 10.2 gems/min
instead of 12.5).

A pick-up reserves its slot for 8-12 s (`RESPAWN_MIN_SECONDS`/`RESPAWN_MAX_SECONDS`, plus
up to one 0.5 s scheduler tick) before the index is legal again, then respawns at a
freshly randomised point.
Randomised delay **and** location on purpose: a fixed respawn turns farming into a
memorised route, which is a chore rather than a game. The reservation is what makes the
delay real — the sweep skips cooling indices and counts pending respawns as gems the
field is already owed, so it cannot refill the hole from somewhere else on its next tick.

`GemCatalog.expectedValue()` exists so this number is computed rather than asserted.

### The balance

The `[SIM]`-tagged values assume roughly 9.5 pickups/min (about 12.5 gems/min for a
player who keeps moving):

| Commitments | Drain/min | Net/min | Reading |
|-------------|----------:|--------:|---------|
| 0 creatures | 7.5 | **+5** | You are banking gems. |
| 1 creature | 10 | +2.5 | Comfortable. |
| 2 creatures | 12.5 | **0** | Break-even. |
| 3 creatures | 15 | -2.5 | You are working for your pets. |
| 4+ creatures | 17.5+ | negative | The collection *is* the difficulty. |

### Summons

| Situation | Cost |
|-----------|-----:|
| Very first summon of a player's **lifetime** | `FIRST_SUMMON_COST` = 10 (`stats.summons` is lifetime, not per-session) |
| Every summon after that | `COST` = 25 |

The first summon is deliberately cheap so every new player finishes their first
session owning a visible creature. The cost is re-read from the **server** session at
the instant of the spend, so a client that believes it is owed the discount still
cannot be charged less than it owes.

There is deliberately **no collection cap.** An arbitrary limit is a rule the player
cannot see the reason for; the upkeep curve is legible on the HUD as a drain rate.
The curve *is* the cap.

---

## 10. Persistence

`DataStoreLite` is a deliberately small, self-contained persistence layer (no
cross-server messaging, no per-key budget management, no migration tooling — Phase 1
needs none of them). `PlayerDataService` is the only consumer, and it is the only
module that knows the save schema.

### The save schema

```luau
SaveData = {
    version: number,          -- 1; bumped when the shape changes
    gems: number,
    creatures: { { id: string, obtainedAt: number, slot: number } },
    stats: {
        gemsCollected, cursedGemsCollected, gemsSpent, summons, cursedSeconds,
    },
    firstJoinAt: number,
    lastSeen: number,
}
```

Four rules make this safe to grow:

1. **Schema growth is a merge, not a migration.** Defaults are merged into whatever
   was loaded, so adding a field in a later phase cannot break an existing save.
2. **Defaults are deep-copied per player.** Sharing one default sub-table across
   every player in the server is a classic and very hard-to-spot data bug.
3. **`gems` is fractional.** The drain charges fractions of a gem, so the stored
   number is not rounded to an integer.
4. **The session baseline is not part of the save.** `PlayerDataService.Session.baseline`
   is a copy of `stats` taken at load and held only for the life of the session, so a
   playtest can report *this session* rather than a lifetime total. It is deliberately
   never persisted: the lifetime total is the only thing that must survive a rejoin, and
   a stored baseline would be one more field to migrate.

`stats` is not decoration: `cursedSeconds` is marked dirty on curse-state
**transitions**, because that is the only moment the accumulated value would
otherwise be lost, and `summons` is lifetime — it drives the first-summon discount.

### Sessions and locking

`Config.Data` governs the layer:

| Setting | Value | Meaning |
|---------|------:|---------|
| `DATASTORE_NAME` | `CursedGems_PlayerData_v1` | The store. |
| `KEY_PREFIX` | `Player_` | Key namespace. |
| `AUTOSAVE_SECONDS` | 90 | Batched, never per-change: Roblox rate-limits, and per-change writes are the classic way to silently lose progress. |
| `LOCK_TIMEOUT_SECONDS` | 60 | Session lock expiry. |
| `MAX_SAVE_RETRIES` / `RETRY_BASE_SECONDS` | 5 / 1.5 | `saveWithRetry` backs off from 1.5 s. |
| `ALLOW_MEMORY_FALLBACK` | `true` | Keeps the game playable in unpublished Studio, where DataStore access does not exist. |

`DataStoreLite` tracks `{ loads, saves, failures, locksLost }` and exposes
`isMemoryOnly()` / `getStats()`. `Main.server.luau` warns loudly at boot if the store
came up memory-only, so "my progress vanished" is never a mystery.

`acquire(userId, defaults)` returns a **session wrapper**, not the save — the save is at
`.data`. It also reports `fresh`, true only when the key held no save at all, which is how
`PlayerDataService` distinguishes a first-ever player from a returning one instead of guessing
from timestamps (a brand-new save's `firstJoinAt` and `lastSeen` are both `now`). `fresh` is
correct in a memory-only server too, so the `JOIN` line stays honest in Studio.

Two log lines are the playtest's entire instrumentation, gated by
`Config.Debug.LOG_SESSION_SUMMARY`: `JOIN` per player (fresh vs `returning after Nh`, and whether
the session will persist) and `SESSION` per player on leave, carrying the session deltas for
`P1`–`P6` annotated with the prediction each number answers. Procedure and sheet:
[`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md).

A player's `Session` also carries `graceUntil` — the spawn-grace deadline the curse
system reads (`getGraceRemaining`). Grace is part of the session, not a separate
timer, so a rejoin cannot farm an endless grace period from a stale flag.

### Character spawning

`PlayerDataService` loads data, then spawns the character itself, probing
`LoadCharacterAsync` through `any` with a `LoadCharacter` fallback, so the project
runs on both newer and older Studio builds instead of leaving a player permanently
without a character.

---

## 11. World generation

`WorldBuilder.build()` constructs the whole map from primitives — no models, no
meshes, no asset ids — from a fixed seed (`Config.World.SEED = 20261017`), so every
server produces the same world.

```
BuildResult = {
    folder:         Folder,          -- one container, so the world is one thing to delete
    gemSpawnPoints: { Vector3 },     -- every LEGAL gem position, pre-validated
    pens:           { Pen },         -- summon altars: index, center, pedestal, prompt
    shrineCenter:   Vector3,
}
```

| Feature | Config |
|---------|--------|
| Map | `MAP_SIZE` 520, `GROUND_Y` 0 |
| Player spawn | `(0, 4, 44)` |
| Shrine (safe zone + social hub) | `(0, 0, 0)`, pad radius 26, safe radius 48, `0.25x` drain |
| Cave | centre `(-150, 0, -150)`, size `(96, 32, 96)` |
| Scatter | 90 trees, 55 rocks |
| Gem field | four pockets: 50-stud radius discs 108 studs from the shrine on the axes, 152.7 studs apart, so the shrine stays readable as social space |

The build result is **handed** to the systems rather than rediscovered by them:
`GemSystem.start(build.gemSpawnPoints)`, `SummonSystem.start(build.pens)`,
`CurseSystem.start(build.shrineCenter)`. World layout therefore has exactly one
owner.

Gem placement is enforced at spawn time, not just at build time:

* `MIN_GEM_SPACING` (13): no two gems crowd one spot. Inside a zone this is what
  makes four gems read as a pocket you can walk through rather than a pile; 152.7
  studs between zone centres makes the cross-zone case moot.
* `MIN_SPAWN_DISTANCE_FROM_PLAYER` (25) — nothing appears on top of somebody.
* `MAX_SPAWN_ATTEMPTS` (24) — then fall back to the least-bad legal point rather than
  starving the field. A crowded server getting a gem slightly too close is better
  than an empty field.

The field is **pooled** (`Pool.luau`): instances are prewarmed to
`min(POOL_MIN, #points)` and reused forever, so a full day of picking gems up does
not allocate a single new part. When the target shrinks (players leave), `reconcile`
retires the *most recently placed* gems first, so the field a player has been looking
at all session does not reshuffle under them.

---

## 12. The client presentation layer

Everything visual is built from primitives, gradients and tweens — **no images and no
sounds anywhere**. A fresh clone therefore runs in Studio with zero uploads, zero
moderation, and zero asset-id bookkeeping. `Theme.luau` is the only file that knows
what anything looks like; the other modules ask it for widgets.

### `Theme.luau` — the vocabulary

| Group | Contents |
|-------|----------|
| `Theme.Color` | The palette (panel, panelLight, text, muted, accent, danger, gold, ...) |
| `Theme.Font` | `Enum.Font` choices per role (title, body, number) |
| `Theme.Rarity` / `RarityOrder` | Common / Uncommon / Rare colours and their order, so sorting never invents a rank |
| `Theme.rarityColor(rarity)` / `rarityRank(rarity)` | The lookups those tables exist for |
| `Theme.corner` / `stroke` / `pad` | Consistent rounding, outlines and insets |
| `Theme.tween(instance, goal, seconds)` | One tween helper, so every animation is interruptible the same way |
| `Theme.frame` / `label` / `button` | Widget factories: parent, name, size, position, colour, and the styling |

### `Hud.luau` — the composition root

`Hud.start()` builds every widget and then repaints from `ClientState.get()` on each
4 Hz snapshot. `countdown` is the exception: it is repainted from `RunService.Heartbeat`
off `ClientState.remainingSeconds()`, because it is the one number that has to be
continuous — as a function of the snapped balance it could only move when a whole gem
left, i.e. in strides of `60/drain` seconds. Its widget set, top to bottom:

| Widget | Shows |
|--------|-------|
| `balance` | The gem counter — the player's number and their health bar at once |
| `drain` | Gems/min, straight from `CurseSystem.currentRatePerMinute` |
| `countdown` | Time to empty, projected every frame from the last snapshot and the rate that came with it, so it decrements a second at a time instead of holding for `60/drain` seconds and then lurching |
| `track` + `barFill` | The reserve bar: the same number, but glanceable |
| `grace` | The spawn-grace / shield pill while grace remains |
| `summon` | The **next summon price**, and it rewrites the altar `ProximityPrompt.ObjectText` so the world and the HUD never disagree about the cost |
| `banner` + `bannerText` | The cursed banner |
| `tint` + `tintText` + `tintNote` | The full-screen gradient tint that escalates with the curse |
| `toasts` | The toast queue, capped at 4 so a bad minute cannot bury the screen |
| `collectionButton` | Opens `CollectionPanel` |

`Hud` also owns the feedback handler for `curseWarning`, `curseChanged`,
`summonDenied`, `summonReveal` and `witnessSummon` — the five UI-shaped events. It
does **not** handle `gemCollected`, which is world-shaped and belongs to `EffectFx`.

### `CollectionPanel.luau` — the collection

A grid of cards, one per owned creature, each with a **live 3D `ViewportFrame`
preview** built by `CreatureFactory`. Undiscovered species render as true
silhouettes, so the panel always shows the size of the catalogue without spoiling
what is missing.

Two details keep it cheap: the card list is capped at `MAX_CARDS` (30), and it
rebuilds **only** when the owned-set signature changes — not on every snapshot,
because the collection is the one part of the panel that is expensive to build and
changes a handful of times per session.

### `EffectFx.luau` and `SpinFx.luau` — the world

`EffectFx` is the world-space feedback layer: pickup pops at the gem's position,
reveal flashes at the altar, and witness flashes for nearby players.

`SpinFx` is the one ambient animation loop. It is deliberately generic: it knows
nothing about gems or altars, only that some instances carry a CollectionService tag
and should spin and bob. `Main.client.luau` supplies the meaning:

```luau
SpinFx.track(Config.Tags.PEN_MARKER, math.rad(40),  0.5, 1.2)
SpinFx.track(Config.Tags.GEM,        math.rad(160), 0.3, 2.2)
```

That is why `Config.Tags` is centralised: a tag string is a **silent** failure mode.
A typo in a tag name does not error — the world looks completely normal and simply
never moves. One shared constant per tag, written by the server and read by the
client, is the fix.

---

## 13. TypeProbe notes (why the type requires look like that)

`Modules.luau` gives every shared module one require-chain. The reason it exposes
**values only** is a Luau language fact, not a style choice:

> A table constructor holds *values*. An exported type is not a value, so
> `Modules.luau` cannot re-export `CreatureCatalog.CreatureDef` or `GemCatalog.GemKind`.

The analyzer resolves an exported type only through a **local binding created
directly by `require()`**. So modules that need a shared *type* carry one extra,
deliberately isolated require for the type alone. `SummonSystem.luau` is the clearest
example:

```luau
local Shared = require(script.Parent.Imports)         -- values
-- Sibling require purely for the Pen TYPE. Luau resolves a module exported type
-- only through a local bound straight to require().
local WorldBuilder = require(script.Parent.WorldBuilder)
```

Practical rule for new code: take **values** from `Shared.*`, and add a direct
`require` with a local binding **only** when you need a type from that module. The
`CreatureFactory` re-export (`export type CreatureDef = CreatureCatalog.CreatureDef`)
is the other half of the same pattern — a module may re-export a type it imported
itself, which is what lets consumers name a creature definition without requiring the
catalogue.

---

## 14. Invariants

Rules the structure enforces, and rules only review can enforce.

### The gate enforces these

* Every file is `--!strict` and formatted (`stylua`).
* Every file compiles (`luau-compile`), individually.
* Zero analyzer diagnostics across the tree (`luau-lsp analyze`).
* The sourcemap the analyzer sees is regenerated on every run, so it cannot be stale.

### Review (and the structure) must enforce these

1. **Config owns every number.** If a logic file contains a literal that decides how
   the game feels, it belongs in `Config.luau`.
2. **`PlayerDataService` is the only writer of player state.** `gems`, the collection
   and `stats` change nowhere else, so "how did this number change?" has exactly one
   place to look.
3. **Requires point one way.** No shared module may require `Modules`.
4. **The client holds no independent copy of a server number.** A view paints from
   `ClientState.get()`; it never accumulates its own counter. The single value the
   client projects forward is the run-dry countdown, and only because the balance it
   would otherwise show is quantised to whole gems: it is `balance - rate/60 * age` at
   the rate the server sent, re-anchored on the first snapshot that disagrees with it
   ([§12](#12-the-client-presentation-layer)).
5. **`Feedback` is never state-bearing.** If a value must be true for gameplay, it
   travels in a `StateSync` snapshot.
6. **Anything the client can trigger is validated server-side** by re-measuring, not
   by trusting a payload.
7. **Comments explain *why*, not *what*.** Every non-obvious decision in this
   codebase carries its reason next to it; that is why the files read the way they do.

---

## 15. Known gaps

Stated plainly, because a document that says "done" without a gap list is not useful.

| Gap | Status | Where the work goes |
|-----|--------|---------------------|
| No client -> server channel, and therefore no rate limiter | **Deliberate, and now visible rather than latent.** Phase 1 has no client-initiated verb: both interactive verbs are server-owned `ProximityPrompt`s, so the client never sends intent. `Remotes.Action`, `RateLimiter.luau` and `Config.Net.MAX_ACTIONS_PER_10_SECONDS` were built for that future verb and then deleted, so nothing in the tree is inert | The first client verb (fishing in Phase 2, a quest hand-in in Phase 3) adds the single audited channel, the token bucket and the per-10-second budget together; the removed implementation is in `git log` |
| Economy values are `[SIM]`, not playtest-validated | Open. The arithmetic in [§9](#9-economy-model) is reproducible; the *income* assumption (~10 pickups/min) is the soft number | Playtest, then edit `Config.Economy` / `Config.Gems` only |
| No behavioural tests | Open. The gate is strictly static: types, syntax, formatting. Nothing simulates a session — demonstrated the hard way: `PlayerDataService` read `acquire`'s session wrapper as if it were the save, which type-checks behind a single `:: any` cast and would have thrown on every join with no character ever spawning. Removing the cast made the analyzer report it instantly, so the real lesson is narrower and more useful: **a cast is exactly where the gate goes blind** | A phase-2 harness needs the engine; keep gameplay decisions in pure functions (`Util`, `GemCatalog.expectedValue`) so more of them are testable offline. Until then, Track A in [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) is the only behavioural check that exists |
| No audio | Deliberate (asset-free) | `EffectFx` is the natural home |
| Desktop-only UI layout | Open — the HUD assumes a landscape desktop viewport | `Theme`'s widget factories are the single choke point for a responsive pass |
| No monetisation, trading or leaderboards | Out of scope for Phase 1 | — |
| `Config.Debug.VERBOSE` gates only two boot prints | Open. `Config.Debug.LOG_SESSION_SUMMARY` (on by default) is the flag that actually matters for a playtest — see [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) | — |
| The toolchain is not in the repository | **Deliberate.** `tools/*` is ignored (~64 MB: four executables, `globalTypes.d.luau`, the release zips and the Rojo Studio plugin), and `.gitattributes` pins LF so a fresh clone still passes step 1 of the gate | `git clone` is not a working gate on its own yet: [`tools/README.md`](../tools/README.md) records the layout and the sources by hand, and a `fetch-tools.ps1` with version pins is the obvious next step |

`docs/PHASE1_DESIGN.md` is the design/balance companion that explains where the
`[SIM]` numbers came from. This document is the code-level counterpart, and it is the
authority on what is implemented.

---

## 16. Running it

Nothing below needs a network connection except the Rojo Studio plugin, and that is
optional.

### The offline path (recommended)

```powershell
.\check.ps1                                                   # gate must pass first
tools\rojo\rojo.exe build default.project.json --output build/CursedGems.rbxlx
```

Open `build/CursedGems.rbxlx` in Studio and press **Play** (F5). No plugin required.

Expected output window (server):

```
[CursedGems] persistence: DataStore handle acquired
[CursedGems] GemSystem online: NN legal positions, target pool 16.
[CursedGems] SummonSystem online: 4 altars.
[CursedGems] CurseSystem online: base drain 7.5/min, 2.5 per creature.
[CursedGems] StateSync online at 4 Hz.
[CursedGems] 0.1.0-phase1 ready in NN ms: NN gem positions, 4 summon altars, 7.5/3.75/1.875 gems per minute base/mercy/shrine.
[CursedGems] Load failed for user NN (Studio access to APIs is not allowed); using memory-only storage for the rest of this server (progress will not persist).
[CursedGems] JOIN Player1 | first ever session | persisted no | gems 15
[CursedGems] SESSION Player1 | 12.4 min | collected 143 (9.5/min P1) | cursed 11 (7.7% P5) | spent 50 (0.35 of collected P6) | summons 3 (P4) | creatures 3 (P2) | cursed 6.1% of session (P3) | gems 88 | persisted no
```

In an unpublished place the first read fails and the store drops to memory-only for the rest
of that server, so `persisted no` and the warning above are the **expected** state rather
than a bug. The `JOIN` line arrives asynchronously when the first player's save resolves, so
it can appear anywhere after the boot lines.

The boot `persistence:` line is *not* the verdict on saving: `GetDataStore` happily hands out
a handle in Studio and only fails on the first read. The per-join `persisted` field is the
authoritative answer, and a `JOIN` line is also the single best proof that character loading
succeeded at all — the process is what [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) formalises.

### The live-sync path

```powershell
tools\rojo\rojo.exe serve default.project.json
```

…then connect the Rojo Studio plugin. This needs the plugin installed (a one-time
download), which is why the `build` path above is the default for this repository.

### Multiplayer check

Use Studio's **Test → Clients and Servers** with 2+ players to exercise the social
paths: `witnessSummon` (everyone within 120 studs of the summoner sees the reveal)
and the shared gem field.

---

## 17. Where to change what

| I want to change… | Edit |
|-------------------|------|
| Gem value, drop odds, pool size, respawn window | `Config.Gems` |
| Drain feel, upkeep curve, mercy rule, grace, shrine safety | `Config.Economy` |
| Summon price, reveal timing, prompt hold, witness radius | `Config.Summon` |
| Curse thresholds and the movement penalty | `Config.Curse` |
| Map size, seed, spawn, shrine, cave, scatter counts, gem zones | `Config.World` |
| Save cadence, lock timeout, store name, memory fallback | `Config.Data` |
| Sync rate and the position slack | `Config.Net` |
| Colours, fonts, corners, widget styling | `Theme.luau` |
| A HUD element, or the presentation of a feedback event | `Hud.luau` |
| The collection grid | `CollectionPanel.luau` |
| A new creature | `CreatureCatalog.luau` (a def only — the collection panel, the followers and the reveals all read the catalogue) |
| A new gem kind | `GemCatalog.luau` (a kind only — spawning, prompts and pickup values follow) |
| World geometry | `WorldBuilder.luau` |
| A new remote or payload | `Remotes.luau`, then `StateSync`/`ClientState` (state) or `Feedback`/`Hud`/`EffectFx` (cosmetic) |
| How a phase is playtested and where results are recorded | `docs/PHASE1_PLAYTEST.md` |
| Whether a tunable is validated or still `[SIM]` | `docs/PHASE1_DESIGN.md` §2 and §7 — the `[SIM]` markers in `Config.luau` come from there |















