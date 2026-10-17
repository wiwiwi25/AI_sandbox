--!strict
--[[
    CursedGems :: WorldBuilder
    ------------------------------------------------------------------
    Builds the ENTIRE playable map from code.

    Why code and not a saved model:
      * The map is a flat arena plus roughly 150 decorative props. Generating it
        means one number in Config resizes the world and the props follow, with
        no unreviewable binary blob in the repository.
      * The server and any future editor tooling see byte-identical worlds,
        generated from the same seed.
      * Server-authoritative gem placement needs a list of LEGAL positions that
        the client did not choose. Generating that list here keeps it out of the
        hands of the client entirely.

    Everything is parented under one Workspace folder, so build() is idempotent:
    destroy the folder, generate again. Nothing is ever hand-edited, so nothing
    can drift away from this file.

    Output contract:
      World/Geometry       ground, walls, shrine, cave, trees, rocks, spawn
      World/GemSpawns      invisible marker at every legal gem position
      World/Pens           summon pens, one pedestal plus prompt anchor each

    Ordering detail that matters: gem positions are generated FIRST and props are
    scattered around them afterwards. That way a tree can never end up on top of
    a legal gem position - a bug that is invisible in review and maddening in
    play.

    GOTCHA worth knowing: a Part with Shape = Cylinder puts its circular faces on
    the X axis, not the Y axis. Every flat disc and every upright column in this
    file therefore carries a 90 degree Z rotation.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local CollectionService = game:GetService("CollectionService")
local Util = Shared.Util

local WorldBuilder = {}

local FOLDER_NAME = "World"
local PEN_PAD_RADIUS = 14

-- Client-facing tag: lets the client animate every marker without guessing at
-- folder layout or name patterns. The string itself lives in Config, next to the
-- gems' tag, because exactly one client module animates both.
local PEN_MARKER_TAG = Config.Tags.PEN_MARKER

-- Hand-placed rather than generated: four pens must stay clear of the shrine,
-- of the cave and of each other. An explicit list makes that checkable by
-- reading it instead of by reasoning about trigonometry.
local PEN_POSITIONS: { Vector3 } = {
    Vector3.new(170, 0, 40),
    Vector3.new(-170, 0, 40),
    Vector3.new(170, 0, -40),
    Vector3.new(-170, 0, -40),
}

local GROUND_COLOR = Color3.fromRGB(74, 116, 82)
local STONE_COLOR = Color3.fromRGB(104, 104, 112)
local SHRINE_COLOR = Color3.fromRGB(228, 224, 236)
local CAVE_COLOR = Color3.fromRGB(80, 78, 86)

export type PartOptions = {
    name: string,
    size: Vector3,
    position: Vector3,
    color: Color3,
    material: Enum.Material,
    rotation: Vector3?,
    shape: Enum.PartType?,
    transparency: number?,
    canCollide: boolean?,
    castShadow: boolean?,
    parent: Instance?,
}

export type Pen = {
    index: number,
    center: Vector3,
    -- Concrete 'Part', not 'BasePart': Luau treats table properties as
    -- invariant, so declaring the wider supertype here would reject the
    -- 'Part' values that makePart actually returns.
    pad: Part,
    pedestal: Part,
}

export type BuildResult = {
    folder: Folder,
    gemSpawnPoints: { Vector3 },
    pens: { Pen },
    shrineCenter: Vector3,
}

local function makePart(options: PartOptions): Part
    local part = Instance.new("Part")
    part.Name = options.name
    part.Shape = options.shape or Enum.PartType.Block
    part.Size = options.size
    part.Anchored = true
    part.CanCollide = options.canCollide ~= false
    part.CastShadow = options.castShadow ~= false
    part.Color = options.color
    part.Material = options.material
    part.Transparency = options.transparency or 0

    local rotation = options.rotation or Vector3.zero
    part.CFrame = CFrame.new(options.position)
        * CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))

    part.Parent = options.parent
    return part
end

local function insideCaveBox(
    caveCenter: Vector3,
    caveSize: Vector3,
    position: Vector3,
    margin: number
): boolean
    local halfX = caveSize.X * 0.5 + margin
    local halfZ = caveSize.Z * 0.5 + margin
    return math.abs(position.X - caveCenter.X) < halfX
        and math.abs(position.Z - caveCenter.Z) < halfZ
end

-- True only inside the cave WALLS, never the interior. Gems are allowed inside
-- the cave (it is a deliberate risk destination) but must never be buried in a
-- slab where nobody can reach them.
local function insideCaveShell(caveCenter: Vector3, caveSize: Vector3, position: Vector3): boolean
    if not insideCaveBox(caveCenter, caveSize, position, 3) then
        return false
    end
    local innerX = caveSize.X * 0.5 - 8
    local innerZ = caveSize.Z * 0.5 - 8
    local inInterior = math.abs(position.X - caveCenter.X) < innerX
        and math.abs(position.Z - caveCenter.Z) < innerZ
    return not inInterior
end

local function tooCloseToAny(candidate: Vector3, points: { Vector3 }, minimum: number): boolean
    for _, point in ipairs(points) do
        if Util.distanceXZ(candidate, point) < minimum then
            return true
        end
    end
    return false
end

local function clearGenerated()
    local existing = Workspace:FindFirstChild(FOLDER_NAME)
    if existing then
        existing:Destroy()
    end
end

-- Mood, not decoration: a warm low sun plus a light haze makes the gem lights
-- and the cursed purple read clearly at a distance. All of this is cosmetic and
-- never touches gameplay state.
local function applyLighting()
    Lighting.ClockTime = 15.4
    Lighting.Brightness = 2
    Lighting.Ambient = Color3.fromRGB(58, 60, 70)
    Lighting.OutdoorAmbient = Color3.fromRGB(96, 102, 118)
    Lighting.GlobalShadows = true
    Lighting.EnvironmentDiffuseScale = 0.4
    Lighting.EnvironmentSpecularScale = 0.2

    local atmosphere = Lighting:FindFirstChildWhichIsA("Atmosphere")
    if not atmosphere then
        atmosphere = Instance.new("Atmosphere")
        atmosphere.Parent = Lighting
    end
    local atmosphereInstance = atmosphere :: Atmosphere
    atmosphereInstance.Density = 0.32
    atmosphereInstance.Haze = 1.4
    atmosphereInstance.Glare = 0.1
    atmosphereInstance.Color = Color3.fromRGB(196, 208, 220)
    atmosphereInstance.Decay = Color3.fromRGB(106, 112, 130)

    local bloom = Lighting:FindFirstChildWhichIsA("BloomEffect")
    if not bloom then
        bloom = Instance.new("BloomEffect")
        bloom.Parent = Lighting
    end
    local bloomInstance = bloom :: BloomEffect
    bloomInstance.Intensity = 0.7
    bloomInstance.Size = 22
    bloomInstance.Threshold = 1.1
end

local function generateGemSpawnPoints(rng: Random, isBlocked: (Vector3) -> boolean): { Vector3 }
    local target = math.max(Config.Gems.POOL_MAX + 10, 42)
    local inner = Config.World.GEM_FIELD_INNER_RADIUS
    local outer = Config.World.GEM_FIELD_OUTER_RADIUS
    local height = Config.World.GROUND_Y + Config.Gems.GEM_HEIGHT
    local points: { Vector3 } = {}

    local attempts = 0
    local maxAttempts = target * Config.Gems.MAX_SPAWN_ATTEMPTS
    while #points < target and attempts < maxAttempts do
        attempts += 1

        local angle = rng:NextNumber() * math.pi * 2
        -- sqrt() makes the sample area-uniform. Without it, points pile up near
        -- the inner radius and the outer field stays visibly empty.
        local radius = inner + math.sqrt(rng:NextNumber()) * (outer - inner)
        local candidate = Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)

        if not isBlocked(candidate) then
            if not tooCloseToAny(candidate, points, Config.Gems.MIN_GEM_SPACING) then
                table.insert(points, candidate)
            end
        end
    end

    if #points < target then
        warn(
            string.format(
                "[CursedGems] Gem field accepted %d of %d positions. MIN_GEM_SPACING (%.0f) is too tight for this ring, or too much of the field is blocked.",
                #points,
                target,
                Config.Gems.MIN_GEM_SPACING
            )
        )
    end

    return points
end

local function buildShrine(parent: Instance): Folder
    local folder = Instance.new("Folder")
    folder.Name = "Shrine"
    folder.Parent = parent

    local center = Config.World.SHRINE_POSITION
    local radius = Config.World.SHRINE_PAD_RADIUS
    local groundY = Config.World.GROUND_Y
    local flat = Vector3.new(0, 0, 90)

    makePart({
        name = "Pad",
        shape = Enum.PartType.Cylinder,
        size = Vector3.new(0.6, radius * 2, radius * 2),
        rotation = flat,
        position = Vector3.new(center.X, groundY + 0.3, center.Z),
        color = SHRINE_COLOR,
        material = Enum.Material.Marble,
        castShadow = false,
        parent = folder,
    })

    makePart({
        name = "PadRing",
        shape = Enum.PartType.Cylinder,
        size = Vector3.new(0.5, radius * 2 + 6, radius * 2 + 6),
        rotation = flat,
        position = Vector3.new(center.X, groundY + 0.35, center.Z),
        color = Color3.fromRGB(150, 214, 255),
        material = Enum.Material.Neon,
        transparency = 0.4,
        castShadow = false,
        parent = folder,
    })

    local beacon = makePart({
        name = "Beacon",
        shape = Enum.PartType.Cylinder,
        size = Vector3.new(64, 9, 9),
        rotation = flat,
        position = Vector3.new(center.X, groundY + 32, center.Z),
        color = Color3.fromRGB(180, 226, 255),
        material = Enum.Material.Neon,
        transparency = 0.72,
        canCollide = false,
        castShadow = false,
        parent = folder,
    })

    local light = Instance.new("PointLight")
    light.Color = Color3.fromRGB(170, 216, 255)
    light.Range = 46
    light.Brightness = 2
    light.Shadows = false
    light.Parent = beacon

    makePart({
        name = "HeartGem",
        shape = Enum.PartType.Ball,
        size = Vector3.new(4, 4, 4),
        position = Vector3.new(center.X, groundY + 7, center.Z),
        color = Color3.fromRGB(120, 255, 210),
        material = Enum.Material.Neon,
        canCollide = false,
        castShadow = false,
        parent = folder,
    })

    return folder
end

-- An enclosed box with exactly one doorway, built from slabs rather than
-- Terrain. Voxel writes are expensive and irreversible, and a cave this small
-- gains nothing from them. The doorway faces +Z, which is toward the shrine.
local function buildCave(parent: Instance): Folder
    local folder = Instance.new("Folder")
    folder.Name = "Cave"
    folder.Parent = parent

    local center = Config.World.CAVE_CENTER
    local size = Config.World.CAVE_SIZE
    local height = size.Y
    local halfX = size.X * 0.5
    local halfZ = size.Z * 0.5
    local thickness = 4
    local doorwayWidth = 22
    local midY = center.Y + height * 0.5

    local function slab(name: string, slabSize: Vector3, position: Vector3)
        makePart({
            name = name,
            size = slabSize,
            position = position,
            color = CAVE_COLOR,
            material = Enum.Material.Rock,
            parent = folder,
        })
    end

    slab(
        "WallNorth",
        Vector3.new(size.X, height, thickness),
        Vector3.new(center.X, midY, center.Z - halfZ)
    )
    slab(
        "WallWest",
        Vector3.new(thickness, height, size.Z),
        Vector3.new(center.X - halfX, midY, center.Z)
    )
    slab(
        "WallEast",
        Vector3.new(thickness, height, size.Z),
        Vector3.new(center.X + halfX, midY, center.Z)
    )

    local segmentWidth = (size.X - doorwayWidth) * 0.5
    for index, direction in ipairs({ -1, 1 }) do
        slab(
            string.format("WallSouth%d", index),
            Vector3.new(segmentWidth, height, thickness),
            Vector3.new(
                center.X + direction * (doorwayWidth * 0.5 + segmentWidth * 0.5),
                midY,
                center.Z + halfZ
            )
        )
    end

    slab(
        "Roof",
        Vector3.new(size.X + thickness, thickness, size.Z + thickness),
        Vector3.new(center.X, center.Y + height + thickness * 0.5, center.Z)
    )

    return folder
end

-- One pen per summon pedestal. The floating gem above each pedestal is the
-- entire "something happens here" affordance, so the location needs no UI.
local function buildPens(parent: Folder): { Pen }
    local folder = Instance.new("Folder")
    folder.Name = "Pens"
    folder.Parent = parent

    local pens: { Pen } = {}
    for index, position in ipairs(PEN_POSITIONS) do
        local pad = makePart({
            name = string.format("Pen%dPad", index),
            shape = Enum.PartType.Cylinder,
            size = Vector3.new(0.5, PEN_PAD_RADIUS * 2, PEN_PAD_RADIUS * 2),
            rotation = Vector3.new(0, 0, 90),
            position = Vector3.new(position.X, Config.World.GROUND_Y + 0.25, position.Z),
            color = Color3.fromRGB(74, 72, 88),
            material = Enum.Material.Slate,
            castShadow = false,
            parent = folder,
        })

        local pedestal = makePart({
            name = string.format("Pen%dPedestal", index),
            size = Vector3.new(3, 3.2, 3),
            position = Vector3.new(position.X, Config.World.GROUND_Y + 1.6, position.Z),
            color = Color3.fromRGB(44, 42, 56),
            material = Enum.Material.Marble,
            parent = folder,
        })

        local marker = makePart({
            name = string.format("Pen%dMarker", index),
            shape = Enum.PartType.Ball,
            size = Vector3.new(1.6, 1.6, 1.6),
            position = Vector3.new(position.X, Config.World.GROUND_Y + 5.4, position.Z),
            color = Color3.fromRGB(186, 74, 255),
            material = Enum.Material.Neon,
            canCollide = false,
            castShadow = false,
            parent = folder,
        })

        CollectionService:AddTag(marker, PEN_MARKER_TAG)

        table.insert(pens, { index = index, center = position, pad = pad, pedestal = pedestal })
    end

    return pens
end

local function scatterProps(
    parent: Instance,
    rng: Random,
    keepClear: { Vector3 },
    pens: { Pen },
    shrine: Vector3,
    caveCenter: Vector3,
    caveSize: Vector3
)
    local inner = Config.World.GEM_FIELD_INNER_RADIUS
    local outer = Config.World.GEM_FIELD_OUTER_RADIUS
    local groundY = Config.World.GROUND_Y

    local function findSpot(attempts: number, clearance: number): Vector3?
        for _ = 1, attempts do
            local angle = rng:NextNumber() * math.pi * 2
            local radius = inner + math.sqrt(rng:NextNumber()) * (outer - inner)
            local candidate =
                Vector3.new(math.cos(angle) * radius, groundY, math.sin(angle) * radius)

            if Util.distanceXZ(candidate, shrine) < Config.World.SHRINE_PAD_RADIUS + 14 then
                continue
            end
            if insideCaveBox(caveCenter, caveSize, candidate, 10) then
                continue
            end

            local blocked = false
            for _, pen in ipairs(pens) do
                if Util.distanceXZ(candidate, pen.center) < PEN_PAD_RADIUS + 10 then
                    blocked = true
                    break
                end
            end
            if blocked or tooCloseToAny(candidate, keepClear, clearance) then
                continue
            end

            return candidate
        end
        return nil
    end

    for _ = 1, Config.World.TREE_COUNT do
        local spot = findSpot(24, 9)
        if not spot then
            break
        end
        local height = rng:NextNumber(9, 17)
        makePart({
            name = "TreeTrunk",
            size = Vector3.new(2.2, height, 2.2),
            position = Vector3.new(spot.X, spot.Y + height * 0.5, spot.Z),
            color = Color3.fromRGB(96, 68, 48),
            material = Enum.Material.Wood,
            parent = parent,
        })
        local canopy = rng:NextNumber(5.5, 9)
        makePart({
            name = "TreeCanopy",
            shape = Enum.PartType.Ball,
            size = Vector3.new(canopy * 2, canopy * 1.7, canopy * 2),
            position = Vector3.new(spot.X, spot.Y + height + canopy * 0.3, spot.Z),
            color = Color3.fromRGB(58, 116, 62),
            material = Enum.Material.Grass,
            parent = parent,
        })
    end

    for _ = 1, Config.World.ROCK_COUNT do
        local spot = findSpot(18, 6)
        if not spot then
            break
        end
        local rockSize =
            Vector3.new(rng:NextNumber(3, 9), rng:NextNumber(2.5, 7), rng:NextNumber(3, 9))
        makePart({
            name = "Rock",
            size = rockSize,
            position = Vector3.new(spot.X, spot.Y + rockSize.Y * 0.3, spot.Z),
            rotation = Vector3.new(0, rng:NextNumber(0, 360), 0),
            color = STONE_COLOR,
            material = Enum.Material.Slate,
            parent = parent,
        })
    end
end

function WorldBuilder.build(): BuildResult
    clearGenerated()
    applyLighting()

    local folder = Instance.new("Folder")
    folder.Name = FOLDER_NAME
    folder.Parent = Workspace

    local geometry = Instance.new("Folder")
    geometry.Name = "Geometry"
    geometry.Parent = folder

    -- A place file ships with a decorative Baseplate. It would hang above the
    -- generated ground and confuse spawn height, so it goes.
    local baseplate = Workspace:FindFirstChild("Baseplate")
    if baseplate then
        baseplate:Destroy()
    end

    local rng = Random.new(Config.World.SEED)
    local groundY = Config.World.GROUND_Y
    local half = Config.World.MAP_SIZE * 0.5
    local shrine = Config.World.SHRINE_POSITION
    local caveCenter = Config.World.CAVE_CENTER
    local caveSize = Config.World.CAVE_SIZE

    makePart({
        name = "Ground",
        size = Vector3.new(Config.World.MAP_SIZE, 8, Config.World.MAP_SIZE),
        position = Vector3.new(0, groundY - 4, 0),
        color = GROUND_COLOR,
        material = Enum.Material.Grass,
        castShadow = false,
        parent = geometry,
    })

    local wallHeight = 30
    local wallThickness = 4
    local wallY = groundY + wallHeight * 0.5
    local wallSizeLong = Vector3.new(Config.World.MAP_SIZE, wallHeight, wallThickness)
    local wallSizeSide = Vector3.new(wallThickness, wallHeight, Config.World.MAP_SIZE)
    makePart({
        name = "WallNorth",
        size = wallSizeLong,
        position = Vector3.new(0, wallY, -half),
        color = STONE_COLOR,
        material = Enum.Material.Rock,
        parent = geometry,
    })
    makePart({
        name = "WallSouth",
        size = wallSizeLong,
        position = Vector3.new(0, wallY, half),
        color = STONE_COLOR,
        material = Enum.Material.Rock,
        parent = geometry,
    })
    makePart({
        name = "WallEast",
        size = wallSizeSide,
        position = Vector3.new(half, wallY, 0),
        color = STONE_COLOR,
        material = Enum.Material.Rock,
        parent = geometry,
    })
    makePart({
        name = "WallWest",
        size = wallSizeSide,
        position = Vector3.new(-half, wallY, 0),
        color = STONE_COLOR,
        material = Enum.Material.Rock,
        parent = geometry,
    })

    local spawnLocation = Instance.new("SpawnLocation")
    spawnLocation.Name = "PlayerSpawn"
    spawnLocation.Size = Vector3.new(14, 1, 14)
    spawnLocation.CFrame =
        CFrame.new(Config.World.PLAYER_SPAWN.X, groundY + 0.5, Config.World.PLAYER_SPAWN.Z)
    spawnLocation.Anchored = true
    spawnLocation.CanCollide = true
    spawnLocation.Neutral = true
    spawnLocation.Duration = 0
    spawnLocation.Color = SHRINE_COLOR
    spawnLocation.Material = Enum.Material.Marble
    spawnLocation.Parent = geometry

    buildShrine(geometry)
    buildCave(geometry)

    local pens = buildPens(folder)

    local gemSpawnPoints = generateGemSpawnPoints(rng, function(candidate: Vector3): boolean
        if Util.distanceXZ(candidate, shrine) < Config.World.SHRINE_PAD_RADIUS + 12 then
            return true
        end
        if insideCaveShell(caveCenter, caveSize, candidate) then
            return true
        end
        for _, pen in ipairs(pens) do
            if Util.distanceXZ(candidate, pen.center) < PEN_PAD_RADIUS + 6 then
                return true
            end
        end
        return false
    end)

    local spawnFolder = Instance.new("Folder")
    spawnFolder.Name = "GemSpawns"
    spawnFolder.Parent = folder
    for index, position in ipairs(gemSpawnPoints) do
        makePart({
            name = tostring(index),
            size = Vector3.new(0.8, 0.8, 0.8),
            position = position,
            color = Color3.fromRGB(255, 255, 255),
            material = Enum.Material.Neon,
            transparency = 1,
            canCollide = false,
            castShadow = false,
            parent = spawnFolder,
        })
    end

    scatterProps(geometry, rng, gemSpawnPoints, pens, shrine, caveCenter, caveSize)

    return {
        folder = folder,
        gemSpawnPoints = gemSpawnPoints,
        pens = pens,
        shrineCenter = shrine,
    }
end

return WorldBuilder
