--!strict
--[[
CursedGems :: Util
Small, dependency-free helpers shared by server and client.
]]

local Util = {}

-- Picks one entry from a list using a caller-supplied weight function.
-- Weighted rolls are the backbone of both gem rarity and creature rarity.
function Util.weightedPick<T>(entries: { T }, weightOf: (T) -> number, rng: Random): T?
    local total = 0
    for _, entry in ipairs(entries) do
        total += math.max(0, weightOf(entry))
    end
    if total <= 0 then
        return nil
    end

    local roll = rng:NextNumber() * total
    local accumulator = 0
    for _, entry in ipairs(entries) do
        accumulator += math.max(0, weightOf(entry))
        if roll <= accumulator then
            return entry
        end
    end

    -- Floating point safety net: only reachable if rounding drifts.
    return entries[#entries]
end

-- Fisher-Yates. Returns the same table for convenient chaining.
function Util.shuffle<T>(list: { T }, rng: Random): { T }
    for index = #list, 2, -1 do
        local swap = rng:NextInteger(1, index)
        list[index], list[swap] = list[swap], list[index]
    end
    return list
end

function Util.round(value: number, places: number): number
    local scale = 10 ^ (places or 0)
    return math.floor(value * scale + 0.5) / scale
end

function Util.distanceXZ(a: Vector3, b: Vector3): number
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

function Util.isFiniteNumber(value: unknown): boolean
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Short display form so the HUD never prints an unreadable integer. The divisor
-- must match the threshold it belongs to, or a six-digit balance renders as
-- "100.0K" - which is worse than the digits it replaced.
function Util.abbreviate(amount: number): string
    local rounded = math.floor(amount)
    if rounded >= 1000000 then
        return string.format("%.1fM", rounded / 1000000)
    elseif rounded >= 1000 then
        return string.format("%.1fK", rounded / 1000)
    end
    return tostring(rounded)
end

return Util
