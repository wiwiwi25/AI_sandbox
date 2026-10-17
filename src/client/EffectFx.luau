--!strict
--[[
    CursedGems :: EffectFx (client)
    ------------------------------------------------------------------
    World-space feedback: the pop when a gem is taken, and the reveal when
    somebody summons.

    Design notes:

      * Everything is created CLIENT-SIDE and locally. The server never sends an
        effect object down the wire; it sends a small event and each client
        builds the same thing from the same catalog. A cosmetic that exists for
        two seconds does not deserve replication.

      * Reveals are capped. Several players summoning in the same pen field is
        exactly the social moment the game is built around, but several creature
        models per altar at once is visual noise and wasted geometry, so past
        the cap the client plays the flash and skips the model.

      * The reveal model comes from CreatureFactory - the SAME factory the
        server uses for its followers - so what a witness sees is what the
        summoner actually owns rather than an approximation built for the
        occasion.

      * No assets: geometry, material and a tween. Nothing here can fail to load.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local Util = Shared.Util
local CreatureCatalog = Shared.CreatureCatalog
local CreatureFactory = Shared.CreatureFactory
local Remotes = Shared.Remotes
local Theme = require(script.Parent.Theme)

local EffectFx = {}

local localPlayer = Players.LocalPlayer

-- Beyond this many overlapping reveals, extra ones degrade to the flash.
local MAX_CONCURRENT_REVEALS = 2
local REVEAL_SPIN_DEGREES = 720
local REVEAL_RISE_STUDS = 3

local fxFolder: Folder? = nil
local reveals = 0

local function container(): Folder
    local existing = fxFolder
    if existing and existing.Parent then
        return existing
    end
    local created = Instance.new("Folder")
    created.Name = "CursedGemsFx"
    created.Parent = workspace
    fxFolder = created
    return created
end

-- A one-shot neon sphere, used for both the gem pop and the summon flash. One
-- gesture at two sizes reads as a single consistent visual language, and it
-- costs exactly one tweened, anchored, non-collidable part.
local function burst(position: Vector3, color: Color3, size: number, seconds: number)
    local part = Instance.new("Part")
    part.Name = "CursedGemsBurst"
    part.Shape = Enum.PartType.Ball
    part.Size = Vector3.new(size * 0.35, size * 0.35, size * 0.35)
    part.CFrame = CFrame.new(position)
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.Material = Enum.Material.Neon
    part.Color = color
    part.Transparency = 0.15
    part.Parent = container()

    TweenService:Create(
        part,
        TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Size = Vector3.new(size, size, size), Transparency = 1 }
    ):Play()

    task.delay(seconds + 0.1, function()
        part:Destroy()
    end)
end

-- Which way a revealed creature should look: at whoever is watching. One that
-- spawns facing away reads as a bug even when it is genuinely just standing
-- there.
local function facingTowards(position: Vector3): Vector3
    local character = localPlayer.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        local flat = Vector3.new(root.Position.X - position.X, 0, root.Position.Z - position.Z)
        if flat.Magnitude > 0.1 then
            return flat.Unit
        end
    end
    return Vector3.new(0, 0, 1)
end

-- A cursed gem is worth strictly more than a normal one, and that value gap is
-- exactly what the pop communicates - so the pop is derived from Config rather
-- than from a second table of colour constants that could drift away from it.
local function gemPop(position: Vector3, value: number)
    local cursed = Config.Gems.CURSED_VALUE > Config.Gems.COMMON_VALUE
        and value >= Config.Gems.CURSED_VALUE
    if cursed then
        burst(position, Theme.Color.curse, 9, 0.5)
    else
        burst(position, Theme.Color.accent, 5, 0.32)
    end
end

local function reveal(creatureId: string, position: Vector3, accent: Color3, seconds: number)
    burst(position, accent, 16, seconds * 0.5)

    local def = CreatureCatalog.get(creatureId)
    if def == nil or reveals >= MAX_CONCURRENT_REVEALS then
        return
    end

    reveals += 1
    local model = CreatureFactory.build(def, container())
    local ground = Vector3.new(position.X, position.Y, position.Z)
    local origin = CreatureFactory.pivotCFrame(def, ground, facingTowards(position))
    model:PivotTo(origin)

    local part = model:FindFirstChildWhichIsA("BasePart")
    if part then
        local light = Instance.new("PointLight")
        light.Color = accent
        light.Brightness = 3
        light.Range = 26
        light.Parent = part
    end

    -- Rise and spin, then vanish. PivotTo on an anchored model: no physics, no
    -- collision, and nothing for the server to replicate.
    task.spawn(function()
        local startedAt = os.clock()
        while true do
            local elapsed = os.clock() - startedAt
            if elapsed >= seconds then
                break
            end
            local t = elapsed / seconds
            local angle = math.rad(REVEAL_SPIN_DEGREES) * t
            local rise = math.sin(t * math.pi) * REVEAL_RISE_STUDS
            model:PivotTo(origin * CFrame.Angles(0, angle, 0) + Vector3.new(0, rise, 0))
            task.wait()
        end
        model:Destroy()
        reveals -= 1
    end)
end

local function handle(payload: any)
    if type(payload) ~= "table" then
        return
    end

    local position = payload.position
    if typeof(position) ~= "Vector3" then
        return
    end

    if payload.kind == "gemCollected" then
        if Util.isFiniteNumber(payload.value) then
            gemPop(position, payload.value)
        end
        return
    end

    -- Summoner and witness get identical treatment on purpose: several players
    -- watching one reveal is the entire point of a shared altar field.
    if payload.kind == "summonReveal" or payload.kind == "witnessSummon" then
        if type(payload.creatureId) ~= "string" then
            return
        end

        local accent: Color3 = Theme.Color.accent
        if typeof(payload.accent) == "Color3" then
            accent = payload.accent
        end

        local seconds: number = Config.Summon.REVEAL_SECONDS
        if Util.isFiniteNumber(payload.revealSeconds) then
            seconds = math.clamp(payload.revealSeconds, 0.5, 6)
        end

        reveal(payload.creatureId, position, accent, seconds)
    end
end

function EffectFx.start()
    Remotes.Feedback.OnClientEvent:Connect(handle)
end

return EffectFx
