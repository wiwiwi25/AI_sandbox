# CursedGems — Phase 1 design

Version `0.1.0-phase1`. This is the **design and balance** companion to
[`PHASE1_ARCHITECTURE.md`](PHASE1_ARCHITECTURE.md): the architecture doc explains how
the code is built, this one explains why the numbers are what they are.

Every value quoted here lives in `src/shared/Config.luau`. Config values tagged
`[SIM]` were derived from the offline model in [§2](#2-the-model) and are **not yet
playtest-validated** — see [§7](#7-what-would-falsify-this).

---

## 1. The pitch

> Gems are your currency and your life. Every creature you capture is a pet you keep
> and a bill you pay forever.

The loop is a closed circuit with one valve:

```
        pick up gems ──────────────► balance ──────────────► summon a creature
             ▲                          │                          │
             │                          ▼                          ▼
             │                    curse drains              upkeep rises
             │                    the balance                permanently
             │                          │                          │
             └──────────────────────────┴──────────────────────────┘
                     you must keep moving to keep living
```

*Standing still and doing nothing is a losing strategy, and the HUD says so.*

### What the player learns, in order

1. **Minute 0** — a number is in the corner and it means something: you start with 15
   gems and the first summon costs 10, so the first purchase is available
   immediately, before the player has understood anything else.
2. **Minute 1** — the number goes *down* on its own. The HUD shows gems/min and an
   estimated time to empty, so this is legible rather than mysterious.
3. **Minute 2** — the first creature appears, and the drain rate visibly rises. The
   connection "pet = cost" is taught by observation, not by a tutorial.
4. **Minute 5** — the player is choosing between "one more creature" and "staying
   solvent". That choice *is* the game.

---

## 2. The model

Two curves, and the whole balance is where they cross.

### Income

| Quantity | Value | Source |
|----------|------:|--------|
| Value of a normal gem | 1 | `Config.Gems.COMMON_VALUE` |
| Value of a cursed gem | 5 | `Config.Gems.CURSED_VALUE` |
| Odds | 92 / 8 | `Config.Gems.COMMON_WEIGHT` / `CURSED_WEIGHT` |
| Expected value per pickup | **1.32** | `GemCatalog.expectedValue()` = `(92*1 + 8*5)/100` |
| Modelled pickups per minute | ~9.5 | derived below |
| Modelled income | **~12.5 gems/min** | 1.32 x 9.5, rounded for legibility |

The figure is derived from the map geometry rather than from a playtest, and it was
re-derived in the Phase 1 tuning pass after the first derivation turned out to be
optimistic by about 35%. The old model read `MIN_GEM_SPACING` (40) as if it were the
realised spacing; sampling the actual placement put the nearest *live* gem about 58
studs away rather than 40, so the theoretical maximum was 15.8 pickups/min instead of
24. That is why the promised `+5/min` at zero creatures was really `-0.4/min`.

The current model walks the four gem zones (`Config.World.GEM_ZONES`: 50-stud discs
108 studs from the shrine, 16 legal points each). With one player the pool is sixteen
gems, so four of the sixteen points in a zone hold one, and a gem sits about 24 studs
from any spot in the zone. That is sampled from the real generator rather than assumed:
the mean distance to the nearest of the four closest gems is 23-25 studs across seeds,
and sampling the placement is what caught the original error above. At 22 studs/s a
pickup costs 24 / 22 + 0.15 s of prompt hold = 1.24 s. Neighbouring zones are 152.7
studs apart, so a four-zone circuit costs 4 x (6.94 + 4 x 1.24) = 47.6 s for the sixteen
live gems: a theoretical 20.2 pickups/min. A real player explores, backtracks and misses
gems, so the model keeps **under half** of that maximum: 0.474 gives 9.5 pickups/min, or
12.5 gems/min.

The 0.474 factor is the one number in this chain that is calibrated rather than
measured: it is set so that a circuit pays the published income, which is what makes the
base drain land on the `+5/min` column. That is a target, not evidence, which is why P1
exists: if the measured factor comes back lower, the factor moves and the base drain
moves with it, in that order.

The playtest pass changed the geometry, not the model. Widening the pockets from 34 to
50 studs and pushing them from 86 to 108 studs out lengthens every travel term; keeping
the pool at twelve would have dropped income to 10.2 gems/min, which forces the base
drain down to 5.2 and stretches the 15-to-0 countdown from two minutes to nearly three.
Adding one gem per pocket costs nothing and holds density - and therefore the felt loop -
where it was. That is why `POOL_BASE` and `POOL_MIN` rose with the radius: a bigger pocket
with the same number of gems in it is a worse pocket, not a more generous one.

### Drain

| Quantity | Value | Source |
|----------|------:|--------|
| Base drain | 7.5/min | `BASE_DECAY_PER_MINUTE` |
| Per creature | 2.5/min | `UPKEEP_PER_CREATURE_PER_MINUTE` |
| Mercy multiplier | 0.5x below 5 gems | `MERCY_THRESHOLD` / `MERCY_MULTIPLIER` |
| Shrine multiplier | 0.25x within 48 studs | `SHRINE_SAFE_RADIUS` / `SHRINE_DECAY_MULTIPLIER` |
| Spawn grace | no drain at all for 60 s | `SPAWN_GRACE_SECONDS` |

```
drain/min = (7.5 + 2.5 x creatures) x mercy x shrine
```

### Where they cross

| Creatures owned | Drain/min | Net/min vs ~12.5 income | What the player is doing |
|----------------:|----------:|------------------------:|--------------------------|
| 0 | 7.5 | **+5** | Banking gems, hunting the jackpot |
| 1 | 10 | +2.5 | Comfortable |
| 2 | 12.5 | **0** | Break-even: this is the designed stable state |
| 3 | 15 | −2.5 | Working for the pets |
| 4 | 17.5 | −5 | Every creature now costs the player |
| 6 | 22.5 | −10 | Deliberate over-commitment; needs shrine + mercy to survive |

Base drain has now moved twice: 10 -> 8 in the Phase 1 pass, then 8 -> 7.5 once
playtesting widened the pockets. Both moves read backwards until the income figure is in
view. The first was repairing an error: with the ring geometry a player at zero creatures
was already losing 0.4 gems/min, and one with a pet was losing about 3. The second is a
clean trade: the pockets got bigger and further apart, so the same circuit pays 12.5
instead of 13.0, and the base follows it down by the same amount. The invariant worth
defending is the column, not the absolute drain: **zero creatures nets +5/min, two
creatures is exactly break-even.**

The curve is **linear on purpose.** A linear upkeep is predictable by inspection:
one look at the drain number tells the player how many creatures they can carry, and
the answer does not change when they are not looking. Exponential upkeep would
punish the exact behaviour the game is about.

And it is deliberately **cheap to reach break-even and expensive to pass it**: 25
gems buys a creature that costs 2.5 gems/min forever — a 10-minute payback at the
margin. That is a decision worth thinking about, and a mistake that is recoverable.

---

## 3. The value system

Phase 1 ships **exactly two gem kinds** and **exactly five creatures**, and that is a
design decision rather than a content shortfall.

### Two gem kinds, one jackpot

| Kind | Value | Odds | Look |
|------|------:|-----:|------|
| Gem | 1 | 92% | Glass, teal, small glow |
| Cursed Gem | 5 | 8% | Neon, purple, big glow, sparkle |

`8%` is about **one cursed gem per 12 pickups**: frequent enough that a new player
discovers the jackpot inside their first session, rare enough that it still reads as
a stroke of luck. A second intermediate kind would not add a decision — it would add
a number. The player can learn this entire value system from two observations, which
is the point: **the value system must be learnable at a glance** so attention can go
to the actual decision, which is upkeep.

The 5x value is not the only payoff: the cursed gem is *visually* different
(material, colour, light range, brightness, sparkle). Colour does the teaching;
the HUD does the accounting.

### Five creatures, three rarities

Rarity is a **sort/label**, not a hidden power tier. Nothing in Phase 1 gives a Rare
creature a gameplay advantage, because the interesting axis is already "another
creature costs another 2.5/min forever". Adding power on top would double-weight the
same decision and make the rare roll mandatory instead of delightful.

### The collection panel is a completion device

Undiscovered species render as **silhouettes**, so the panel always shows the size of
the catalogue without spoiling what is missing. That is the retention hook that does
not cost a single gem: it gives the player a visible "what is left" without ever
threatening their balance.

---

## 4. The difficulty dial

The central design claim of CursedGems:

> The player chooses their own difficulty, and the HUD tells them exactly what it costs.

Every support for that claim is structural:

| Decision | Reason |
|----------|--------|
| **No collection cap** | An arbitrary limit is a rule the player cannot see the reason for. The upkeep curve *is* the cap, and it is legible as a drain rate. |
| **Linear upkeep** | Predictable by inspection: one glance at gems/min tells you how many creatures you can carry. |
| **Drain visible at all times** | A drain you cannot see feels arbitrary. The HUD shows gems/min *and* time-to-empty, because those are the two questions a worried player actually asks. |
| **Over-committing is recoverable** | Mercy (0.5x below 5 gems), the shrine (0.25x), and the fact that grabbing one gem clears the curse mean a player who over-extends gets a second act, not a death sentence. |
| **Only 3 followers visible** (`MAX_VISIBLE_FOLLOWERS`) | The rest live in the collection panel. Eight pets trailing a player is visual noise, and noise hides the drain rate — which is the one thing the player must be able to read. |

Deliberately absent: any way to *pause* the drain, and any way to sell a creature
back. Removing a commitment is exactly the decision the game is built on, so Phase 1
does not offer it — a player who over-commits must out-earn the mistake, which the
mercy rule and the shrine make possible.

---

## 5. Failure design

What losing looks like matters more than what winning looks like, because losing is
the state the player will spend the most time thinking about.

### The curse is a soft failure

| | Normal | Cursed |
|---|---:|---:|
| Walk speed | 22 | **14** |
| Jump power | 50 | **38** |
| Damage over time | none | **none** |

Both speeds were raised in the Phase 1 pass (16/10 to 22/14). The ratio is what the
player actually feels, so it was preserved (0.636 now, 0.625 before): raising normal
speed while leaving cursed speed at 10 would have silently made the curse far harsher.

The penalty is a *cost* (you move slowly, so you cannot farm), not a *timer* (you are
about to die). Timer-death is legible to an adult and reads as unfair to a young
player — the failure arrives from nowhere and cannot be outplayed. Slow feet are
immediately understandable and can always be fixed by grabbing the next gem.

`CLEAR_ABOVE_GEMS = 0` means one gem at 5 value clears the curse outright. Recovery
is a single decision away, at every moment, for every player.

### Four safety nets, each for a specific failure

| Net | Value | The failure it prevents |
|-----|-------|-------------------------|
| Spawn grace | 60 s of zero drain | "I loaded in and was already losing." Also gives the player time to find their first summon. |
| Mercy rule | 0.5x below 5 gems | The death spiral: broke → cannot travel fast → collects less → breaks further. Halving the drain at exactly the moment of crisis is what makes "one more gem" a real opportunity instead of a fantasy. |
| The shrine | 0.25x within 48 studs of the centre | The place you go to stop worrying, think, and meet other players. Making it *safe* rather than *profitable* keeps it from becoming a farm: you recover at the shrine, you earn in the field. |
| Display cap | 9999 gems (`MAX_GEMS`) | A number that stays readable. Gems above the cap are a *display* concern, never a gameplay one. |

### Onboarding

| Step | Value | Why |
|------|-------|-----|
| Starting gems | 15 | Enough to feel real, not enough to skip the loop |
| First (lifetime) summon | 10 | The discounted first purchase is reachable before the player understands the economy — and it *teaches* the economy by being the first thing they spend on |
| The discount is **lifetime**, keyed on `stats.summons` | — | A per-session discount would simply be farmed by rejoining. Lifetime makes it an onboarding gift with a permanent one-time feel. |
| Reveal | 2.2 s | Long enough to be an event, short enough not to stall the field |

---

## 6. Social design

The game is single-player-solvent but multi-player-visible. Nothing in Phase 1 can
transfer value between players, and that is intentional: the moment players can move
gems to each other, the difficulty dial becomes negotiable and the whole balance
model stops meaning anything.

What *is* shared:

| Shared thing | Range | Why it exists |
|--------------|-------|---------------|
| The gem field | four pockets (50-stud discs, 108 studs from the shrine) | Competition for a resource is the cheapest social tension there is, and it costs no extra systems. |
| The shrine | 48-stud safe radius, 0.25x drain | The one place players reliably stand still next to each other. It is the map's social hub *because* it is the map's safe zone, not in spite of it. |
| Summon reveals | 120 studs (`BROADCAST_RADIUS`) | Summoning is the game's achievement moment, and a pen field only reads as a shared one if other players actually notice — so witnesses in range get the same reveal, including the same `creatureId`. |
| The collection panel | per player | Personal, and shown as silhouettes to its owner. |

Design consequence to watch: because drain is personal, a player cannot be dragged
down by a neighbour's over-commitment — and cannot be helped either. That is what
keeps Phase 1's balance model honest, and it is the first thing that would have to be
re-derived if trading were ever added.

---

## 7. What would falsify this

A design is a set of predictions. These are testable from the data the server already
persists (`stats`, `firstJoinAt`, `lastSeen`), so no new instrumentation is needed to run
the test: `Config.Debug.LOG_SESSION_SUMMARY` prints one `JOIN` line per player and one
`SESSION` line per session, and the `SESSION` line is annotated with the prediction each
number answers. The procedure and the recording sheet live in
[`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md).

| # | Prediction | Measure | If it fails |
|---|------------|---------|-------------|
| P1 | ~9.5 pickups/min, i.e. ~12.5 gems/min income | `stats.gemsCollected` / session minutes | Below ~7/min: the income model is wrong. **This is the first number to replace** — every other balance decision rests on it. Fix in `Config.Gems` (value) before touching the drain. |
| P2 | Most sessions end owning 1-3 creatures | creatures per save at `lastSeen` | Clustered at 0-1: upkeep or price is too punishing, or the first purchase is not discoverable. Clustered at 5+: the dial has no bite — raise `UPKEEP_PER_CREATURE_PER_MINUTE`. |
| P3 | Time cursed is a small share of a session | `stats.cursedSeconds` / session length | Above ~30%: the drain is a treadmill rather than a tension. Re-tune mercy, shrine radius, then income — in that order. |
| P4 | Every first session contains a summon | `stats.summons` per save | Many saves at 0 summons: the onboarding money is right but the *path* is not — check that the altar is discoverable from the spawn point. |
| P5 | Cursed gems are ~8% of pickups | `stats.cursedGemsCollected` / `stats.gemsCollected` | Below 8%: players are *avoiding* the jackpot, which is a naming/legibility bug rather than a weighting bug (see open question O1). |
| P6 | Most earned gems get spent | `stats.gemsSpent` / `stats.gemsCollected` | Around 0.5: players hoard, which suggests they do not trust the income — a HUD legibility problem, not a balance problem. |
| P7 | Witnessed summons happen at all | requires 2+ players near a pen | Never: `BROADCAST_RADIUS` is too small, or the pens are placed away from where players actually are. |

---

## 8. Phase 2 candidates

Ordered by how much they would change the design rather than by how easy they are. Long-range sequencing lives in [`ROADMAP.md`](ROADMAP.md); this section is the Phase 1 view of it.

1. **More creatures and more gem kinds** — pure content, no model change. The
   catalogue and the collection panel already scale; the only decision is whether
   more rarity tiers stay decorative.
2. **Creature abilities** — the strongest candidate, because it would give the upkeep
   a *return* instead of only a cost. It also risks double-weighting the same
   decision, so it needs a rule: an ability must change *how you collect*, never *how
   much you keep*.
3. **Trading** — desirable socially, dangerous mechanically: it lets a player shed
   upkeep, which is the exact lever the game is built on. It would require re-deriving
   the whole model.
4. **Collection set bonuses** — fits the existing silhouette panel naturally and
   rewards breadth rather than depth. Same risk as abilities: it must not pay gems.
5. **Daily / re-engagement loop** — `firstJoinAt` and `lastSeen` are already stored,
   so this is cheap to add later.
6. **Mobile layout, audio, cosmetics** — presentation work that does not touch the
   model. Cosmetics are also the only monetisation that cannot sell survival.
7. **Monetisation** — with one hard line: **never sell gems.** Gems are life in this
   game; selling them sells the balance. Cosmetic-only.
8. **A visual pass on the world** — wanted once Phase 1 passes playtest: better gem models
   and VFX, varied tree sizes and silhouettes, underbrush, and denser atmosphere. Today the
   map is deliberately placeholder geometry: every tree is exactly two primitives (one
   `2.2`-wide trunk plus one canopy ball), every rock is a box, the ground is one flat slab
   with no `Terrain` beneath it, and the only VFX in the build is a single `ParticleEmitter`
   on gems. Presentation in the same sense as item 6, with one difference that makes it
   worth its own entry: it is the first work in the tree that would break an actual
   property rather than a convenience. The game is asset-free today — no images, no sounds,
   no uploaded ids ([`PHASE1_ARCHITECTURE.md`](PHASE1_ARCHITECTURE.md), §12) — and a mesh or
   a texture is the first thing that needs an asset id, a moderation pass and a story for
   what the player sees when it fails to load. Decide that trade deliberately, not as a side
   effect of wanting better trees.

---

## 9. Open questions

* **O1 — the naming collision.** The jackpot gem is called *cursed*, and so is the
  failure state. "Cursed" reads as *bad*, so a new player may avoid the 5x pickup
  precisely because it sounds dangerous. If P5 fails, rename the gem (for example
  "Rift Gem") rather than reweighting the table.
* **O2 — the income assumption.** ~10 pickups/min is a model, not a measurement.
  Everything in [§2](#2-the-model) moves if it is wrong.
* **O3 — is one session enough to learn upkeep?** The reveal shows a *nice* thing and
  the drain rises. A player may well attribute the rising drain to something else the
  first time.
* **O4 — is the first summon too cheap to be felt?** At 10 gems the discount teaches
  "this number pays for things"; it may also teach "creatures cost 10", which is wrong
  for the next twenty purchases.
* **O5 — five creatures, three rarities.** Whether a first session produces enough
  variety to make the silhouette panel feel like a goal rather than a chore is
  unknown, and only a playtest will say.
* **O6 — the shrine's radius is a promise.** "Safe" means the drain becomes
  survivable, not that it stops. Whether players read a 4x reduction as safe enough to
  stand still in is a legibility question the HUD has to carry.
* **O7 — the curse rarely threatens a skilled player**, because skilled players are
  never at 0 gems. That is arguably correct (the curse is a floor, not a timer), but it
  does mean the failure state is experienced mainly by new players — exactly the
  audience it is gentlest with.







