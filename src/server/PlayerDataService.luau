--!strict
--[[
    CursedGems :: PlayerDataService
    ------------------------------------------------------------------
    Owns the SHAPE of a player save and is the only module allowed to mutate
    it. Every other system asks politely and is told whether it worked.

    Design note - why characters are loaded manually:
    Roblox creates a character as soon as a player joins, which is BEFORE any
    DataStore read can finish. If the character existed during the load, a
    player could grab a gem into a placeholder table that the real save then
    overwrites, silently deleting that gem. So we set
    Players.CharacterAutoLoads = false, load first, and only then call
    LoadCharacter. No gameplay action can race the load, and the fix is one
    line instead of an entire delta-merge system.

    Failure policy: if the load ultimately fails, the player STILL gets a
    character and still plays. Losing one session of progress is much better
    than being locked out of the game, and it is the difference between a bad
    night and a dead game.
]]

local Players = game:GetService("Players")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local DataStoreLite = require(script.Parent.DataStoreLite)

local PlayerDataService = {}

export type CreatureEntry = {
    id: string,
    obtainedAt: number,
    slot: number,
}

-- Lifetime counters. Persisted as-is, and the ONLY numbers the Phase-1 playtest
-- reads: every prediction in docs/PHASE1_DESIGN.md section 7 is a ratio of two
-- of these fields. Do not add a field here without a measurement that needs it.
export type Stats = {
    gemsCollected: number,
    cursedGemsCollected: number,
    gemsSpent: number,
    summons: number,
    cursedSeconds: number,
}

export type SaveData = {
    version: number,
    gems: number,
    creatures: { CreatureEntry },
    stats: Stats,
    firstJoinAt: number,
    lastSeen: number,
}

export type Session = {
    data: SaveData,
    -- Session-only, never persisted: a copy of `stats` as they were at load, so a
    -- session summary can report THIS session rather than a lifetime total.
    -- Lives on the session so it dies with the session and cannot leak across a
    -- rejoin.
    baseline: Stats,
    persistable: boolean,
    loadedAt: number,
    graceUntil: number,
}

local store = DataStoreLite.new()
local sessions: { [Player]: Session } = {}
local started = false

local function emptyStats(): Stats
    return {
        gemsCollected = 0,
        cursedGemsCollected = 0,
        gemsSpent = 0,
        summons = 0,
        cursedSeconds = 0,
    }
end

local function copyStats(stats: Stats): Stats
    return {
        gemsCollected = stats.gemsCollected,
        cursedGemsCollected = stats.cursedGemsCollected,
        gemsSpent = stats.gemsSpent,
        summons = stats.summons,
        cursedSeconds = stats.cursedSeconds,
    }
end

local function defaultData(): SaveData
    local now = os.time()
    return {
        version = 1,
        gems = Config.Economy.STARTING_GEMS,
        creatures = {},
        stats = emptyStats(),
        firstJoinAt = now,
        lastSeen = now,
    }
end

-- LoadCharacter was recently deprecated in favour of LoadCharacterAsync. We look the
-- member up through `any` and keep a fallback branch, so the project still runs on
-- older Studio builds instead of leaving a player permanently without a character.
local function spawnCharacterFor(player: Player)
    local asyncSpawn = (player :: any).LoadCharacterAsync
    if asyncSpawn then
        asyncSpawn(player)
        return
    end

    local legacySpawn = (player :: any).LoadCharacter
    if legacySpawn then
        legacySpawn(player)
    end
end

-- Playtest instrumentation, gated by Config.Debug.LOG_SESSION_SUMMARY so it can
-- be switched off for a release build without touching any logic. `awaySeconds`
-- is nil for a player who has never been seen before.
local function logSessionStart(player: Player, session: Session, awaySeconds: number?)
    if not Config.Debug.LOG_SESSION_SUMMARY then
        return
    end

    local data = session.data
    local persisted = "no"
    if session.persistable then
        persisted = "yes"
    end

    -- "persisted no" in Studio is the EXPECTED state until the place is
    -- published with API access: the load failed, so this session is never
    -- written back. The warn raised during load carries the underlying reason.
    if awaySeconds then
        print(
            string.format(
                "[CursedGems] JOIN %s | returning after %.2fh | persisted %s | gems %d | creatures %d",
                player.Name,
                awaySeconds / 3600,
                persisted,
                data.gems,
                #data.creatures
            )
        )
    else
        print(
            string.format(
                "[CursedGems] JOIN %s | first ever session | persisted %s | gems %d",
                player.Name,
                persisted,
                data.gems
            )
        )
    end
end

function PlayerDataService.load(player: Player): Session
    local existing = sessions[player]
    if existing then
        return existing
    end

    local defaults = defaultData()
    local stored, loadError = store:acquire(player.UserId, defaults)

    local data: SaveData
    local persistable = false

    if stored then
        -- `acquire` returns DataStoreLite's session WRAPPER ({ userId, data, dirty,
        -- acquiredAt, lastSaveAt }); the save itself is `.data`. Reading the wrapper
        -- as if it were the save type-checks only behind a cast, and fails at runtime
        -- on `data.stats` for every single join.
        data = stored.data :: any
        -- Only claim persistence when a write can actually reach the DataStore.
        -- DataStoreLite flips itself to memory-only the first time a load fails, and
        -- stays there for the life of this server, so this is a server-wide fact and
        -- not a per-player guess.
        persistable = not store:isMemoryOnly()
    else
        data = defaults
        warn(
            string.format(
                "[CursedGems] Could not load save for %s (%s). Playing this session unlocked; progress will not persist.",
                player.Name,
                tostring(loadError)
            )
        )
    end

    -- Captured before it is overwritten, so a returning player's summary can
    -- report how long they were away.
    local previousLastSeen = data.lastSeen
    data.lastSeen = os.time()

    local session: Session = {
        data = data,
        baseline = copyStats(data.stats),
        persistable = persistable,
        loadedAt = os.time(),
        -- Grace is intentionally NOT persisted: a fresh spawn always gets the
        -- onboarding window, and farming it would cost the player more time
        -- than the gems it protects.
        graceUntil = os.time() + Config.Economy.SPAWN_GRACE_SECONDS,
    }
    sessions[player] = session

    local character = player.Character
    if player.Parent == Players and (not character or not character.Parent) then
        spawnCharacterFor(player)
    end

    local awaySeconds: number? = nil
    if stored and not stored.fresh then
        awaySeconds = math.max(0, os.time() - previousLastSeen)
    end
    logSessionStart(player, session, awaySeconds)

    return session
end

function PlayerDataService.awaitSession(player: Player, timeout: number?): Session?
    local deadline = os.clock() + (timeout or 10)
    while os.clock() < deadline do
        local session = sessions[player]
        if session then
            return session
        end
        if player.Parent ~= Players then
            return nil
        end
        task.wait(0.1)
    end
    return sessions[player]
end

function PlayerDataService.getSession(player: Player): Session?
    return sessions[player]
end

function PlayerDataService.getData(player: Player): SaveData?
    local session = sessions[player]
    return session and session.data or nil
end

function PlayerDataService.markDirty(player: Player)
    local session = sessions[player]
    if session and session.persistable then
        store:markDirty(player.UserId)
    end
end

function PlayerDataService.getGems(player: Player): number
    local data = PlayerDataService.getData(player)
    if not data then
        return 0
    end
    return data.gems
end

function PlayerDataService.addGems(player: Player, amount: number): number
    local data = PlayerDataService.getData(player)
    if not data or amount == 0 then
        return data and data.gems or 0
    end
    data.gems = math.clamp(data.gems + amount, 0, Config.Economy.MAX_GEMS)
    if amount > 0 then
        data.stats.gemsCollected += amount
    end
    PlayerDataService.markDirty(player)
    return data.gems
end

function PlayerDataService.spendGems(player: Player, amount: number): boolean
    if amount <= 0 then
        return true
    end
    local data = PlayerDataService.getData(player)
    if not data or data.gems < amount then
        return false
    end
    data.gems -= amount
    data.stats.gemsSpent += amount
    PlayerDataService.markDirty(player)
    return true
end

-- Removes gems for upkeep. Kept in the data service so that the currency
-- never changes outside this module.
function PlayerDataService.applyDrain(player: Player, amount: number): number
    local data = PlayerDataService.getData(player)
    if not data or amount <= 0 then
        return data and data.gems or 0
    end
    -- Deliberately FRACTIONAL and floored at zero. Rounding to whole gems on
    -- every tick would turn an 8/min drain into a 60/min drain, and gems must
    -- never go negative or the mercy rule would read as a debt.
    local nextGems = math.max(0, data.gems - amount)
    if nextGems ~= data.gems then
        data.gems = nextGems
        PlayerDataService.markDirty(player)
    end
    return data.gems
end

-- The single place that turns a picked-up gem into a balance change. Gem kinds
-- are identified by id so that this module never needs to know the gem catalog.
function PlayerDataService.recordPickup(player: Player, value: number, isCursed: boolean): number
    local data = PlayerDataService.getData(player)
    if not data or value <= 0 then
        return data and data.gems or 0
    end
    data.gems = math.clamp(data.gems + value, 0, Config.Economy.MAX_GEMS)
    data.stats.gemsCollected += value
    if isCursed then
        data.stats.cursedGemsCollected += 1
    end
    PlayerDataService.markDirty(player)
    return data.gems
end

function PlayerDataService.getCreatures(player: Player): { CreatureEntry }
    local data = PlayerDataService.getData(player)
    if not data then
        return {}
    end
    return data.creatures
end

function PlayerDataService.creatureCount(player: Player): number
    return #PlayerDataService.getCreatures(player)
end

function PlayerDataService.addCreature(player: Player, creatureId: string): CreatureEntry?
    local data = PlayerDataService.getData(player)
    if not data then
        return nil
    end
    local entry: CreatureEntry = {
        id = creatureId,
        obtainedAt = os.time(),
        slot = #data.creatures + 1,
    }
    table.insert(data.creatures, entry)
    data.stats.summons += 1
    PlayerDataService.markDirty(player)
    return entry
end

function PlayerDataService.lifetimeSummons(player: Player): number
    local data = PlayerDataService.getData(player)
    if not data then
        return 0
    end
    return data.stats.summons
end

-- The very first summon a player ever performs is discounted, so that every new
-- player finishes their first session owning a visible creature.
function PlayerDataService.getSummonCost(player: Player): number
    if PlayerDataService.lifetimeSummons(player) <= 0 then
        return Config.Summon.FIRST_SUMMON_COST
    end
    return Config.Summon.COST
end

-- Single source of truth for the drain rate. Every creature a player owns eats
-- gems forever, which is what turns collecting into a chosen difficulty.
function PlayerDataService.getUpkeepPerMinute(player: Player): number
    return Config.Economy.BASE_DECAY_PER_MINUTE
        + Config.Economy.UPKEEP_PER_CREATURE_PER_MINUTE
            * PlayerDataService.creatureCount(player)
end

function PlayerDataService.getGraceRemaining(player: Player): number
    local session = sessions[player]
    if not session then
        return 0
    end
    return math.max(0, session.graceUntil - os.time())
end

function PlayerDataService.addCursedSeconds(player: Player, seconds: number)
    local data = PlayerDataService.getData(player)
    if data and seconds > 0 then
        data.stats.cursedSeconds += seconds
    end
end

function PlayerDataService.getStoreStats()
    return store:getStats()
end

function PlayerDataService.isMemoryOnly(): boolean
    return store:isMemoryOnly()
end

-- One line per session, shaped for the recording sheet in
-- docs/PHASE1_PLAYTEST.md: every prediction in PHASE1_DESIGN.md section 7 (P1-P7)
-- can be read straight off it. Ratios are guarded so that a player who joins and
-- immediately leaves prints a line instead of erroring.
local function logSessionSummary(player: Player)
    if not Config.Debug.LOG_SESSION_SUMMARY then
        return
    end

    local session = sessions[player]
    if not session then
        return
    end

    local data = session.data
    local stats = data.stats
    local baseline = session.baseline
    local minutes = math.max(0, (os.time() - session.loadedAt) / 60)

    local collected = stats.gemsCollected - baseline.gemsCollected
    local cursedGems = stats.cursedGemsCollected - baseline.cursedGemsCollected
    local spent = stats.gemsSpent - baseline.gemsSpent
    local summons = stats.summons - baseline.summons
    local cursedSeconds = math.max(0, stats.cursedSeconds - baseline.cursedSeconds)

    local perMinute = 0
    local cursedShare = 0
    if minutes > 0 then
        perMinute = collected / minutes
        cursedShare = cursedSeconds / (minutes * 60)
    end

    local cursedRate = 0
    local spendRatio = 0
    if collected > 0 then
        cursedRate = cursedGems / collected
        spendRatio = spent / collected
    end

    local persisted = "no"
    if session.persistable then
        persisted = "yes"
    end

    print(
        string.format(
            "[CursedGems] SESSION %s | %.1f min | collected %d (%.1f/min P1) | cursed %d (%.1f%% P5) | spent %d (%.2f of collected P6) | summons %d (P4) | creatures %d (P2) | cursed %.1f%% of session (P3) | gems %d | persisted %s",
            player.Name,
            minutes,
            collected,
            perMinute,
            cursedGems,
            cursedRate * 100,
            spent,
            spendRatio,
            summons,
            #data.creatures,
            cursedShare * 100,
            data.gems,
            persisted
        )
    )
end

function PlayerDataService.start()
    if started then
        return
    end
    started = true

    -- Must happen before any player can join, so that no character exists while
    -- a save is still loading. See the design note at the top of this file.
    Players.CharacterAutoLoads = false

    Players.PlayerAdded:Connect(function(player: Player)
        PlayerDataService.load(player)
    end)

    Players.PlayerRemoving:Connect(function(player: Player)
        -- Logged before the session is cleared and before the final save, so the
        -- summary describes the state the player actually left with.
        logSessionSummary(player)
        sessions[player] = nil
        store:release(player.UserId, true)
    end)

    -- Handles players already present, which happens in Studio solo play because
    -- the local player can join before server scripts finish starting.
    for _, player in ipairs(Players:GetPlayers()) do
        task.spawn(function()
            PlayerDataService.load(player)
        end)
    end

    store:startAutosave()

    if Config.Debug.LOG_SESSION_SUMMARY then
        local mode = "DataStore handle acquired"
        if store:isMemoryOnly() then
            mode = "MEMORY ONLY - this server will not persist anything"
        end
        -- Not the definitive answer: an unpublished Studio place hands out a
        -- handle happily and only fails on the first read, so the per-join
        -- line ("persisted yes/no") is the one to trust.
        print(string.format("[CursedGems] persistence: %s", mode))
    end

    game:BindToClose(function()
        store:flushAll()
    end)
end

return PlayerDataService
