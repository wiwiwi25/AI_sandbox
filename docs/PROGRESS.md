# CursedGems — progress and handoff

A working note, not a design document. It exists so a fresh session can pick up without
re-reading twelve files: what changed last, what the numbers are, what was decided and
why, and what is still open. The authoritative documents are
[`PHASE1_ARCHITECTURE.md`](PHASE1_ARCHITECTURE.md),
[`PHASE1_DESIGN.md`](PHASE1_DESIGN.md), [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) and
[`ROADMAP.md`](ROADMAP.md); where this file and those disagree, they win.

**Last updated:** 2026-10-22, after commit `1544ff4`.

---

## 1. Where the tree stands

`.\check.ps1` passes (stylua clean, 26 files compile, luau-lsp 0 diagnostics), both
offline probes (respawn, countdown) pass with zero failed checks, and `rojo build`
produces `build/CursedGems.rbxlx` (about 211 KB). Nothing is half-finished: every
commit below is self-contained, gate-green and probe-green.

| Commit | Change |
|--------|--------|
| `860cab5` | Respawn window 5-8 s → **8-12 s** (`RESPAWN_MIN_SECONDS`/`RESPAWN_MAX_SECONDS`), docs synced |
| `500cdaf` | Shrine and pen tiles lifted clear of the ground: the z-fight is gone |
| `84f7f81` | HUD countdown projected from the live clock instead of redrawn from a floored balance (§3) |
| `1544ff4` | A respawn places its gem on another point in another pocket, never the spot just collected (§4) |

Phase 1 status is unchanged in the only sense that matters to the roadmap: **code-complete,
playtest 2 not yet run by a human.** No roadmap row moved.

---

## 2. Respawn window: 5-8 s → 8-12 s

`Config.Gems.RESPAWN_MIN_SECONDS = 8`, `RESPAWN_MAX_SECONDS = 12`. `GemSystem` is the
only reader and needed no change; the probe harness reads both bounds from Config, so it
retuned itself.

**Why no pool or decay re-tune.** A reservation of length `L` at a pickup rate `λ` leaves
`λ·L` slots cooling at steady state. Phase 1 tuning puts a solo player at 9.5 pickups/min
(`λ = 0.158/s`), so the window moves from about 1.0 cooling slots to about 1.6:

| | 5-8 s | 8-12 s |
|---|---|---|
| mean reservation | 6.5 s | 10.0 s |
| slots cooling at 9.5 picks/min | ~1.0 | ~1.6 |
| live gems of 16 | ~15.0 | **~14.4** |
| density | reference | −3.7% |
| income, 1p / 4p | reference | −1% / −4% |
| break-even creatures | 2.0 | ~1.8 |

The income deltas sit inside the ±10% band one playtest cannot resolve, so the field
absorbs the change instead of the drain. Retuning the pool upward to "restore" density
would have made the map pay *more* per pickup (the widened-pocket effect documented in
`PHASE1_ARCHITECTURE.md` §4), i.e. it would have bought visibility with inflation.

**Evidence** (offline probe, shipped modules, driven every 0.05 s):

```
cursed:  n=16  min=8.10s  mean=10.14s  max=12.00s  under-8s=0
common:  n=16  min=8.05s  mean= 9.73s  max=11.95s  under-8s=0
traffic Common: n=73  min=8.10s  mean= 9.87s  max=12.05s  under-8s=0
traffic Cursed: n= 7  min=8.10s  mean=10.31s  max=12.05s  under-8s=0
Traffic: 80 pickups, 0 unresolved, final active 24
Total failed checks: 0
```

`max` landing at 12.00 s rather than above it is correct: the drawn delay is clamped to the
ceiling and the part appears on the next scheduler tick, so the ceiling is inclusive.

The sample split above is from that change's run. Re-running the probe after §4 gives
slightly different n per kind (74 / 6 rather than 73 / 7) because the destination is no
longer the collected point, so the pairing of fires changes — the bounds are identical.

---

## 3. The run-dry countdown: a frozen label, not a slow drain

The HUD's "runs dry in Xm Ys" held still and then jumped — the report was 1m 44s
straight to 1m 16s. No drain arithmetic moved: the label was being redrawn from a
number the client had quantised.

**Cause.** `ClientState` stored `math.floor(snapshot.gems)`, and `Hud` recomputed
`gems / drainPerMinute * 60` only when a snapshot arrived (4 Hz). The server bills
fractionally — `PlayerDataService.applyDrain` subtracts `rate/60 * delta` once a
second — so the client threw the fraction away and the label could only move when a
whole gem left the balance: a stride of `60/drain` seconds, **8.0 s at the 7.5/min
base**, 4.8 s with one creature, 12 s with none. It stood still for a stride, then
lurched by one. A summon made it worse by changing the denominator under the same
gems (13 gems read 1m 44s at 7.5/min and 1m 18s at 10/min).

**Fix, client-side only** (`ClientState.luau`, `Hud.luau`):

- the mirror keeps the fraction; `Util.abbreviate` already floors, so the counter
  text is unchanged (asserted in the probe, not assumed);
- `ClientState.remainingSeconds()` projects `balance - rate/60 * age` from an anchor,
  at the rate the server sent — the client still never computes a rate of its own;
- `Hud` repaints `countdown` from `RunService.Heartbeat`, and only when the rendered
  string changes, so it is about one property write per second rather than sixty;
- the anchor moves only on a balance event, a rate change, or a snapshot more than
  1.25 billing ticks away from the projection. Three of every four snapshots are the
  1 Hz billing tick restating itself, and re-anchoring on those made the label tick
  *backwards* in the first draft of this fix — the probe caught it, which is the
  reason the probe exists;
- a dead stream freezes the projection 1.5 s after the last snapshot instead of
  counting a disconnected player down to zero.

**Evidence** (offline probe, real `Config`, 1 Hz billing / 4 Hz snapshots / 60 Hz
frames, label read back from its own text; a "lurch" is a repaint over 1 s that no
snapshot explains):

| Scenario | Before | After |
|---|---|---|
| steady, 7.5/min, 55 s | 8.0 s strides, 7 lurches | 1.0 s steps, 0 lurches, 0 backward ticks |
| same, drained to empty | 16 s strides once mercy halves the rate, 12 lurches | 1.0 s steps; the mercy change still shows (+39 s) |
| 2 creatures, 12.5/min | 4-5 s strides, 7 lurches | 1.0 s steps, 0 lurches |
| first summon at t=20 | 80 s jump | 78 s jump, nothing invented |
| shrine entered at t=25 | 32 s freeze, then +208 s | 1 s steps, one +240 s at the entry |
| snapshots stop at t=15 | frozen (nothing repaints) | frozen after 1.5 s, never reaches 0 |

`Total failed checks: 0`. The text is still per-second by design (`formatDuration`
floors), so the readout changes once a second; what is gone is the eight-second hold
and the eight-second lurch. The probe certifies the arithmetic and the stride, not the
modules — `Hud`/`ClientState` build Roblox instances at require time, so the gate is
what certifies them.

**Committed as `84f7f81`** ("fix(hud): project the run-dry countdown every frame instead of on
each snapshot"), together with this section and the two doc updates.

---

## 4. Gem respawn: the replacement no longer lands under the cursor

A pick-up removed a gem and the next gem appeared in the same place 8-12 s later. The delay
was working; the *destination* was the bug. `processPendingRespawns` called
`spawnAt(entry.index)` — the queue remembered the collected point and put the gem back onto
it — and that has been true since the first commit (`git log -S 'spawnAt(entry.index)'` →
`df56a1c`). `PHASE1_ARCHITECTURE.md` and playtest check A18 already described the opposite
("respawns at a freshly randomised point", "the respawns land elsewhere on the map"), so this
is the code catching up to its own spec, not a new rule.

**Fix, server-side only** (`GemSystem.luau`; no config, world, client or remote change):

- `PendingRespawn` now records `spot` — where the gem *was* — instead of a destination. The
  destination is chosen when the reservation ends, because only then is the set of free
  points meaningful;
- pocket membership is derived once in `start()` from the same `Config.World.GEM_ZONES` the
  legal points were generated from: containment, not nearest-centre, so a point outside
  every pocket simply has no pocket to exclude. 64 points against 4 discs, once, at boot;
- `respawnCandidates(spot)` builds three tiers and the first non-empty tier wins:
  1. free, not the spot, **another pocket** — the rule;
  2. free, not the spot, same pocket — when no other pocket has a free point;
  3. the spot itself — when the field has no other point at all.

  One `pickFromCandidates` then applies the existing 25-stud player-distance preference, so
  the deficit path and the respawn path cannot drift apart;
- the collected point stays `cooling` until its replacement has been *placed*, which stops a
  deficit sweep from re-using the spot mid-cooldown (the other half of the old behaviour);
- `getStats()` gained `pendingSpots` (a copy of the queue's sources). It is a debug/test
  surface in the same spirit as `forceReconcile`: without it, a refill cannot be attributed
  to the reservation that was waiting for it, because the destination is no longer the
  collected point.

**Why relax instead of wait.** An entry that waited for a legal destination would break the
8-12 s ceiling; an entry that was dropped would make `reconcile()` refill the same spot with
*no* delay. Both are worse than a documented fallback, so the tiers relax in order and a gem
is never lost.

**Reachability.** With the shipped layout (4 pockets x 16 = 64 points, `POOL_MAX` 44) at
least 20 points are free and at most 16 of them fit in one pocket, so **at least four free
points are always outside the collected pocket: tier 1 cannot fail.** Tiers 2 and 3 are dead
code at these numbers and live code on a smaller map, which is why the probe builds two tiny
worlds to force them. Fewer players lowers the *pool*, not the number of legal points, so the
one-player case is the easiest one for this rule.

**Economy and timing unchanged.** `deficit` still subtracts `#pendingRespawn`, and the delay
is still drawn at pick-up, so the number of gems on the map and the 8-12 s window are exactly
what §2 measured. The only second-order effect is spatial: a pocket that one player keeps
emptying stops refilling itself until a pick-up happens somewhere else, which is the
anti-camping rule in `ROADMAP.md` R2 doing what it says.

**Evidence** (offline probe, shipped modules, driven every 0.05 s):

```
cursed:  n=16  min=8.25s  mean=10.06s  max=12.00s  under-8s=0
common:  n=16  min=8.65s  mean=10.81s  max=11.95s  under-8s=0
traffic Common: n=74  min=8.05s  mean= 9.97s  max=12.05s  under-8s=0
traffic Cursed: n= 6  min=10.55s  mean=11.19s  max=12.05s  under-8s=0
Traffic pairing: 74 fire(s) paired source -> destination, 6 ambiguous [2->2 x3]
Traffic: 80 pickups, 0 unresolved, final active 24
Respawn destinations: elsewhere=136 same-pocket=3 same-spot=3
Total failed checks: 0
```

Every paired refill landed on a different point in a different pocket; `same-pocket=3` and
`same-spot=3` are three refills in each of the two tiny worlds (17 points in one pocket:
tier 1 empty, so the spot moved and the pocket could not; 16 points with a target of 16: no
free point at all, so the field took the spot back on time instead of starving). The six
unpaired fires are three ticks in which two reservations expired inside the same 50 ms — their
*timing* is still exact because it comes from the queue, only the source → destination pairing
is not asserted. The probe certifies the module's arithmetic and its placement; `build/` is not
part of the gate.

**Studio-check list** (the gate before commit):

1. Collect a gem and keep your camera on the spot: nothing reappears there for at least 8 s,
   and when the field refills, the gem is somewhere in one of the other three pockets.
2. Walk a circuit and watch the far pocket: gems keep arriving there while the pocket you are
   working drains — that is the exclusion, not a spawn bug.
3. Stand still in one pocket and farm it: its supply thins out and replacements appear in the
   other pockets. Move once and the emptied pocket starts refilling on the next few pick-ups.
4. Watch one spot twice in a row (A6 in the playtest sheet): the 8-12 s reservation still
   behaves as it did in §2.

**Committed as `1544ff4`** ("fix(gems): respawn on a different point outside the collected
gem's pocket") with the four doc updates. The checks above are the ones that shipped; the
Studio items stay on the list until playtest 2 is run for real (§7).

---

## 5. Altar z-fight: it was never the grass

The diagnosis is worth keeping because the obvious hypothesis was wrong. `Shrine/Pad`
(opaque marble, 52 studs across) and `Shrine/PadRing` (translucent neon, 58 studs across)
both had their **top face at exactly y = 0.60**, overlapping over about 2,120 stud². Two
surfaces at identical depth fight for the same pixels, and because the ring is translucent
the shimmer moved with the camera. Nothing else on the altar was coplanar.

| Part | Before | After | Top face now |
|------|--------|-------|--------------|
| `Shrine/Pad` | `GROUND_Y + 0.30` | `GROUND_Y + 0.45` | 0.75 (was 0.60) |
| `Shrine/PadRing` | `GROUND_Y + 0.35` | `GROUND_Y + 0.40` | 0.65 (was 0.60) |
| `Pens/Pen1-4Pad` | `GROUND_Y + 0.25` | `GROUND_Y + 0.40` | 0.65 (was 0.50) |

Both shrine discs now clear the grass by 0.15, and their up-faces are 0.10 apart with the
neon ring *below* the marble lip, so no coplanar pair is left anywhere on the map.
`GROUND_Y` is 0, so the numbers above are absolute.

Pedestals, prompts, gem heights and every marker are untouched. That is safe because all
gameplay distance in `src/` goes through `Util.distanceXZ` (which ignores Y) and there are
no raycasts in the tree — the change is purely visual.

---

## 6. Open decisions and unresolved observations

1. **The shrine fix has not been seen in Studio.** The geometry is verified (three new Y
   expressions present in the built place, `GROUND_Y = 0`, no coplanar pair remaining by
   arithmetic), but "no shimmer" is a human judgement. It is the first thing to look at in
   the next session.
2. **The traffic live-count does not match the analytic model, and it was not chased.**
   The probe reported `mean 17.57 of 24` gems visible (73%) at a synthetic 1 pickup/s with
   3 players. The analytic steady state for that rate is ~14 of 24 (58%); the *real*
   1-player case this change was tuned on is ~14.4 of 16 (90%). The harness drives
   `forceReconcile` every 0.05 s while the shipped scheduler resolves one tick per 0.5 s,
   so the surplus is probably batching — but that is a hypothesis, not a measurement. The
   probe certifies the delay bounds and the `active + pending == target` invariant; it does
   not certify density. Do not quote 73% as a density figure.
3. **Version string.** `Config.VERSION` is still `0.1.0-phase1` after two behaviour changes.
   Decide whether playtest-2 fixes bump the patch number or whether Phase 1 keeps one label
   until it is signed off.
4. **Cursed-gem share.** The traffic sample is roughly 91/9 common/cursed, matching the
   shipped 92/8 roll; the six cursed samples are consistent with the common ones but are
   too few to say anything about the cursed tail.

---

## 7. Next steps, in order

1. Playtest 2 in Studio: run [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) start to finish. A6
   now reads 8-12 s and its replacement must land in another pocket; watch one empty spot twice
   to confirm the index stays reserved *and* that nothing comes back to it. Add the altar
   shimmer check while standing on the pad and orbiting.
2. If a shimmer is still visible in Studio it is *not* the pad/ring pair, which is now
   provably separated — look at `Beacon`, the pedestals and the prop scatter before
   touching the pads again.
3. Record the results in the playtest sheet, then move the ROADMAP §1 row that playtest 2
   unblocks. Nothing else in the tree is waiting on this session.

---

## 8. How to re-verify without Studio

```powershell
.\check.ps1                                                      # stylua + sourcemap + compile + analyze
powershell -ExecutionPolicy Bypass -File build\_run_probe.ps1     # respawn probe, offline
powershell -ExecutionPolicy Bypass -File build\_run_countdown_probe.ps1   # countdown probe, offline
& 'tools\rojo\rojo.exe' build default.project.json -o build\CursedGems.rbxlx
```

`rojo` is not on PATH — always call `tools\rojo\rojo.exe`. The probe injects the real
`src/` modules into `build\_cursed_respawn_run.luau` on every run, so it cannot test a stale
copy. It asserts both halves of the respawn contract — the delay bounds and the destination
(not the collected spot, not its pocket) — and ends by driving two tiny worlds that force the
tier-2 and tier-3 fallbacks, which the 64-point map cannot reach. The countdown probe works
the same way but injects only `Config` and `Util`: the two derivations it compares are
transcribed from `Hud`/`ClientState`, which build Roblox instances at require time and cannot
load offline. It certifies the arithmetic and the
stride; the gate certifies the modules. `build/` is gitignored scratch space;
`sourcemap.json` is committed and regenerated by `check.ps1`.

## 9. Working rules (as agreed)

- One change per commit, committed only once it is tested and green. Never commit
  unfinished work.
- Any commit that moves income updates the net table in the same commit (`ROADMAP.md`
  rule 2).
- At roughly 120k tokens of context, stop, write this file, commit it, and start a fresh
  session.
