--!strict
--[[
    CursedGems :: GemSystem
    ------------------------------------------------------------------
    Owns every gem in the world: placement, respawn, prompting and the
    authoritative collection check.

    The security model, in one paragraph: the ProximityPrompt on a gem is a
    REQUEST, not a permission. A modified client can fire PromptTriggered from
    anywhere on the map. So the handler re-measures the distance between the
    player character and the gem on the SERVER, and only then pays out. The
    client-side activation distance is deliberately set STRICTER than the
    server limit, so a legitimate player is never rejected while a spoofed
    trigger from across the map is.

    Placement is cheap by design. MIN_GEM_SPACING is enforced ONCE, at world
    build time, over the fixed list of legal positions. That turns runtime
    placement into an index pick instead of an O(n^2) rejection loop, and it
    guarantees two gems are never crowded together, which is the bug such a
    loop usually hides.

    Those legal positions now live in four pockets (Config.World.GEM_ZONES).
    Respawn is deliberately NOT bound to a zone: a zone that refilled itself
    would make standing still the best income in the game. The draw below is
    uniform over all four, which is what keeps movement mandatory.

    Gems are pooled. The pool holds the Part, its PointLight and its
    ProximityPrompt; acquiring one only re-colours it for the rolled kind. A
    pick-up reserves that index for 8-12 s before it is legal again, so a
    collected gem genuinely leaves the field while turnover still costs zero
    instances.

    The Pool handle below is created at module scope with no type annotation on
    purpose: its type is inferred from Pool.new, which is what lets the module
    avoid naming a shared type at all.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local Util = Shared.Util
local Pool = Shared.Pool
local Remotes = Shared.Remotes
local PlayerDataService = require(script.Parent.PlayerDataService)

-- Required directly, in addition to the value available from the package, only
-- so that the exported TYPE below resolves. Luau can reach a module exported
-- type exclusively through a local bound straight to require().
local GemCatalog = require(
    game:GetService("ReplicatedStorage"):WaitForChild("CursedGems"):WaitForChild("GemCatalog")
)
export type GemKind = GemCatalog.GemKind

local GemSystem = {}

local GEM_TAG = Config.Tags.GEM
local ATTRIBUTE_KIND = "GemKindId"

local CURSED_KIND_ID = "Cursed"

export type GemRecord = {
    index: number,
    kindId: string,
    acquiredAt: number,
}

export type PendingRespawn = {
    index: number,
    at: number,
}

local gemsFolder = Instance.new("Folder")
gemsFolder.Name = "ActiveGems"

local spawnPoints: { Vector3 } = {}
local activeByPart: { [BasePart]: GemRecord } = {}
local occupiedIndices: { [number]: boolean } = {}
-- Indices whose gem was just collected and which are serving their respawn
-- delay. Kept separate from occupiedIndices because a cooling index is neither
-- "has a gem" nor "free to take": it is reserved to the gem that was there.
local coolingIndices: { [number]: boolean } = {}
local pendingRespawn: { PendingRespawn } = {}
local lastCollectAt: { [Player]: number } = {}
local rng = Random.new(Config.World.SEED + 991)
local running = false

local function buildGemPart(): Instance
    local part = Instance.new("Part")
    part.Name = "Gem"
    part.Shape = Enum.PartType.Ball
    part.Size = Vector3.new(1.6, 1.6, 1.6)
    part.Anchored = true
    part.CanCollide = false
    -- Query off means a gem never blocks another system raycast, and it also
    -- keeps the prompt from being occluded by the gem it belongs to.
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false

    local light = Instance.new("PointLight")
    light.Shadows = false
    light.Enabled = false
    light.Parent = part

    local sparkle = Instance.new("ParticleEmitter")
    sparkle.Name = "Sparkle"
    sparkle.Rate = 16
    sparkle.Lifetime = NumberRange.new(0.65)
    sparkle.Speed = NumberRange.new(1.2)
    sparkle.SpreadAngle = Vector2.new(180, 180)
    sparkle.Size = NumberSequence.new(0.4)
    sparkle.LightEmission = 0.8
    sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
    sparkle.Enabled = false
    sparkle.Parent = part

    local prompt = Instance.new("ProximityPrompt")
    prompt.ActionText = "Collect"
    prompt.ObjectText = "Gem"
    prompt.HoldDuration = Config.Gems.PROMPT_HOLD_SECONDS
    prompt.MaxActivationDistance = Config.Gems.PROMPT_MAX_DISTANCE
    -- A gem inside a tree canopy must still be collectable. Line of sight adds
    -- nothing here because the server distance check is the real gate.
    prompt.RequiresLineOfSight = false
    prompt.Parent = part

    return part
end

local gemPool = Pool.new(buildGemPart, gemsFolder)

local function configureGem(part: BasePart, kind: GemKind)
    part.Color = kind.color
    part.Material = kind.material
    part.Transparency = 0.04
    part.Size = Vector3.new(1.6, 1.6, 1.6)

    local light = part:FindFirstChildOfClass("PointLight")
    if light then
        light.Color = kind.lightColor or kind.color
        light.Range = kind.lightRange or 8
        light.Brightness = kind.lightBrightness or 0
        light.Enabled = kind.lightColor ~= nil
    end

    local prompt = part:FindFirstChildOfClass("ProximityPrompt")
    if prompt then
        prompt.ObjectText = kind.displayName
    end

    local sparkle = part:FindFirstChild("Sparkle")
    if sparkle and sparkle:IsA("ParticleEmitter") then
        sparkle.Enabled = kind.sparkle
        sparkle.Color = ColorSequence.new(kind.color)
    end
end

local function targetPoolSize(): number
    local desired = Config.Gems.POOL_BASE + Config.Gems.POOL_PER_PLAYER * #Players:GetPlayers()
    desired = math.clamp(desired, Config.Gems.POOL_MIN, Config.Gems.POOL_MAX)
    return math.min(desired, #spawnPoints)
end

local function activeCount(): number
    local count = 0
    for _ in pairs(activeByPart) do
        count += 1
    end
    return count
end

local function spawnAt(index: number)
    local position = spawnPoints[index]
    if not position or occupiedIndices[index] then
        return
    end

    local kind = GemCatalog.roll(rng)
    local part = gemPool:acquire() :: BasePart

    configureGem(part, kind)
    part.CFrame = CFrame.new(position)
    part:SetAttribute(ATTRIBUTE_KIND, kind.id)
    part.Parent = gemsFolder
    CollectionService:AddTag(part, GEM_TAG)

    activeByPart[part] = { index = index, kindId = kind.id, acquiredAt = os.clock() }
    occupiedIndices[index] = true
    coolingIndices[index] = nil
end

-- `respawnDelay` nil retires the slot for good (the bulk shrink when players
-- leave). A number reserves the index for that long, which is the entire
-- feature: without the reservation the sweep below sees "the pool is short" and
-- refills from some other point on its next tick, which is indistinguishable
-- from the gem respawning instantly. That was the reported bug.
local function despawn(part: BasePart, respawnDelay: number?)
    local record = activeByPart[part]
    if not record then
        return
    end

    activeByPart[part] = nil
    occupiedIndices[record.index] = nil
    part:SetAttribute(ATTRIBUTE_KIND, nil)
    CollectionService:RemoveTag(part, GEM_TAG)
    gemPool:release(part)

    if respawnDelay then
        coolingIndices[record.index] = true
        table.insert(pendingRespawn, { index = record.index, at = os.clock() + respawnDelay })
    end
end

local function pickIndex(): number?
    local free: { number } = {}
    for index = 1, #spawnPoints do
        -- A cooling index belongs to the gem that was just collected. Handing it
        -- out again would let a different gem appear in the same spot and hide
        -- the delay entirely.
        if not occupiedIndices[index] and not coolingIndices[index] then
            table.insert(free, index)
        end
    end
    if #free == 0 then
        return nil
    end

    Util.shuffle(free, rng)

    local positions: { Vector3 } = {}
    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if root and root:IsA("BasePart") then
            table.insert(positions, root.Position)
        end
    end

    if #positions == 0 then
        return free[1]
    end

    local fallback: number? = nil
    for _, index in ipairs(free) do
        local candidate = spawnPoints[index]
        local tooClose = false
        for _, position in ipairs(positions) do
            if
                Util.distanceXZ(candidate, position) < Config.Gems.MIN_SPAWN_DISTANCE_FROM_PLAYER
            then
                tooClose = true
                break
            end
        end
        if not tooClose then
            return index
        end
        fallback = fallback or index
    end

    -- A crowded server can block every legal point at once. Starving the field
    -- would be worse than spawning in view, so take the least bad option.
    return fallback
end

local function processPendingRespawns()
    local now = os.clock()
    local target = targetPoolSize()
    local index = 1
    while index <= #pendingRespawn do
        local entry = pendingRespawn[index]
        if entry.at <= now then
            -- Refill only if the field still wants a gem; a server that emptied
            -- out while this one was cooling would otherwise overfill. Either
            -- way the reservation ends here, so the queue cannot leak entries
            -- that will never fire.
            if activeCount() < target then
                spawnAt(entry.index)
            end
            coolingIndices[entry.index] = nil
            table.remove(pendingRespawn, index)
        else
            index += 1
        end
    end
end

local function reconcile()
    local target = targetPoolSize()
    local count = activeCount()

    if count > target then
        local parts: { BasePart } = {}
        for part in pairs(activeByPart) do
            table.insert(parts, part)
        end
        -- Retire the most recently placed gems first, so the ones a player has
        -- been looking at all session stay put and the field does not reshuffle
        -- every time somebody joins.
        table.sort(parts, function(a: BasePart, b: BasePart): boolean
            local recordA = activeByPart[a]
            local recordB = activeByPart[b]
            local timeA = recordA and recordA.acquiredAt or 0
            local timeB = recordB and recordB.acquiredAt or 0
            return timeA > timeB
        end)
        for _, part in ipairs(parts) do
            if count <= target then
                break
            end
            -- No delay: this is a retire, not a pick-up. Reserving the slot here
            -- would put a gem straight back and undo the shrink.
            despawn(part)
            count -= 1
        end
        return
    end

    if count < target then
        -- Pending respawns are gems already owed to the field. Counting them is
        -- the difference between "the pool is short" and "the pool is waiting",
        -- and only a genuinely short pool may spawn outside the queue.
        local deficit = target - count - #pendingRespawn
        for _ = 1, deficit do
            local index = pickIndex()
            if not index then
                break
            end
            spawnAt(index)
        end
    end
end

local function handleTriggered(prompt: ProximityPrompt, player: Player)
    local part = prompt.Parent
    if not part or not part:IsA("BasePart") then
        return
    end

    local record = activeByPart[part]
    if not record then
        return
    end

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or not root:IsA("BasePart") then
        return
    end

    -- THE REAL GATE. Everything above is bookkeeping; this is the line that
    -- decides whether a client we do not trust actually gets paid.
    local maxDistance = Config.Gems.COLLECT_RADIUS + Config.Net.MAX_POSITION_SLACK
    if (root.Position - part.Position).Magnitude > maxDistance then
        return
    end

    local now = os.clock()
    local previous = lastCollectAt[player]
    if previous and now - previous < Config.Net.MIN_SECONDS_BETWEEN_COLLECTS then
        return
    end

    local kind = GemCatalog.get(record.kindId)
    if not kind then
        return
    end

    lastCollectAt[player] = now

    local position = part.Position
    local isCursed = kind.id == CURSED_KIND_ID
    local balance = PlayerDataService.recordPickup(player, kind.value, isCursed)
    local delay = rng:NextNumber(Config.Gems.RESPAWN_MIN_SECONDS, Config.Gems.RESPAWN_MAX_SECONDS)

    despawn(part, delay)

    -- Cosmetic only. The HUD balance comes from StateSync; this just tells the
    -- client that a "+5" pop and a sound are owed.
    Remotes.Feedback:FireClient(player, {
        kind = "gemCollected",
        gemKind = record.kindId,
        value = kind.value,
        balance = balance,
        position = position,
    })
end

local function schedulerLoop()
    while running do
        task.wait(0.5)
        processPendingRespawns()
        reconcile()
    end
end

function GemSystem.start(points: { Vector3 })
    if running then
        return
    end
    running = true

    spawnPoints = points
    gemsFolder.Parent = Workspace

    -- Prewarm only up to the minimum pool. Building the maximum on a one player
    -- server would spend instances on gems nobody can see.
    gemPool:prewarm(math.min(Config.Gems.POOL_MIN, #spawnPoints))

    ProximityPromptService.PromptTriggered:Connect(handleTriggered)

    Players.PlayerRemoving:Connect(function(player: Player)
        lastCollectAt[player] = nil
    end)

    reconcile()
    task.spawn(schedulerLoop)

    print(
        string.format(
            "[CursedGems] GemSystem online: %d legal positions, target pool %d.",
            #spawnPoints,
            targetPoolSize()
        )
    )
end

function GemSystem.stop()
    running = false
end

function GemSystem.getStats()
    return {
        spawnPoints = #spawnPoints,
        active = activeCount(),
        pending = #pendingRespawn,
        target = targetPoolSize(),
    }
end

-- Used by the debug tool and by tests: force a respawn sweep right now instead
-- of waiting for the next half second tick.
function GemSystem.forceReconcile()
    processPendingRespawns()
    reconcile()
end

return GemSystem
