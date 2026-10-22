# CursedGems: roadmap

The canonical statement of where this game is going. [`README.md`](../README.md) says what it
is now, the `PHASE1_*.md` documents say how it works and how to prove that it works, and
this file says what comes next and in what order.

Two rules keep it honest:

1. **A version is design-only until its code exists.** Everything below is a proposal
   unless the ladder table marks it shipped. Design-only means no `Config` field, no
   system and no client work: it costs nothing to change and nothing to ignore.
2. **A version that moves income must re-publish the net table.** The Phase 1 economy is
   pinned to one published column (0 creatures = `+5/min`, 2 = break-even, 4+ = losing,
   see [`PHASE1_DESIGN.md` §2](PHASE1_DESIGN.md#2-the-model)). Any future mechanic that
   changes income has to re-derive that column, not quietly invalidate it.

## 1. The ladder

| Version | Theme | Status |
|---------|-------|--------|
| v1-v5 | Not itemised in this repository. The state they produced is `0.1.0-phase1` | Shipped |
| v6 | Reserved | Not yet specified |
| v7 | Reserved | Not yet specified |
| v8 | Reserved | Not yet specified |
| v9 | Treasure Zones and Tiered Gems | **Design only**, see [§5](#5-v9-treasure-zones-and-tiered-gems) |

The shipped baseline v9 has to respect, in one line: walk speed 22, cursed speed 14, four
50-stud gem pockets of 16 legal points each at 13-stud spacing, base drain 7.5/min, and
therefore 0 creatures = `+5/min` off a modelled 12.5 gems/min income. Every number in
[§5](#5-v9-treasure-zones-and-tiered-gems) is checked against those.

## 2. v6 (reserved)

*Empty on purpose: v6 is reserved and has no design yet.*

## 3. v7 (reserved)

*Empty on purpose: v7 is reserved and has no design yet.*

## 4. v8 (reserved)

*Empty on purpose: v8 is reserved and has no design yet.*

## 5. v9: Treasure Zones and Tiered Gems

### 5.1 Premise

Phase 1's four gem pockets are real geography with no identity. They are safe, uniform
and interchangeable, so the map teaches exactly one idea: walk the circuit. v9 gives
each pocket a character by controlling **what it contains**, and inserts one gem tier
between common and cursed so the pockets differ in *variance* and not only in location.

The constraint that makes this cheap: **a full circuit must still average 1.32 gems per
pickup**, the Phase 1 expected value. If it does, `Config.Economy` does not move at all
and the published net table survives untouched. v9 redistributes value geographically
instead of adding value, which is the only kind of economy change that does not force a
re-balance of the drain, the mercy window and the shrine multiplier with it.

### 5.2 The tiers

| Tier | Name | Value | Look | Note |
|------|------|------:|------|------|
| T1 | Common | 1 | the existing green gem | The floor. Never removed. |
| T2 | Cut | 3 | faceted, cyan, larger light radius | New. The tier that makes a pocket worth crossing for. |
| T3 | Cursed | 5 | the existing purple jackpot | Unchanged value; still the 5x moment. |

A tier must be readable at a glance - colour, silhouette and light radius - because the
decision it enables (cross the map for that pocket, or take what is here) has to be made
before arrival. The pick-up prompt stays **identical** for all three tiers: a longer hold
on a better gem would turn a decision into a hesitation, and hides the value it is
rewarding.

### 5.3 The four pockets

| Pocket | Position | Weights T1/T2/T3 | EV per pickup | Character |
|--------|----------|------------------|--------------:|-----------|
| Hearthfield | `(0, 108)`, 64 studs from the spawn | 96 / 4 / 0 | 1.08 | Onboarding. No jackpots, so nothing here can disappoint a new player. |
| The Long Walk | `(0, -108)` | 88 / 12 / 0 | 1.24 | The commute. Reliable, unexciting, always on the way somewhere. |
| The Anvil | `(108, 0)` | 80 / 17 / 3 | 1.46 | Variance. Mostly mid-tier, with jackpots rare enough to be worth telling someone about. |
| Deepwater | `(-108, 0)`, on the cave side | 78 / 19 / 3 | 1.50 | The richest pocket, and the one you commit to: it is the far side from the spawn. |

The mean over an even circuit is `(1.08 + 1.24 + 1.46 + 1.50) / 4 = 1.32`, which is the
Phase 1 number exactly. The weights are **starting values, not playtested ones**: they
exist to prove the arithmetic closes, not because 96 is sacred.


### 5.4 Zone richness (the anti-camping rule)

Phase 1 respawns globally across all 64 legal points, which is what stops a pocket from
feeding its own camper. v9 keeps that rule exactly and adds one number on top: every
pocket carries a **richness** multiplier in `[0.75, 1.25]` that rises while the pocket
is empty and falls as it is harvested (full strength after 90 s untouched, floor after
three quick pickups). It multiplies the payout, not the table.

Why this does not inflate the economy: the multiplier is bounded and symmetric around
1.0, and the circuit the income model already assumes visits all four pockets, so the
multipliers average out over the loop. The same bound is what makes camping lose *by
construction* rather than by tuning:

| Strategy | EV per pickup | Reading |
|----------|--------------:|---------|
| Circuit all four pockets | 1.32 | The Phase 1 number. v9 does not move it. |
| Camp Deepwater at the ceiling | 1.50 x 1.25 = 1.88 | Exists for exactly one pickup: harvesting it is what pulls it down. |
| Camp Deepwater at the floor | 1.50 x 0.75 = 1.13 | 14% worse than travelling, and that is before the wait. |

The wait is the other half. A pool of 16 over 64 points puts roughly four gems in each
pocket, so a camper takes four and then competes for 16 respawns spread across four
pockets - about a quarter of them. A live pool that is deliberately one gem short for
8-12 s after every pick-up makes that wait worse, and v9 inherits it deliberately. The
camper's realised rate is therefore a fraction of what its EV suggests, while the
travelling player keeps converting distance into gems.

Richness is also where the rim pays off: a pocket at high richness can be told apart
from a harvested one by its rim (a slow pulse in the `buildZoneRims` rocks), so the
multiplier is information the player can act on rather than a hidden tax. Nothing in
v9 should ever *reduce* a payout below the Phase 1 value without showing why.

### 5.5 What v9 leaves alone

- `Config.Economy` is untouched: base drain 7.5, upkeep 2.5, mercy, shrine, grace.
- The published net table is untouched, because the circuit EV is unchanged.
- Respawn stays global, not per-pocket. This is the load-bearing decision for R2.
- No new remotes. Tiers are rolled on the server; colour and light radius ride the
  existing state sync.

### 5.6 Implementation shape (design level)

1. **Config.** Each `GEM_ZONES` entry gains `weights = { t1, t2, t3 }`; a new
   `Config.Gems.TIERS` table carries value, colour and light radius per tier, and
   `GemCatalog` stops hard-coding two kinds. New `RICHNESS_*` constants next to it.
2. **WorldBuilder.** `generateGemSpawnPoints` already emits zone by zone, so zone
   membership is `floor((index - 1) / GEM_POINTS_PER_ZONE) + 1`. That arithmetic
   depends on emit order, which is exactly the kind of coupling that rots: return a
   parallel `gemSpawnZones: { number }` from `build()` instead, and let `GemSystem` read
   it. The index arithmetic then becomes an assertion, not a rule.
3. **GemSystem.** The kind roll takes a zone argument; the pooled part is re-coloured
   per tier, so three tiers still cost zero instance churn.
4. **Client.** One extra colour/light-radius pair in the gem renderer and a tier legend
   in the collection panel. No HUD layout change.
5. **PlayerData.** No migration: balances are plain numbers, and a tier only changes
   what a pickup is worth.

### 5.7 Risks

| # | Risk | Why it would bite | Mitigation |
|---|------|-------------------|------------|
| R1 | Income drifts up | The weights are guesses | Circuit EV asserted by the harness before any playtest, tolerance 2% |
| R2 | Camping becomes optimal | Pockets exist to be travelled to | Global respawn plus the richness floor; the harness asserts camping < circuit |
| R3 | A tier is invisible | A cyan gem reads as a green one through haze | Check at 40 studs in Studio; light radius is the primary tell, colour the secondary |
| R4 | The word "cursed" means three things | O1 already flags jackpot vs curse state | Do not rename in v9 at all; if P5 fails, rename the tier rather than the state |
| R5 | Richness reads as a hidden tax | An invisible multiplier is indistinguishable from a bug | It only ever buffs relative to the floor, and the rim shows it |
| R6 | Hearthfield is boring | Safe pocket, no jackpots | Deliberate. It is the tutorial, not the game. |

### 5.8 Acceptance criteria

1. Circuit EV within 2% of 1.32, computed offline from the weights.
2. Camping EV at the floor at least 10% below the circuit EV.
3. P1 in [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) still lands near 12.5 gems/min.
4. Every tier is identifiable at 40 studs in Studio.
5. `Config.Economy` unchanged and no save migration.

### 5.9 Non-goals

Trading, gifting, gem decay, per-pocket respawn clocks, loot tables, and any new remote.
If a v9 feature needs one of those, it is a different version.

### 5.10 Open questions

- **Q1** Is richness linear or stepped? Stepped is easier to see; linear is easier to
  reason about.
- **Q2** Does the rim pulse, or does the tier mix show in the gem count instead? Two
  tells for one fact is noise; pick one.
- **Q3** Should the prompt name the tier after all? The argument above says no, but a
  playtest that shows players ignoring cyan gems would overturn it.
- **Q4** Pocket names are placeholders. Hearthfield, The Long Walk, The Anvil and
  Deepwater are not referenced by any code yet, precisely so they stay free to change.

## 6. Changing this document

A version gets a section only when it is specified. When it ships, its row in [§1](#1-the-ladder)
changes and its section stays as history, because the reasoning is the part that is
expensive to reconstruct. Every number carries its derivation, and any change that moves
income updates the net table in the same commit - rule 2 at the top of this file.

| Date | Change |
|------|--------|
| Phase 1 close | Tuning pass recorded: speed 22/14, four pockets, spacing 13, base drain 8 |
| Playtest 1 | Pockets widened 34 -> 50 studs and pushed 86 -> 108 from the shrine, pool 12 -> 16 to hold density, respawn delay made real by reserving the slot, HUD card moved out of the chat corner, base drain 8 -> 7.5 to keep `+5/min` |
| Playtest 2 | Respawn window 5-8 -> 8-12 s (`RESPAWN_MIN_SECONDS`/`RESPAWN_MAX_SECONDS`), pool and drain deliberately untouched: ~1.6 slots cooling instead of 1.0, so ~14.4 of 16 gems are visible at the tuned 9.5 pickups/min (-3.7% density, inside playtest noise). Shrine and pen tiles raised 0.15 studs clear of the ground and their up-faces separated by 0.10, fixing the coplanar z-fight |
| This document | Created. v6-v8 reserved, v9 specified as design only |

See also: [`PHASE1_DESIGN.md`](PHASE1_DESIGN.md) (balance and reasoning),
[`PHASE1_ARCHITECTURE.md`](PHASE1_ARCHITECTURE.md) (code contracts),
[`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) (how the numbers get replaced by evidence),
[`PROGRESS.md`](PROGRESS.md) (current state and open decisions).

