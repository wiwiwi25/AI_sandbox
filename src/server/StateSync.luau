--!strict
--[[
    CursedGems :: StateSync
    ------------------------------------------------------------------
    The one place server truth becomes client-visible.

    Two shapes of update, deliberately different sizes:
      * the SUMMARY - balance, drain rate, grace, curse state, summon price -
        goes out every tick, because it changes constantly and it is tiny;
      * the COLLECTION goes out only when its signature changes, because it
        changes a handful of times per session and its payload grows with the
        collection. Sending it four times a second would mean a payload that
        grows with playtime in exchange for no new information.

    Only ids, slots and timestamps travel. Names, rarities and colours live in
    the shared CreatureCatalog, which the client already loads in order to
    build the reveal animation; shipping them as well would create a second
    source of truth for the same string.

    RequestState covers the moments the stream is not enough: a client that has
    just joined, or one that suspects it missed something. It answers from the
    same builder as the stream, so the two can never disagree.

    The drain rate is read from CurseSystem rather than recomputed here. A HUD
    that displays a different number from the one being charged would be worse
    than no HUD at all.
]]

local Players = game:GetService("Players")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local Remotes = Shared.Remotes
local PlayerDataService = require(script.Parent.PlayerDataService)
local CurseSystem = require(script.Parent.CurseSystem)

local StateSync = {}

local INTERVAL = 1 / Config.Net.STATE_SYNC_HZ

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

local lastSignature: { [Player]: string } = {}
local running = false

local function collectionSignature(player: Player): string
    local ids: { string } = {}
    for _, record in ipairs(PlayerDataService.getCreatures(player)) do
        table.insert(ids, record.id)
    end
    return table.concat(ids, "|")
end

local function collectionEntries(player: Player): { CollectionEntry }
    local entries: { CollectionEntry } = {}
    for _, record in ipairs(PlayerDataService.getCreatures(player)) do
        table.insert(entries, {
            slot = record.slot,
            id = record.id,
            obtainedAt = record.obtainedAt,
        })
    end
    return entries
end

local function buildSnapshot(player: Player, includeCollection: boolean): Snapshot
    local collection: { CollectionEntry }? = nil
    if includeCollection then
        collection = collectionEntries(player)
    end

    return {
        gems = PlayerDataService.getGems(player),
        drainPerMinute = CurseSystem.currentRatePerMinute(player),
        grace = PlayerDataService.getGraceRemaining(player),
        creatureCount = PlayerDataService.creatureCount(player),
        cursed = CurseSystem.isCursed(player),
        summonCost = PlayerDataService.getSummonCost(player),
        collection = collection,
    }
end

local function step()
    for _, player in ipairs(Players:GetPlayers()) do
        if not PlayerDataService.getSession(player) then
            continue
        end

        local signature = collectionSignature(player)
        local includeCollection = lastSignature[player] ~= signature
        if includeCollection then
            lastSignature[player] = signature
        end

        Remotes.StateSync:FireClient(player, buildSnapshot(player, includeCollection))
    end
end

function StateSync.start()
    if running then
        return
    end
    running = true

    Remotes.RequestState.OnServerInvoke = function(player: Player): Snapshot?
        -- nil means "no authoritative data yet". Never answer from a session
        -- that is still loading: the client's job is to ask again, not to
        -- apply half a snapshot.
        if not PlayerDataService.getSession(player) then
            return nil
        end
        -- Keep the stream in step, so the next tick does not immediately
        -- resend the collection we just handed over.
        lastSignature[player] = collectionSignature(player)
        return buildSnapshot(player, true)
    end

    Players.PlayerRemoving:Connect(function(player: Player)
        lastSignature[player] = nil
    end)

    task.spawn(function()
        while running do
            task.wait(INTERVAL)
            step()
        end
    end)

    print(string.format("[CursedGems] StateSync online at %d Hz.", Config.Net.STATE_SYNC_HZ))
end

function StateSync.stop()
    running = false
end

return StateSync
