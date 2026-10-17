--!strict
--[[
    CursedGems :: CreatureFactory
    ------------------------------------------------------------------
    Turns a CreatureDef (pure data) into a real Model.

    Shared on purpose: the SERVER builds the authoritative creature that follows
    its owner, and the CLIENT needs the identical construction for the summon
    reveal and the collection grid. One builder means the thing the player is
    shown is built by the same code as the thing that exists.

    NOTE ON REQUIRE DIRECTION: this module requires its siblings directly and
    must never require Modules.luau, because Modules.luau requires THIS file.
    A cycle would fail at require time, in the live server, with no warning at
    edit time - so the direction is documented rather than remembered.

    Construction rules that matter at runtime:
      * Every part is Anchored. Creatures are positioned by setting one CFrame
        on the model, so they cost zero physics. That is what keeps a large
        collection affordable.
      * CanCollide/CanQuery/CanTouch are all false, so a pet can never push the
        player or intercept a gem prompt.
]]

local Util = require(script.Parent.Util)
local CreatureCatalog = require(script.Parent.CreatureCatalog)

local CreatureFactory = {}

export type CreatureDef = CreatureCatalog.CreatureDef
export type PartSpec = CreatureCatalog.PartSpec

-- Wedges need a different CLASS, not just a different Shape enum, so the two
-- lookups are kept separate on purpose.
local SHAPE_CLASS: { [string]: string } = {
    Ball = "Part",
    Block = "Part",
    Cylinder = "Part",
    Wedge = "WedgePart",
}

local SHAPE_PART_TYPE: { [string]: Enum.PartType } = {
    Ball = Enum.PartType.Ball,
    Block = Enum.PartType.Block,
    Cylinder = Enum.PartType.Cylinder,
}

local function buildPart(spec: PartSpec, parent: Instance): BasePart
    local className = SHAPE_CLASS[spec.shape] or "Part"
    local instance = Instance.new(className) :: BasePart

    instance.Name = spec.name
    instance.Size = spec.size
    instance.Anchored = true
    instance.CanCollide = false
    instance.CanQuery = false
    instance.CanTouch = false
    instance.CastShadow = false
    instance.Color = spec.color
    instance.Material = spec.material
    instance.Transparency = spec.transparency or 0

    if className == "Part" then
        local part = instance :: Part
        part.Shape = SHAPE_PART_TYPE[spec.shape] or Enum.PartType.Block
        part.Massless = true
    end

    local rotation = spec.rotation or Vector3.zero
    instance.CFrame = CFrame.new(spec.offset)
        * CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
    instance.Parent = parent

    local glow = spec.glow
    if glow then
        local light = Instance.new("PointLight")
        light.Color = glow.color
        light.Range = glow.range
        light.Brightness = glow.brightness
        light.Shadows = false
        light.Parent = instance
    end

    return instance
end

function CreatureFactory.build(def: CreatureDef, parent: Instance?): Model
    local model = Instance.new("Model")
    model.Name = def.id

    for _, spec in ipairs(def.parts) do
        buildPart(spec, model)
    end

    -- PrimaryPart is what lets a single PivotTo move the whole creature.
    local firstSpec = def.parts[1]
    if firstSpec then
        local primary = model:FindFirstChild(firstSpec.name)
        if primary and primary:IsA("BasePart") then
            model.PrimaryPart = primary
        end
    end

    model.Parent = parent
    return model
end

-- Keeps the model pivot on the ground contact point so every caller can place a
-- creature with one CFrame and get consistent results for all five creatures.
function CreatureFactory.pivotCFrame(def: CreatureDef, ground: Vector3, facing: Vector3): CFrame
    local look = Vector3.new(facing.X, 0, facing.Z)
    if look.Magnitude < 0.001 then
        look = Vector3.new(0, 0, -1)
    end
    local position = Vector3.new(ground.X, ground.Y + def.anchorHeight, ground.Z)
    return CFrame.lookAt(position, position + look.Unit)
end

function CreatureFactory.highestPoint(def: CreatureDef): number
    local highest = 0
    for _, spec in ipairs(def.parts) do
        highest = math.max(highest, spec.offset.Y + spec.size.Y * 0.5)
    end
    return Util.round(highest, 2)
end

return CreatureFactory
