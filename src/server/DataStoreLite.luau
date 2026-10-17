--!strict
--[[
    CursedGems :: DataStoreLite
    ------------------------------------------------------------------
    A small, defensive persistence layer. Deliberately not a framework.

    What it guarantees:

      * One server owns a player key at a time. The lock is taken atomically
        inside UpdateAsync, with a stale-lock timeout so a crashed server cannot
        permanently hold a save. Two servers writing the same key is the number
        one way Roblox games silently destroy player progress.
      * Saves are BATCHED on a timer, never per change. Picking up a gem does
        not touch the network.
      * A save failure NEVER kicks or blocks the player. We log, retry with
        backoff, and try again on the next autosave.
      * Studio places with API access disabled fall back to an in-memory store,
        so the game stays playable before it is ever published.

    What it deliberately does NOT do: cross-server messaging, per-key budget
    management, or migration tooling. Phase 1 does not need them.

    Schema growth is handled by merging defaults into whatever was loaded, so
    adding a field in a later phase cannot break an existing save. Defaults are
    deep copied per player, because sharing one default sub-table across every
    player in the server is a classic and very hard to spot data bug.
]]

local DataStoreService = game:GetService("DataStoreService")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config

local DataStoreLite = {}
DataStoreLite.__index = DataStoreLite

export type Session = {
    userId: number,
    data: { [string]: any },
    dirty: boolean,
    -- True when the key held no save at all before this acquire. This is the only
    -- honest way to tell a never-played-before player from a returning one: the
    -- defaults cannot say it, because a brand-new save's timestamps ARE `now`.
    fresh: boolean,
    acquiredAt: number,
    lastSaveAt: number,
}

export type DataStoreLite = typeof(setmetatable(
    {} :: {
        _serverId: string,
        _store: any,
        _memoryOnly: boolean,
        _memory: { [number]: { [string]: any } },
        _sessions: { [number]: Session },
        _autosaveThread: thread?,
        _running: boolean,
        _stats: { loads: number, saves: number, failures: number, locksLost: number },
    },
    DataStoreLite
))

local function newServerId(): string
    local jobId = game.JobId
    if type(jobId) == "string" and jobId ~= "" then
        return jobId
    end
    return string.format("local-%06d", math.random(100000, 999999))
end

local function deepCopy(value: any): any
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, nested in pairs(value) do
        copy[key] = deepCopy(nested)
    end
    return copy
end

-- Non-destructive: anything already in the save wins, and only keys that do not
-- exist yet are filled in. Safe to run on every single load.
local function mergeDefaults(
    loaded: { [string]: any },
    defaults: { [string]: any }
): { [string]: any }
    local merged = deepCopy(defaults)
    for key, value in pairs(loaded) do
        merged[key] = value
    end
    return merged
end

function DataStoreLite.new(): DataStoreLite
    local self = setmetatable({}, DataStoreLite)
    self._serverId = newServerId()
    self._memory = {}
    self._sessions = {}
    self._memoryOnly = false
    self._running = false
    self._autosaveThread = nil
    self._stats = { loads = 0, saves = 0, failures = 0, locksLost = 0 }

    local ok, store = pcall(function()
        return DataStoreService:GetDataStore(Config.Data.DATASTORE_NAME)
    end)

    if ok then
        self._store = store
    else
        self._store = nil
        self._memoryOnly = Config.Data.ALLOW_MEMORY_FALLBACK
        warn(
            string.format(
                "[CursedGems] DataStore unavailable (%s); using memory-only storage.",
                tostring(store)
            )
        )
    end

    return self
end

function DataStoreLite.isMemoryOnly(self: DataStoreLite): boolean
    return self._memoryOnly
end

function DataStoreLite.getStats(self: DataStoreLite)
    return self._stats
end

function DataStoreLite.getSession(self: DataStoreLite, userId: number): Session?
    return self._sessions[userId]
end

function DataStoreLite._acquireRemote(
    self: DataStoreLite,
    userId: number,
    defaults: { [string]: any }
): ({ [string]: any }?, string?, boolean)
    local store = self._store
    if not store then
        return nil, "no datastore handle", false
    end

    local key = Config.Data.KEY_PREFIX .. tostring(userId)
    local serverId = self._serverId
    local now = os.time()

    local written: any = nil
    -- Set inside the UpdateAsync closure below: the key had no save in it yet.
    local fresh = false
    local ok, err = pcall(function()
        written = store:UpdateAsync(key, function(previous: any): any
            local record = previous
            if type(record) ~= "table" then
                record = {}
            end

            local lock = record.lock
            if type(lock) == "table" and type(lock.owner) == "string" then
                local heldFor = now - (tonumber(lock.time) or 0)
                if lock.owner ~= serverId and heldFor < Config.Data.LOCK_TIMEOUT_SECONDS then
                    -- Another server is live on this key. Returning nil aborts the
                    -- write, which leaves their lock and data untouched.
                    return nil
                end
            end

            local loaded = record.data
            if type(loaded) ~= "table" then
                loaded = {}
                fresh = true
            end

            local merged = mergeDefaults(loaded, defaults)
            merged.lastSeen = now

            return { lock = { owner = serverId, time = now }, data = merged, version = 1 }
        end)
    end)

    if not ok then
        return nil, tostring(err), false
    end
    if type(written) ~= "table" or type(written.data) ~= "table" then
        return nil, "locked by another server", false
    end

    written.data.lastSeen = now
    return written.data, nil, fresh
end

function DataStoreLite._acquireMemory(
    self: DataStoreLite,
    userId: number,
    defaults: { [string]: any }
): { [string]: any }
    local existing = self._memory[userId]
    local merged = mergeDefaults(existing or {}, defaults)
    merged.lastSeen = os.time()
    self._memory[userId] = merged
    return merged
end

function DataStoreLite.acquire(
    self: DataStoreLite,
    userId: number,
    defaults: { [string]: any }
): (Session?, string?)
    local existing = self._sessions[userId]
    if existing then
        return existing, nil
    end

    local data: { [string]: any }? = nil
    local lastError: string? = nil
    local fresh = false

    if self._memoryOnly then
        fresh = self._memory[userId] == nil
        data = self:_acquireMemory(userId, defaults)
    else
        data, lastError, fresh = self:_acquireRemote(userId, defaults)

        if not data and lastError == "locked by another server" then
            -- The previous holder may be shutting down. Give it a short, bounded
            -- chance to release rather than dumping the player into memory-only.
            for attempt = 1, 3 do
                task.wait(Config.Data.RETRY_BASE_SECONDS * attempt)
                data, lastError, fresh = self:_acquireRemote(userId, defaults)
                if data then
                    break
                end
            end
        end

        if not data and Config.Data.ALLOW_MEMORY_FALLBACK then
            warn(
                string.format(
                    "[CursedGems] Load failed for user %d (%s); using memory-only storage for the rest of this server (progress will not persist).",
                    userId,
                    tostring(lastError)
                )
            )
            self._memoryOnly = true
            fresh = self._memory[userId] == nil
            data = self:_acquireMemory(userId, defaults)
        end
    end

    if not data then
        return nil, lastError or "unknown load failure"
    end

    self._stats.loads += 1
    local session: Session = {
        userId = userId,
        data = data,
        dirty = false,
        fresh = fresh,
        acquiredAt = os.time(),
        lastSaveAt = 0,
    }
    self._sessions[userId] = session
    return session, nil
end

function DataStoreLite.markDirty(self: DataStoreLite, userId: number)
    local session = self._sessions[userId]
    if session then
        session.dirty = true
    end
end

function DataStoreLite.save(self: DataStoreLite, userId: number, force: boolean?): boolean
    local session = self._sessions[userId]
    if not session then
        return false
    end
    if not session.dirty and not force then
        return true
    end

    if self._memoryOnly then
        self._memory[userId] = session.data
        session.dirty = false
        session.lastSaveAt = os.time()
        return true
    end

    local store = self._store
    if not store then
        return false
    end

    local key = Config.Data.KEY_PREFIX .. tostring(userId)
    local serverId = self._serverId
    local lostLock = false

    local ok, err = pcall(function()
        store:UpdateAsync(key, function(previous: any): any
            local record = previous
            if type(record) ~= "table" then
                record = {}
            end

            local lock = record.lock
            if
                type(lock) == "table"
                and type(lock.owner) == "string"
                and lock.owner ~= serverId
            then
                lostLock = true
                return nil
            end

            return {
                lock = { owner = serverId, time = os.time() },
                data = session.data,
                version = 1,
            }
        end)
    end)

    if not ok then
        self._stats.failures += 1
        warn(string.format("[CursedGems] Save failed for user %d: %s", userId, tostring(err)))
        return false
    end

    if lostLock then
        self._stats.locksLost += 1
        warn(
            string.format(
                "[CursedGems] Lock lost for user %d; refusing to overwrite another server.",
                userId
            )
        )
        return false
    end

    session.dirty = false
    session.lastSaveAt = os.time()
    self._stats.saves += 1
    return true
end

function DataStoreLite.saveWithRetry(self: DataStoreLite, userId: number, force: boolean?): boolean
    local attempts = math.max(1, Config.Data.MAX_SAVE_RETRIES)
    for attempt = 1, attempts do
        if self:save(userId, force) then
            return true
        end
        if not self._sessions[userId] then
            return false
        end
        if attempt < attempts then
            task.wait(Config.Data.RETRY_BASE_SECONDS * attempt)
        end
    end
    return false
end

function DataStoreLite.release(self: DataStoreLite, userId: number, saveFirst: boolean?)
    if not self._sessions[userId] then
        return
    end

    if saveFirst ~= false then
        self:saveWithRetry(userId, true)
    end

    self._sessions[userId] = nil

    if self._memoryOnly or not self._store then
        return
    end

    local key = Config.Data.KEY_PREFIX .. tostring(userId)
    local serverId = self._serverId
    -- Clearing the lock is best effort: if it fails, the stale-lock timeout is
    -- the safety net, and the player's data was already saved above.
    pcall(function()
        self._store:UpdateAsync(key, function(previous: any): any
            local record = previous
            if type(record) ~= "table" then
                record = {}
            end
            local lock = record.lock
            if
                type(lock) == "table"
                and type(lock.owner) == "string"
                and lock.owner ~= serverId
            then
                return nil
            end
            record.lock = nil
            return record
        end)
    end)
end

function DataStoreLite.startAutosave(self: DataStoreLite)
    if self._running then
        return
    end
    self._running = true
    self._autosaveThread = task.spawn(function()
        while self._running do
            task.wait(Config.Data.AUTOSAVE_SECONDS)
            -- Snapshot the ids first: saveWithRetry yields, and a player leaving
            -- mid-save would otherwise mutate the table we are iterating.
            local ids: { number } = {}
            for userId in pairs(self._sessions) do
                table.insert(ids, userId)
            end
            for _, userId in ipairs(ids) do
                self:saveWithRetry(userId, false)
            end
        end
    end)
end

function DataStoreLite.stopAutosave(self: DataStoreLite)
    self._running = false
    self._autosaveThread = nil
end

function DataStoreLite.flushAll(self: DataStoreLite)
    local ids: { number } = {}
    for userId in pairs(self._sessions) do
        table.insert(ids, userId)
    end
    for _, userId in ipairs(ids) do
        self:save(userId, true)
    end
end

return DataStoreLite
