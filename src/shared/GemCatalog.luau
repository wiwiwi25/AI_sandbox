--!strict
--[[
    CursedGems :: GemCatalog
    ------------------------------------------------------------------
    Gem kinds and their drop odds.

    Only two kinds exist in Phase 1 on purpose. A bigger table would be data
    without meaning: what matters is that exactly ONE jackpot exists, so a new
    player can learn the entire value system at a glance.

    92 / 8 was chosen so a cursed gem (5x value) shows up roughly once per 12
    pickups: frequent enough to be discovered inside a first session, rare
    enough that it still reads as a jackpot.
]]

local Config = require(script.Parent.Config)
local Util = require(script.Parent.Util)

export type GemKind = {
    id: string,
    displayName: string,
    weight: number,
    value: number,
    color: Color3,
    material: Enum.Material,
    lightColor: Color3?,
    lightRange: number?,
    lightBrightness: number?,
    sparkle: boolean,
}

local GemCatalog = {}

local kinds: { GemKind } = {
    {
        id = "Common",
        displayName = "Gem",
        weight = Config.Gems.COMMON_WEIGHT,
        value = Config.Gems.COMMON_VALUE,
        color = Color3.fromRGB(88, 224, 178),
        material = Enum.Material.Glass,
        lightColor = Color3.fromRGB(90, 255, 200),
        lightRange = 8,
        lightBrightness = 0.75,
        sparkle = false,
    },
    {
        id = "Cursed",
        displayName = "Cursed Gem",
        weight = Config.Gems.CURSED_WEIGHT,
        value = Config.Gems.CURSED_VALUE,
        color = Color3.fromRGB(186, 74, 255),
        material = Enum.Material.Neon,
        lightColor = Color3.fromRGB(190, 90, 255),
        lightRange = 16,
        lightBrightness = 2.5,
        sparkle = true,
    },
}

local byId: { [string]: GemKind } = {}
for _, kind in ipairs(kinds) do
    byId[kind.id] = kind
end

GemCatalog.Kinds = kinds
GemCatalog.ById = byId

function GemCatalog.get(id: string): GemKind?
    return byId[id]
end

function GemCatalog.roll(rng: Random): GemKind
    local picked = Util.weightedPick(kinds, function(kind: GemKind): number
        return kind.weight
    end, rng)
    return picked or kinds[1]
end

-- Used by the design doc and by balance tests: the average value of one pickup.
function GemCatalog.expectedValue(): number
    local totalWeight = 0
    local totalValue = 0
    for _, kind in ipairs(kinds) do
        totalWeight += kind.weight
        totalValue += kind.weight * kind.value
    end
    if totalWeight <= 0 then
        return 0
    end
    return totalValue / totalWeight
end

return GemCatalog
