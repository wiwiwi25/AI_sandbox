# CursedGems — progress and handoff

A working note, not a design document. It exists so a fresh session can pick up without
re-reading twelve files: what changed last, what the numbers are, what was decided and
why, and what is still open. The authoritative documents are
[`PHASE1_ARCHITECTURE.md`](PHASE1_ARCHITECTURE.md),
[`PHASE1_DESIGN.md`](PHASE1_DESIGN.md), [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) and
[`ROADMAP.md`](ROADMAP.md); where this file and those disagree, they win.

**Last updated:** 2026-10-22, after commit `500cdaf` plus the uncommitted countdown fix in §3.

---

## 1. Where the tree stands

`.\check.ps1` passes (stylua clean, 26 files compile, luau-lsp 0 diagnostics), both
offline probes (respawn, countdown) pass with zero failed checks, and `rojo build`
produces `build/CursedGems.rbxlx` (about 205 KB). Nothing is half-finished: every
commit below is self-contained, and the one change on top of them (§3, the countdown)
is finished and probe-verified, waiting only for a Studio look before it is committed.

| Commit | Change |
|--------|--------|
| `860cab5` | Respawn window 5-8 s → **8-12 s** (`RESPAWN_MIN_SECONDS`/`RESPAWN_MAX_SECONDS`), docs synced |
| `500cdaf` | Shrine and pen tiles lifted clear of the ground: the z-fight is gone |

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

**Uncommitted at the time of writing.** The gate and the probe are green; it is left
for one commit together with this section, once the label has been seen in Studio.

---

## 4. Altar z-fight: it was never the grass

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

## 5. Open decisions and unresolved observations

1. **The shrine fix has not been seen in Studio.** The geometry is verified (three new Y
   expressions present in the built place, `GROUND_Y = 0`, no coplanar pair remaining by
   arithmetic), but "no shimmer" is a human judgement. It is the first thing to look at in
   the next session.
2. **The traffic live-count does not match the analytic model, and it was not chased.**
   The probe reported `mean 17.62 of 24` gems visible (73%) at a synthetic 1 pickup/s with
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
   shipped 92/8 roll; the seven cursed samples are consistent with the common ones but are
   too few to say anything about the cursed tail.

---

## 6. Next steps, in order

1. Playtest 2 in Studio: run [`PHASE1_PLAYTEST.md`](PHASE1_PLAYTEST.md) start to finish. A6
   now reads 8-12 s instead of 5-8 s; watch one empty spot twice to confirm the index really
   stays reserved. Add the altar shimmer check while standing on the pad and orbiting.
2. If a shimmer is still visible in Studio it is *not* the pad/ring pair, which is now
   provably separated — look at `Beacon`, the pedestals and the prop scatter before
   touching the pads again.
3. Record the results in the playtest sheet, then move the ROADMAP §1 row that playtest 2
   unblocks. Nothing else in the tree is waiting on this session.

---

## 7. How to re-verify without Studio

```powershell
.\check.ps1                                                      # stylua + sourcemap + compile + analyze
powershell -ExecutionPolicy Bypass -File build\_run_probe.ps1     # respawn probe, offline
powershell -ExecutionPolicy Bypass -File build\_run_countdown_probe.ps1   # countdown probe, offline
& 'tools\rojo\rojo.exe' build default.project.json -o build\CursedGems.rbxlx
```

`rojo` is not on PATH — always call `tools\rojo\rojo.exe`. The probe injects the real
`src/` modules into `build\_cursed_respawn_run.luau` on every run, so it cannot test a stale
copy. The countdown probe works the same way but injects only `Config` and `Util`: the two
derivations it compares are transcribed from `Hud`/`ClientState`, which build Roblox
instances at require time and cannot load offline. It certifies the arithmetic and the
stride; the gate certifies the modules. `build/` is gitignored scratch space;
`sourcemap.json` is committed and regenerated by `check.ps1`.

## 8. Working rules (as agreed)

- One change per commit, committed only once it is tested and green. Never commit
  unfinished work.
- Any commit that moves income updates the net table in the same commit (`ROADMAP.md`
  rule 2).
- At roughly 120k tokens of context, stop, write this file, commit it, and start a fresh
  session.
