# CursedGems — Phase 1 playtest kit

Version `0.1.0-phase1` (`Config.VERSION`). This is the **procedure** companion to
[`PHASE1_ARCHITECTURE.md`](PHASE1_ARCHITECTURE.md) (how it is built) and
[`PHASE1_DESIGN.md`](PHASE1_DESIGN.md) (why the numbers are what they are).

It exists because the gate cannot answer the only question that matters next. `.\check.ps1`
proves 26 files parse, typecheck and are formatted; `rojo build` proves the place assembles.
Neither simulates a session. Phase 1 is finished when a human being who has never seen this
game finds it fun without being taught, and this document is how that gets measured instead
of remembered.

---

## 1. The gate between Phase 1 and Phase 2

Phase 1 may not be declared done by inspection. The advance criteria:

| # | Criterion | Source | Fails if |
|---|-----------|--------|----------|
| G1 | The build runs: every player gets a character, the HUD paints, gems can be picked up | §4 checklist | Any traceback in Output, or a player with no character |
| G2 | An outsider reaches a first pickup with no instruction | §5 | They ask what to do first |
| G3 | An outsider performs a summon in their first session unprompted | §5 | They never find or never try the altar |
| G4 | That outsider says they would play again, unprompted | §5, question 5 | They would not, or they cannot say what the goal was |
| G5 | `P1` income lands near the modelled figure | §6, §8 | `P1` is far off — see the fix order in §8 |
| G6 | Every value still marked `[SIM]` has either been validated or explicitly re-marked | [`PHASE1_DESIGN.md` §7](PHASE1_DESIGN.md#7-what-would-falsify-this) | A number ships on an assumption nobody wrote down |

G2 and G3 are the real gate. G5 is the one that changes the game.

---

## 2. Two tracks, in this order

| Track | Who | Where | Cost | Answers |
|-------|-----|-------|------|---------|
| **A — technical smoke test** | you | local, unpublished Studio, `F5` | ~10 min | "does it behave as designed at all?" |
| **B — outsider session** | 1–3 people who have never seen it | published place, private/1 server | ~20–30 min each | G2, G3, G4 and P1–P7 |

Track A is not optional and not disposable: it is the cheap filter that stops a broken build
from wasting an outsider's first impression. Run it after **every** change to gameplay code.
An outsider session is worth one shot per tester — a crash halfway through destroys the whole
run, and they cannot un-see a bug.

---

## 3. Preconditions

```powershell
.\check.ps1                       # must print: gate: PASS
tools\rojo\rojo.exe build default.project.json --output build/CursedGems.rbxlx
```

Then open `build/CursedGems.rbxlx` in Studio and press **Play** (F5). The viewport starts
**empty** — the map has no static content and is built at runtime by `WorldBuilder`. That is
expected; see [`PHASE1_ARCHITECTURE.md` §16](PHASE1_ARCHITECTURE.md#16-running-it).

Confirm `Config.Debug.LOG_SESSION_SUMMARY = true` (`src/shared/Config.luau`). It is on by
default and it is what produces the two log lines this whole document reads from.

For **Track B only**, the place must be published with **Studio Access to APIs** enabled, or
nothing persists between sessions and every retention measure is meaningless — the `JOIN` line
will say `persisted no` and `first ever session` forever. See §7.

## 4. Track A — technical smoke test

Seventeen checks, ~10 minutes, one player, unpublished Studio. Work down the table; a failure
means stop and fix before touching anything else. Expected text is quoted exactly where the
code produces a fixed string, so "looks about right" is not an available answer.

| # | Do this | Expect | If it fails, look at |
|---|---------|--------|----------------------|
| A1 | Read the Output window at boot | `persistence:`, `GemSystem online: NN legal positions, target pool 16.`, `SummonSystem online: 4 altars.`, `CurseSystem online: base drain 7.5/min, 2.5 per creature.`, `StateSync online at 4 Hz.`, then `0.1.0-phase1 ready in NN ms: NN gem positions, 4 summon altars, 7.5/3.75/1.875 gems per minute base/mercy/shrine.` | `Main.server.luau`, then whichever system is silent |
| A2 | Look for the `JOIN` line | `[CursedGems] JOIN <name> \| first ever session \| persisted no \| gems 15` | **Stop.** A traceback instead of a `JOIN` line means character loading threw — see the note below the table |
| A3 | Watch the character spawn | Character lands on ground at the spawn point, facing the shrine. No fall-through, no void | `Config.World.PLAYER_SPAWN`, `WorldBuilder.luau` |
| A4 | Read the HUD | The `GEM RESERVE` card sits in the **top-right, clear of the chat window**, with `COLLECTION` directly above it; it shows `15`; drain line reads `no drain`; countdown reads about `2m 00s` and is falling | `Hud.luau`, `StateSync.luau` |
| A5 | Wait out the 60-second grace without picking anything up | Balance stays at **15**. First loss happens after the grace window ends | `Config.Economy.SPAWN_GRACE_SECONDS`, `CurseSystem.luau` |
| A6 | Walk to a gem and hold the prompt | Balance rises by **1** (by **5** for a cursed gem); the gem disappears, the prompt vanishes, and **nothing replaces it for 5–8 s** — the field is briefly one gem short, then a gem appears somewhere in one of the four zones. Watch one empty spot twice: it must stay empty for the whole delay (the index is reserved), not refill instantly | `GemSystem.luau`, `Config.Gems` |
| A7 | Walk to an altar and hold the prompt | Prompt reads `Summoning Altar  -  10 gems` on the **first ever** summon (then `25`); hold is visibly longer than a pickup (0.35 s vs 0.15 s); a 2.2 s reveal plays; a creature then trails behind you | `SummonSystem.luau`, `Config.Summon` |
| A8 | Open the collection panel | Header reads `N of 5 discovered`; the summoned species renders as a real model with its name and rarity colour; the rest are dark silhouettes labelled `???` | `CollectionPanel.luau` |
| A9 | Check the drain with one creature | Drain line reads `-10.0 gems / min` (7.5 base + 2.5 upkeep). Countdown is now shorter than it was | `PlayerDataService.getUpkeepPerMinute`, `Config.Economy` |
| A10 | Let the balance fall to 25, then 10, then 0 | Banners `Gem reserves low: N left`, then `CRITICAL: N gems left`; at zero: `CURSED` label plus a `Cursed - collect a gem to lift it` toast, walk speed 22 → **14**, jump 50 → **38**. **No damage, ever.** The next gem picked up prints `Curse lifted` and restores movement | `CurseSystem.luau`, `Config.Curse` |
| A11 | With one creature, drop below 5 gems | Drain halves (`10` → `5`): the mercy window, not a bug | `Config.Economy.MERCY_THRESHOLD` |
| A12 | Stand within 48 studs of the shrine | Drain reads `-1.9 gems / min` with no creatures (0.25× the base), and `no drain` if the grace is still running | `Config.Economy.SHRINE_SAFE_RADIUS`, `CurseSystem.luau` |
| A13 | Confirm persistence behaviour in Studio | `Load failed for user NN (...); using memory-only storage for the rest of this server (progress will not persist).` and `persisted no`. **This is expected**, not a bug | `DataStoreLite.luau`, `Config.Data.ALLOW_MEMORY_FALLBACK` |
| A14 | Count gems on the field | Between **16** and **44** visible (`POOL_MIN`/`POOL_MAX`); they thin out as players join or leave | `GemSystem.targetPoolSize`, `Config.Gems` |
| A15 | Stop the session | `SESSION <name> \| NN.N min \| collected N (N.N/min P1) \| ... \| persisted no` — every P-mapping present with a number after it | `PlayerDataService.logSessionSummary` |
| A16 | **Test → Clients and Servers**, 2 players | Two `JOIN` lines. One player summons while the other stands within 120 studs: both see the reveal. Picking a gem by one does **not** change the other's balance | `SummonSystem` (`BROADCAST_RADIUS`), `Config.Economy` |
| A17 | Press `/` and send a chat message | The line appears when you press Enter, and `Chat` in the Explorer carries no orange warning badge. Silence here means `ChatVersion` is not `TextChatService` in the built place — rebuild after touching the project file | `default.project.json` (`ChatVersion`), [§5 of the architecture document](PHASE1_ARCHITECTURE.md#5-repository-layout) |
| A18 | Count gems per pocket | With one player, roughly four gems sit inside each of the four pockets (50-stud discs, 108 studs from the shrine on the axes). Empty a pocket completely: the respawns land elsewhere on the map rather than refilling that pocket, which is the anti-camping rule working as designed | `Config.World.GEM_ZONES`, `GemSystem.luau` |

**Why A2 is the important one.** A2 is not a formality: `CharacterAutoLoads` is `false` by
design, so *any* exception inside `PlayerDataService.load` means the player never receives a
character and sits in an empty world. That failure mode cannot be caught by the gate — a
mismatch between two modules' interfaces type-checks behind a single `:: any` cast and then
throws on the first join. One of exactly that kind was found and fixed while writing this
document; A2 is the check that proves the fix, and the reason Track A runs before Track B.

**A17 is the same failure class one level up.** Nothing in `src/` decides whether chat
works: `ChatVersion` is a property Studio reads from the project file, so the gate is blind
to it for the same reason it was blind to the `CharacterAutoLoads` mistake. Both are why §5
of the architecture document spends a paragraph on Rojo writing the API dump's defaults
into services the project only *declares*.

## 5. Track B — the outsider session

This is the only track that can pass or fail G2, G3 and G4, and it is invalidated by
help. The single most common way to waste it is to explain the game first.

### Who

- **One at a time** for the first session. 2–3 testers total across the phase.
- At least one who plays Roblox regularly and one who does not, if available.
- **Not** anyone who has watched you build it, read these docs, or already heard the pitch.
- Do not join them as a second player in the first session: another player's presence teaches
  the drain, the altar and the shrine for you. Run the **duo variant** (below) separately, as
  its own session, when you want P7.

### The script — say this and nothing else

> "This is a game I'm building. Play it for about fifteen minutes. I'm going to tell you
> nothing about it on purpose — that's the test. Afterwards I'll ask you five questions."

Then stay quiet and take notes. If they ask **"what do I do?"**, answer only *"whatever you
want to find out"*, and **write the timestamp down**: asking inside the first 30 seconds is a
G2 failure, and the fix is the HUD's legibility, never a tutorial.

Do **not** say: that gems are your health, that anything drains, that upkeep rises with
creatures, that the shrine is safe, that the altar spends gems, that the first summon is cheap,
or that the glowing gem is worth five. Every one of those is something the game is supposed to
teach by itself — and `O1` in [`PHASE1_DESIGN.md` §9](PHASE1_DESIGN.md#9-open-questions) exists
precisely because "cursed" may teach it wrong.

### What to record while they play

Timestamped and concrete. Impressionistic notes are worthless here; "looked confused" cannot
be acted on, "asked what to do at 0:40" can.

| Watch for | Why it matters |
|-----------|----------------|
| Time to first movement | The 30-second clarity claim |
| Time to first **pickup** | Whether the loop is discoverable without instruction |
| Time to first **altar attempt**, and whether it was deliberate or accidental | G3 |
| First time they look at the balance / drain / countdown text | Whether the HUD is read at all |
| First time they notice the drain rising after a summon | `O3` — is the causal link visible? |
| First time cursed, and their reaction | Is the floor read as fair or as punishment? |
| Any gem they visibly avoided | `P5` / `O1` — avoidance is a legibility bug, not a weighting bug |
| When they stop, and what they say at that moment | The real fun signal |
| Every question they ask, **verbatim** | The gap list for the next tuning pass |

### The five questions afterwards, in this order

1. What was the game asking you to do?
2. What happened to your gems over the course of the session?
3. Before you used the altar, what did you think it would do?
4. What were you trying to get?
5. Would you play again — and if so, what would you do differently next time?

Keep the wording exactly as above. Question 2 must not contain the word "drain" and question 3
must not contain "creature": both are fishing for whether the player *built* the model
themselves. A tester who cannot answer 1 or 4 unprompted means the loop did not communicate,
whatever the numbers say.

### Duo variant (for P7 only)

Two testers who know each other, ~5 minutes, you observe silently. P7 asks only whether
*witnessed summons happen at all*, so record three specific things:

- Did a summon by one player get a visible reaction from the other (within 120 studs)?
- Did they compete over gems at all, or split the field cleanly?
- Did they end up near the shrine together without being told it was safe?

## 6. Reading the numbers

### Where they come from

Both lines are produced by `PlayerDataService` when `Config.Debug.LOG_SESSION_SUMMARY` is on:

- `JOIN ...` — once per player, as soon as their save resolves (async, so it can appear
  anywhere after the boot lines).
- `SESSION ...` — once per player, when they leave, printed **before** the final save and
  before the session is cleared, so it describes the state the player actually left with.

They print to the **server** Output window. Which server you can see depends on how you run it:

| Configuration | Persistence | Can you see the log? | Use it for |
|---------------|-------------|----------------------|------------|
| Unpublished Studio, `Play` (F5) | none (memory-only) | yes | Track A, and P1/P3/P4/P5/P6 |
| **Published place with Studio Access to APIs, Studio `Play` or Clients-and-Servers** | **real DataStore** | yes | **everything, including P2 and save integrity** |
| Live server on the Roblox site | real DataStore | no — the log is remote | nothing in this kit |

The middle row is the configuration this kit is designed around: it is the only one that gives
you real persistence *and* a log window in front of you.

### The `SESSION` line, field by field

```
SESSION <name> | NN.N min | collected N (N.N/min P1) | cursed N (N.N% P5) | spent N (N.NN of collected P6) | summons N (P4) | creatures N (P2) | cursed N.N% of session (P3) | gems N | persisted yes|no
```

| Field | Meaning | Prediction |
|-------|---------|------------|
| `NN.N min` | Session length, from load to leave | — |
| `collected N (N.N/min P1)` | Gems gained **this session** (value, so a cursed gem counts 5) | `P1` ≈ 11/min |
| `cursed N (N.N% P5)` | Cursed gems picked **this session**, as a share of gems collected | `P5` ≈ 8% |
| `spent N (N.NN of collected P6)` | Gems spent this session ÷ gems earned this session | `P6` — most earned gems get spent |
| `summons N (P4)` | Summons this session | `P4` — every first session contains one |
| `creatures N (P2)` | Collection size when they left | `P2` — most sessions end owning 1–3 |
| `cursed N.N% of session (P3)` | Seconds spent cursed ÷ session length | `P3` — well under 30% |
| `gems N` | Final balance | — |
| `persisted yes\|no` | Whether this session's numbers will survive | — |

Every figure is a **delta** measured against `Session.baseline`, captured at load — so one line
describes one session, not a lifetime. Without that baseline, an hour-long session would look
identical to a two-minute one.

`P7` is the only prediction not on this line, because "did anyone witness it" is not a number
the server records. It comes from the duo variant in §5 — or from the summoner's own `summons`
count combined with whether the other player reacted.

### The `JOIN` line, field by field

```
JOIN <name> | first ever session           | persisted no | gems 15
JOIN <name> | returning after NN.NNh       | persisted yes | gems 88 | creatures 3
```

`returning after` is the re-engagement signal, and it is only ever non-trivial on a place that
actually persists. `persisted` is the authoritative answer to "is this run real?", and `gems` on
the returning line is the single fastest confirmation that a save round-tripped.

### What Studio cannot tell you, and why

In an unpublished place, `stats` live in memory only, so:

- **Every session reports `first ever session`.** The `JOIN` line is telling the truth about the
  save, not about the player.
- **The first-session summon discount re-applies after every restart**, because it is keyed on
  `stats.summons` and that counter just went back to zero. Do not read this as a discount bug;
  in a persisted session it correctly happens once ever.
- **Retention and return behaviour are unmeasurable.** Any conclusion about whether players come
  back requires the middle row of the table above. Say so in the results rather than inferring it.

The gameplay measures — `P1`, `P3`, `P4`, `P5`, `P6`, and the collection size for `P2` — are all
session-local deltas, so they are perfectly valid from an unpublished Studio run. Only the
*persistence* claims (`persisted yes`, `returning after`, save integrity in §7) need a published
place.

## 7. Save integrity — published place only

None of this has ever run. The lock, the retry ladder and the autosave were written before the
place was published, and every Studio run falls back to memory before reaching them, so **S1–S5
are the first time that code meets the real service.** Run them before inviting an outsider into a
published place: a session that silently loses progress is worse than a session that never
started.

Setup: publish the place, enable **Studio Access to APIs**, then run it from Studio so you keep
the Output window (see §6).

| # | Do this | Expect |
|---|---------|--------|
| S1 | Join, collect ~10 gems, leave with the **Leave** button, rejoin | `JOIN ... returning after 0.00h \| persisted yes`, and the balance is exactly what you left with |
| S2 | Summon once, then leave and rejoin | The creature is still in the panel and still following; the altar now reads `25` gems, because the first-summon discount is **lifetime** and `stats.summons` persisted |
| S3 | Two players in one server, both collect and summon, leave in either order | Two `persisted yes` lines. **No** `Lock lost for user N; refusing to overwrite another server.` and no `Save failed for user N` |
| S4 | Hard-**Stop** the server, then restart within 60 s and rejoin | Expect a burst of `locked by another server` retries (3 attempts, waiting 1.5 s, 3 s, 4.5 s), then `using memory-only storage for the rest of this server` and `persisted no`. Then wait out `LOCK_TIMEOUT_SECONDS` (60 s) and rejoin: you are in normally. **This is the stale-lock safety net working** — an unclean shutdown is exactly the case it exists for |
| S5 | Play for longer than 90 s while picking up gems | No network write per pickup (`AUTOSAVE_SECONDS = 90` batches them). If a save does fail, the player keeps playing: `saveWithRetry` retries up to `MAX_SAVE_RETRIES` and the next autosave tries again. A save failure must **never** kick or block anyone |

What "good" looks like: zero `Save failed for user`, zero `Lock lost for user` in S1–S3, and one
`persisted yes` per session. If a `Lock lost` appears while only one server is running, stop —
that is the failure that silently destroys progress, and it is not something to test with
strangers.

## 8. Recording sheet, verdict rules, and the tuning loop

### The sheet

One row per session. Paste the `SESSION` line verbatim into the last column: it already contains
`P1`–`P6`, so the columns to the left exist to make rows comparable at a glance.

| Tester | Date | Solo/duo | persisted | min | collected | /min (P1) | cursed % (P5) | spent ratio (P6) | summons (P4) | creatures (P2) | cursed % session (P3) | P7 | G2 / G3 / G4 | SESSION line (verbatim) |
|--------|------|----------|-----------|-----|-----------|-----------|---------------|------------------|--------------|----------------|-----------------------|----|--------------|-------------------------|
|  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |

Keep a free-text section under the table for the verbatim questions and the timestamped
observations from §5. The questions are the part that survives into Phase 2 design; the numbers
only tell you whether the model held.

### Verdict bands

| Prediction | Pass band | If it fails, change — in this order |
|------------|-----------|-------------------------------------|
| `P1` income | ≈ 12.5 gems/min (≈9.5 pickups/min) | **Income first** (`Config.Gems.COMMON_VALUE` / `CURSED_VALUE`), never the drain. `P1` is the load-bearing number: every other balance decision is derived from it (`O2`) |
| `P2` collection | 1–3 creatures at leave | 0–1: `Config.Summon.COST` / `FIRST_SUMMON_COST`, then altar discoverability from the spawn. 5+: raise `UPKEEP_PER_CREATURE_PER_MINUTE` |
| `P3` curse share | well under 30% | `MERCY_*`, then `SHRINE_SAFE_RADIUS` / `SHRINE_DECAY_MULTIPLIER`, then income — that exact order is in [`PHASE1_DESIGN.md` §7](PHASE1_DESIGN.md#7-what-would-falsify-this) |
| `P4` first summon | ≥ 1 in the first session | Altar discoverability from the spawn point, **not** the price — the onboarding money is already right |
| `P5` cursed share | ≈ 8% | **Rename the gem before reweighting it** (`O1`). Avoidance is a naming bug: weighted odds cannot fix a pickup players choose not to take |
| `P6` spend ratio | most earned gems get spent | The HUD, not the economy. A ratio near 0.5 means players do not trust the income, which is legibility |
| `P7` witnesses | witnessed summons happen | `Config.Summon.BROADCAST_RADIUS`, then where the pens actually are relative to where players stand |

### Rules for the tuning loop

1. **One lever per run.** Change two and you cannot attribute the result; the next session
   becomes a coin flip instead of evidence.
2. **Income before drain.** If `P1` is off, every drain conclusion drawn on top of it is fiction.
3. **Legibility before numbers.** `P5`, `P6` and any "I avoided that" note are solved in the HUD or
   the naming, not in `Config`.
4. **Re-run Track A after every change.** It costs ten minutes and it is the only cheap protection
   against ship-a-breakage.
5. **Validate in `Config.luau` when a number earns it.** The `[SIM]` tag means "from the offline
   simulation, not playtest-validated". When a session confirms a value, delete the tag and record
   the evidence next to it, e.g. `-- [PLAYTEST: 11.5/min across 3 sessions, 2026-10-17]`. A `[SIM]`
   that has been tested is a lie by omission.

---

## 9. What this kit does not test

Stated so nobody reads a green run as more than it is.

- **Multi-day retention.** Needs live traffic and days of it, not a session. `firstJoinAt` and
  `lastSeen` are already stored for when that data exists.
- **Monetisation.** There is nothing to test: Phase 1 ships none, and per the project's ethics rule
  it should be cosmetic/convenience/content when it arrives — never gems, because gems are life.
- **Mobile and controller layout.** The HUD assumes a landscape desktop viewport; this is a known
  gap in [`PHASE1_ARCHITECTURE.md` §15](PHASE1_ARCHITECTURE.md#15-known-gaps), not something a
  desktop playtest can detect.
- **Audio.** None exists yet (`EffectFx` is the natural home).
- **Trading, gifting and invite-a-friend loops.** Out of scope for Phase 1 by design: transferring
  gems would let a player shed upkeep, which is the exact lever the game is built on.
- **Load beyond a handful of players.** The pool scales to `POOL_MAX` (32) and follower visuals cap
  at 3 each, but nothing here measures a 20-player server. Only 2 players are exercised, in A16
  and S3.
- **Anything in Phase 2 and beyond.** By the phase rule: fishing, the Admin, leveling, hunting,
  businesses and slice-of-life systems are not built, and must not be until this phase passes.

When `G1`–`G6` in §1 are settled with evidence, Phase 1 is done and Phase 2 (fishing) can be
designed. Until then the only edits that belong in the tree are `Config` values, HUD legibility,
and bug fixes — with Track A re-run after each one.





