--!strict
--[[
CursedGems :: Pool
A generic object pool.

Why this exists: gems and creature models are created and destroyed
constantly. Instantiating and destroying parts is one of the most expensive
things a Roblox server can do, and it scales linearly with player count.
Reusing a fixed set of instances keeps frame cost flat as the server fills.
]]

local Pool = {}
Pool.__index = Pool

export type Pool = typeof(setmetatable(
    {} :: {
        _factory: () -> Instance,
        _parent: Instance?,
        _free: { Instance },
        _inUse: { [Instance]: boolean },
        _inUseCount: number,
        _created: number,
    },
    Pool
))

function Pool.new(factory: () -> Instance, parent: Instance?): Pool
    local self = setmetatable({}, Pool)
    self._factory = factory
    self._parent = parent
    self._free = {}
    self._inUse = {}
    self._inUseCount = 0
    self._created = 0
    return self
end

-- Builds instances up front so the first minutes of a session never pay the
-- instantiation cost.
function Pool.prewarm(self: Pool, count: number)
    for _ = 1, count do
        local instance = self._factory()
        self._created += 1
        instance.Parent = nil
        table.insert(self._free, instance)
    end
end

function Pool.acquire(self: Pool): Instance
    -- `instance` is declared with its final type up front instead of being
    -- inferred from a branch. table.remove hands back a T?, and relying on the
    -- analyser to re-narrow that on the join is fragile, so we assign it in both
    -- arms of an explicit if/else instead.
    local instance: Instance
    local reusable = table.remove(self._free)
    if reusable ~= nil then
        instance = reusable
    else
        instance = self._factory()
        self._created += 1
    end

    self._inUse[instance] = true
    self._inUseCount += 1
    if self._parent then
        instance.Parent = self._parent
    end
    return instance
end

function Pool.release(self: Pool, instance: Instance)
    if not self._inUse[instance] then
        return
    end

    self._inUse[instance] = nil
    self._inUseCount -= 1
    instance.Parent = nil
    table.insert(self._free, instance)
end

function Pool.releaseAll(self: Pool)
    for instance in self._inUse do
        self:release(instance)
    end
end

function Pool.stats(self: Pool): (number, number, number)
    return self._created, #self._free, self._inUseCount
end

function Pool.destroy(self: Pool)
    for _, instance in ipairs(self._free) do
        instance:Destroy()
    end
    table.clear(self._free)
    for instance in self._inUse do
        instance:Destroy()
    end
    table.clear(self._inUse)
    self._inUseCount = 0
    self._created = 0
end

return Pool
