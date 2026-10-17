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
        state.gems = math.max(0, math.floor(snapshot.gems))
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

    loaded = true
    changed:Fire(state)
end

function ClientState.get(): Snapshot
    return state
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
