--!strict
--[[
    CursedGems :: ClientState (client)
    ------------------------------------------------------------------
    The client-side mirror of server truth. Exactly one table, written in
    exactly one place, read by every view - so no two panels can disagree about
    what the player's balance is.

    Two entry points, one destination:
      * the PUSHED snapshot (RemoteEvent, 4 Hz) carries the constant churn;
      * the PULLED snapshot (RemoteFunction) carries the collection, and exists
        for clients that joined mid-session or suspect they missed an update.

    Both land in apply(), so a push and a pull cannot produce different state.
    The pull is retried because a brand-new client can legitimately ask BEFORE
    the server has finished loading its data; the server answers nil in that
    window rather than a half-built snapshot.

    Every field is type-checked on arrival. The server is trusted, but one
    malformed field must not take the whole client down with it - and a numeric
    field arriving as nil is by far the most likely shape of that accident.
]]

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local Util = Shared.Util
local Remotes = Shared.Remotes

local ClientState = {}

export type CollectionEntry = {
    slot: number,
    id: string,
    obtainedAt: number,
}

export type Snapshot = {
    gems: number,
    drainPerMinute: number,
    grace: number,
    creatureCount: number,
    cursed: boolean,
    summonCost: number,
    collection: { CollectionEntry }?,
}

local PULL_RETRY_SECONDS = 1
local MAX_PULL_ATTEMPTS = 15

-- How long the countdown may keep projecting past the last snapshot. The stream
-- runs at 4 Hz, so anything beyond a second and a half means the stream has
-- stopped, and a readout that keeps counting down for a disconnected player is
-- a lie with a deadline attached.
local MAX_EXTRAPOLATION_SECONDS = 1.5

-- CurseSystem bills once a second (its TICK_SECONDS) while snapshots arrive at
-- 4 Hz, so three of every four snapshots restate a balance nobody has touched
-- since the last one. A snapshot within this much drain of the projection is
-- that lagging tick rather than news, and re-anchoring on it is what makes a
-- countdown tick backwards. A real event - one gem, at any reachable rate - is
-- always larger than the tolerance.
local BILLING_SECONDS = 1
local ANCHOR_TOLERANCE_TICKS = 1.25

local state: Snapshot = {
    gems = Config.Economy.STARTING_GEMS,
    drainPerMinute = 0,
    grace = 0,
    creatureCount = 0,
    cursed = false,
    summonCost = Config.Summon.COST,
    collection = nil,
}

local loaded = false

-- The anchor the projected countdown reads from: the balance at a known moment
-- and the rate in force since. A snapshot is a place to project from, not only
-- a value to draw.
local anchor = {
    gems = state.gems,
    drain = 0,
    clock = os.clock(),
}

-- When the last snapshot arrived, whatever it said. Deliberately separate from
-- anchor.clock: a snapshot that only restates a lagging balance must not reset
-- the anchor, but it does prove the stream is still alive.
local lastSyncClock = anchor.clock

-- BindableEvent rather than a hand-rolled signal: this is one of the few
-- genuinely cross-cutting notifications in the client, and the built-in comes
-- with a Deferred thread and no ordering surprises.
local changed = Instance.new("BindableEvent")

local function apply(snapshot: any)
    if type(snapshot) ~= "table" then
        warn("[CursedGems] ClientState received a non-table snapshot.")
        return
    end

    if Util.isFiniteNumber(snapshot.gems) then
        -- NOT floored. The server bills fractionally (applyDrain subtracts
        -- rate/60 per second), so the fraction is the difference between a
        -- countdown that slides and one that jumps a whole gem at a time.
        -- Views that must show a whole number floor it themselves, and
        -- Util.abbreviate already does exactly that.
        state.gems = math.max(0, snapshot.gems)
    end
    if Util.isFiniteNumber(snapshot.drainPerMinute) then
        state.drainPerMinute = math.max(0, snapshot.drainPerMinute)
    end
    if Util.isFiniteNumber(snapshot.grace) then
        state.grace = math.max(0, snapshot.grace)
    end
    if Util.isFiniteNumber(snapshot.creatureCount) then
        state.creatureCount = math.max(0, math.floor(snapshot.creatureCount))
    end
    if Util.isFiniteNumber(snapshot.summonCost) then
        state.summonCost = math.max(0, math.floor(snapshot.summonCost))
    end
    if type(snapshot.cursed) == "boolean" then
        state.cursed = snapshot.cursed
    end

    -- Only overwritten when present. The collection is sent on CHANGE, not on
    -- every tick, so an absent field means "unchanged", never "emptied".
    if type(snapshot.collection) == "table" then
        local entries: { CollectionEntry } = {}
        for _, raw in ipairs(snapshot.collection) do
            if
                type(raw) == "table"
                and type(raw.id) == "string"
                and Util.isFiniteNumber(raw.slot)
            then
                table.insert(entries, {
                    slot = math.floor(raw.slot),
                    id = raw.id,
                    obtainedAt = Util.isFiniteNumber(raw.obtainedAt) and raw.obtainedAt or 0,
                })
            end
        end
        -- Sorted once here, rather than in every view that displays it.
        table.sort(entries, function(a: CollectionEntry, b: CollectionEntry): boolean
            return a.slot < b.slot
        end)
        state.collection = entries
    end

    -- Anchoring, in the one function every snapshot passes through, so a push
    -- and a pull cannot anchor at different moments.
    local now = os.clock()
    local drain = state.drainPerMinute

    if state.grace > 0 or drain <= 0 then
        -- Nothing is being billed - the shield is up, or there is no rate at all
        -- - so a projection would invent a drain that is not happening.
        anchor.gems = state.gems
        anchor.drain = drain
        anchor.clock = now
    else
        local age = math.max(0, now - anchor.clock)
        local projected = anchor.gems - anchor.drain / 60 * age
        local tolerance = math.max(anchor.drain, drain)
            / 60
            * BILLING_SECONDS
            * ANCHOR_TOLERANCE_TICKS

        -- Only two things are worth moving the anchor for: a balance the
        -- projection cannot explain (a pickup, a summon's price, a bill the
        -- client slept through) and a change of rate. Everything else is the
        -- billing tick restating itself, and re-anchoring on that is exactly
        -- what makes a countdown tick backwards. On a rate change the label is
        -- about to jump anyway, so the phase is resynced at the same moment
        -- rather than lagging a second behind the new rate.
        if drain ~= anchor.drain or math.abs(state.gems - projected) > tolerance then
            anchor.gems = state.gems
            anchor.clock = now
        end

        anchor.drain = drain
    end

    lastSyncClock = now

    loaded = true
    changed:Fire(state)
end

function ClientState.get(): Snapshot
    return state
end

-- Seconds until the balance reaches zero, projected along the rate the server
-- last reported. Returns nil when nothing is draining.
--
-- This is an interpolation, not a second economy: the client never recomputes
-- the rate, so mercy, the shrine multiplier and upkeep all arrive as rate
-- changes in the ordinary snapshot. What it recovers is the fraction of a gem
-- the snapped balance throws away, which is the difference between a countdown
-- that slides and one that holds still for 60/rate seconds and then lurches -
-- eight of them at the base drain.
function ClientState.remainingSeconds(): number?
    if anchor.drain <= 0 then
        return nil
    end

    -- The projection stops a second and a half after the last snapshot: a dead
    -- stream must freeze the readout, not walk a disconnected player to zero.
    local clock = math.min(os.clock(), lastSyncClock + MAX_EXTRAPOLATION_SECONDS)
    local age = math.max(0, clock - anchor.clock)
    local gems = math.max(0, anchor.gems - anchor.drain / 60 * age)
    return gems / anchor.drain * 60
end

function ClientState.isLoaded(): boolean
    return loaded
end

function ClientState.onChanged(callback: (Snapshot) -> ()): RBXScriptConnection
    return changed.Event:Connect(callback)
end

function ClientState.start()
    Remotes.StateSync.OnClientEvent:Connect(apply)

    -- The stream alone is not enough at join time: the first pushed snapshot can
    -- arrive before this script is listening. Ask for a full one, and keep
    -- asking while the server reports it has nothing authoritative yet - which
    -- is precisely what it does while the player's data is loading.
    task.spawn(function()
        for attempt = 1, MAX_PULL_ATTEMPTS do
            local ok, snapshot = pcall(function()
                return Remotes.RequestState:InvokeServer()
            end)
            if ok and type(snapshot) == "table" then
                apply(snapshot)
                return
            end
            if Config.Debug.VERBOSE then
                print(
                    string.format("[CursedGems] State pull attempt %d returned nothing.", attempt)
                )
            end
            task.wait(PULL_RETRY_SECONDS)
        end
        warn("[CursedGems] Gave up pulling initial state; the pushed stream should still catch up.")
    end)
end

return ClientState
