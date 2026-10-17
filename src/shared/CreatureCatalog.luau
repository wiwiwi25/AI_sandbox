--!strict
--[[
    CursedGems :: CreatureCatalog
    ------------------------------------------------------------------
    The five Phase 1 creatures, assembled from primitives rather than
    uploaded meshes.

    Why primitives: Phase 1 must run without any asset upload, moderation
    queue or asset-id bookkeeping. Every creature is therefore a small list of
    parts, so it lives in source control, diffs cleanly, and is re-tuned by
    editing numbers instead of re-exporting a model.

    Weights are flat, one row per creature, and sum to 100. A nested
    rarity-then-creature scheme needs two tables to answer the only question
    that actually matters - "how often is a Frost Pup?" - so flat wins.

    Resulting distribution: 70% Common, 25% Uncommon, 5% Rare.

    anchorHeight is the distance from the creature's ground contact point up to
    the model pivot. The server places the pivot at ground + anchorHeight, so a
    creature with no legs needs a larger value than a quadruped.
]]

local Util = require(script.Parent.Util)

local function V(x: number, y: number, z: number): Vector3
    return Vector3.new(x, y, z)
end

local function C(r: number, g: number, b: number): Color3
    return Color3.fromRGB(r, g, b)
end

export type GlowSpec = {
    color: Color3,
    range: number,
    brightness: number,
}

export type PartSpec = {
    name: string,
    shape: string,
    size: Vector3,
    offset: Vector3,
    rotation: Vector3?,
    color: Color3,
    material: Enum.Material,
    transparency: number?,
    glow: GlowSpec?,
}

export type CreatureDef = {
    id: string,
    displayName: string,
    rarity: string,
    weight: number,
    accentColor: Color3,
    anchorHeight: number,
    parts: { PartSpec },
}

local CreatureCatalog = {}

local list: { CreatureDef } = {
    {
        id = "Mossling",
        displayName = "Mossling",
        rarity = "Common",
        weight = 40,
        accentColor = C(110, 200, 110),
        anchorHeight = 1.15,
        parts = {
            {
                name = "Body",
                shape = "Ball",
                size = V(2.2, 2.2, 2.2),
                offset = V(0, 0, 0),
                color = C(96, 176, 96),
                material = Enum.Material.Grass,
            },
            {
                name = "EarL",
                shape = "Wedge",
                size = V(0.5, 1.5, 0.5),
                offset = V(-0.72, 1.45, 0),
                rotation = V(0, 0, -14),
                color = C(74, 144, 74),
                material = Enum.Material.Grass,
            },
            {
                name = "EarR",
                shape = "Wedge",
                size = V(0.5, 1.5, 0.5),
                offset = V(0.72, 1.45, 0),
                rotation = V(0, 0, 14),
                color = C(74, 144, 74),
                material = Enum.Material.Grass,
            },
            {
                name = "EyeL",
                shape = "Ball",
                size = V(0.34, 0.34, 0.34),
                offset = V(-0.44, 0.34, -0.98),
                color = C(22, 28, 22),
                material = Enum.Material.SmoothPlastic,
            },
            {
                name = "EyeR",
                shape = "Ball",
                size = V(0.34, 0.34, 0.34),
                offset = V(0.44, 0.34, -0.98),
                color = C(22, 28, 22),
                material = Enum.Material.SmoothPlastic,
            },
            {
                name = "Sprout",
                shape = "Block",
                size = V(0.14, 0.9, 0.6),
                offset = V(0, 1.3, 0.25),
                rotation = V(0, 0, 24),
                color = C(146, 226, 122),
                material = Enum.Material.Grass,
            },
        },
    },
    {
        id = "PebbleImp",
        displayName = "Pebble Imp",
        rarity = "Common",
        weight = 30,
        accentColor = C(140, 140, 152),
        anchorHeight = 1.05,
        parts = {
            {
                name = "Body",
                shape = "Block",
                size = V(1.8, 1.7, 1.6),
                offset = V(0, 0, 0),
                color = C(118, 118, 128),
                material = Enum.Material.Slate,
            },
            {
                name = "Head",
                shape = "Block",
                size = V(1.25, 1.0, 1.15),
                offset = V(0, 1.32, 0),
                color = C(132, 132, 142),
                material = Enum.Material.Slate,
            },
            {
                name = "Hat",
                shape = "Block",
                size = V(0.72, 1.35, 0.72),
                offset = V(0, 2.35, 0),
                rotation = V(0, 45, 0),
                color = C(64, 64, 76),
                material = Enum.Material.Slate,
            },
            {
                name = "EyeL",
                shape = "Ball",
                size = V(0.24, 0.24, 0.24),
                offset = V(-0.31, 1.36, -0.6),
                color = C(255, 170, 60),
                material = Enum.Material.Neon,
            },
            {
                name = "EyeR",
                shape = "Ball",
                size = V(0.24, 0.24, 0.24),
                offset = V(0.31, 1.36, -0.6),
                color = C(255, 170, 60),
                material = Enum.Material.Neon,
            },
            {
                name = "ArmL",
                shape = "Block",
                size = V(0.4, 0.9, 0.4),
                offset = V(-1.05, 0.1, 0),
                color = C(118, 118, 128),
                material = Enum.Material.Slate,
            },
            {
                name = "ArmR",
                shape = "Block",
                size = V(0.4, 0.9, 0.4),
                offset = V(1.05, 0.1, 0),
                color = C(118, 118, 128),
                material = Enum.Material.Slate,
            },
        },
    },
    {
        id = "EmberWisp",
        displayName = "Ember Wisp",
        rarity = "Uncommon",
        weight = 15,
        accentColor = C(255, 150, 50),
        anchorHeight = 2.0,
        parts = {
            {
                name = "Core",
                shape = "Ball",
                size = V(1.45, 1.45, 1.45),
                offset = V(0, 0, 0),
                color = C(255, 150, 50),
                material = Enum.Material.Neon,
                glow = { color = C(255, 140, 40), range = 18, brightness = 3 },
            },
            {
                name = "Shell",
                shape = "Ball",
                size = V(2.05, 2.05, 2.05),
                offset = V(0, 0, 0),
                transparency = 0.82,
                color = C(255, 96, 32),
                material = Enum.Material.Glass,
            },
            {
                name = "Halo",
                shape = "Cylinder",
                size = V(2.9, 0.14, 2.9),
                offset = V(0, 0.15, 0),
                color = C(255, 206, 140),
                material = Enum.Material.Neon,
                transparency = 0.25,
            },
            {
                name = "Ring",
                shape = "Cylinder",
                size = V(2.2, 0.1, 2.2),
                offset = V(0, 0, 0),
                rotation = V(72, 0, 0),
                color = C(255, 170, 90),
                material = Enum.Material.Neon,
                transparency = 0.35,
            },
            {
                name = "EmberL",
                shape = "Ball",
                size = V(0.3, 0.3, 0.3),
                offset = V(-1.15, 0.9, 0.7),
                color = C(255, 120, 40),
                material = Enum.Material.Neon,
            },
            {
                name = "EmberR",
                shape = "Ball",
                size = V(0.3, 0.3, 0.3),
                offset = V(1.15, 0.75, -0.7),
                color = C(255, 120, 40),
                material = Enum.Material.Neon,
            },
        },
    },
    {
        id = "FrostPup",
        displayName = "Frost Pup",
        rarity = "Uncommon",
        weight = 10,
        accentColor = C(168, 216, 255),
        anchorHeight = 1.3,
        parts = {
            {
                name = "Body",
                shape = "Block",
                size = V(1.25, 1.15, 2.2),
                offset = V(0, 0.05, 0),
                color = C(168, 216, 255),
                material = Enum.Material.Ice,
            },
            {
                name = "Head",
                shape = "Ball",
                size = V(1.15, 1.15, 1.15),
                offset = V(0, 0.7, -1.25),
                color = C(186, 228, 255),
                material = Enum.Material.Ice,
            },
            {
                name = "Snout",
                shape = "Block",
                size = V(0.62, 0.5, 0.6),
                offset = V(0, 0.55, -1.85),
                color = C(150, 200, 240),
                material = Enum.Material.Ice,
            },
            {
                name = "EarL",
                shape = "Wedge",
                size = V(0.4, 0.85, 0.32),
                offset = V(-0.42, 1.35, -0.98),
                rotation = V(0, 0, -10),
                color = C(140, 196, 240),
                material = Enum.Material.Ice,
            },
            {
                name = "EarR",
                shape = "Wedge",
                size = V(0.4, 0.85, 0.32),
                offset = V(0.42, 1.35, -0.98),
                rotation = V(0, 0, 10),
                color = C(140, 196, 240),
                material = Enum.Material.Ice,
            },
            {
                name = "LegFL",
                shape = "Block",
                size = V(0.42, 1.0, 0.42),
                offset = V(-0.42, -0.8, -0.62),
                color = C(150, 200, 240),
                material = Enum.Material.Ice,
            },
            {
                name = "LegFR",
                shape = "Block",
                size = V(0.42, 1.0, 0.42),
                offset = V(0.42, -0.8, -0.62),
                color = C(150, 200, 240),
                material = Enum.Material.Ice,
            },
            {
                name = "LegBL",
                shape = "Block",
                size = V(0.42, 1.0, 0.42),
                offset = V(-0.42, -0.8, 0.62),
                color = C(150, 200, 240),
                material = Enum.Material.Ice,
            },
            {
                name = "LegBR",
                shape = "Block",
                size = V(0.42, 1.0, 0.42),
                offset = V(0.42, -0.8, 0.62),
                color = C(150, 200, 240),
                material = Enum.Material.Ice,
            },
            {
                name = "Tail",
                shape = "Cylinder",
                size = V(0.32, 1.15, 0.32),
                offset = V(0, 0.62, 1.32),
                rotation = V(62, 0, 0),
                color = C(186, 228, 255),
                material = Enum.Material.Ice,
            },
            {
                name = "EyeL",
                shape = "Ball",
                size = V(0.22, 0.22, 0.22),
                offset = V(-0.32, 0.86, -1.62),
                color = C(120, 220, 255),
                material = Enum.Material.Neon,
            },
            {
                name = "EyeR",
                shape = "Ball",
                size = V(0.22, 0.22, 0.22),
                offset = V(0.32, 0.86, -1.62),
                color = C(120, 220, 255),
                material = Enum.Material.Neon,
            },
        },
    },
    {
        id = "VoidCub",
        displayName = "Void Cub",
        rarity = "Rare",
        weight = 5,
        accentColor = C(178, 86, 255),
        anchorHeight = 0.85,
        parts = {
            {
                name = "Body",
                shape = "Block",
                size = V(1.5, 1.5, 1.5),
                offset = V(0, 0, 0),
                color = C(38, 30, 52),
                material = Enum.Material.SmoothPlastic,
            },
            {
                name = "Head",
                shape = "Block",
                size = V(1.15, 1.05, 1.1),
                offset = V(0, 1.32, 0),
                color = C(48, 38, 66),
                material = Enum.Material.SmoothPlastic,
            },
            {
                name = "HornL",
                shape = "Wedge",
                size = V(0.34, 0.9, 0.34),
                offset = V(-0.42, 2.18, 0),
                rotation = V(0, 0, -18),
                color = C(150, 80, 255),
                material = Enum.Material.Neon,
            },
            {
                name = "HornR",
                shape = "Wedge",
                size = V(0.34, 0.9, 0.34),
                offset = V(0.42, 2.18, 0),
                rotation = V(0, 0, 18),
                color = C(150, 80, 255),
                material = Enum.Material.Neon,
            },
            {
                name = "Crystal",
                shape = "Ball",
                size = V(0.42, 0.42, 0.42),
                offset = V(0, 0, -0.88),
                color = C(178, 86, 255),
                material = Enum.Material.Neon,
                glow = { color = C(170, 80, 255), range = 16, brightness = 2.5 },
            },
            {
                name = "ShardA",
                shape = "Ball",
                size = V(0.28, 0.28, 0.28),
                offset = V(1.05, 0.62, 0.42),
                color = C(140, 70, 220),
                material = Enum.Material.Neon,
            },
            {
                name = "ShardB",
                shape = "Ball",
                size = V(0.24, 0.24, 0.24),
                offset = V(-1.02, 0.35, -0.5),
                color = C(140, 70, 220),
                material = Enum.Material.Neon,
            },
            {
                name = "ShardC",
                shape = "Ball",
                size = V(0.26, 0.26, 0.26),
                offset = V(-0.85, 0.95, 0.45),
                color = C(140, 70, 220),
                material = Enum.Material.Neon,
            },
            {
                name = "EyeL",
                shape = "Ball",
                size = V(0.22, 0.22, 0.22),
                offset = V(-0.32, 1.42, -0.58),
                color = C(255, 90, 255),
                material = Enum.Material.Neon,
            },
            {
                name = "EyeR",
                shape = "Ball",
                size = V(0.22, 0.22, 0.22),
                offset = V(0.32, 1.42, -0.58),
                color = C(255, 90, 255),
                material = Enum.Material.Neon,
            },
        },
    },
}

local byId: { [string]: CreatureDef } = {}
for _, def in ipairs(list) do
    byId[def.id] = def
end

CreatureCatalog.List = list
CreatureCatalog.ById = byId

function CreatureCatalog.get(id: string): CreatureDef?
    return byId[id]
end

function CreatureCatalog.roll(rng: Random): CreatureDef
    local picked = Util.weightedPick(list, function(def: CreatureDef): number
        return def.weight
    end, rng)
    return picked or list[1]
end

function CreatureCatalog.byRarity(rarity: string): { CreatureDef }
    local matches: { CreatureDef } = {}
    for _, def in ipairs(list) do
        if def.rarity == rarity then
            table.insert(matches, def)
        end
    end
    return matches
end

return CreatureCatalog
