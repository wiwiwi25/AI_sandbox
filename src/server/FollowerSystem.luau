--!strict
--[[
    CursedGems :: FollowerSystem
    ------------------------------------------------------------------
    Moves the visible creatures that trail each player.

    The single most important decision in this file: followers are ANCHORED and
    positioned with PivotTo from the server. A creature that is unanchored, or
    that carries a Humanoid, costs physics and AI every frame, forever, for
    every player. Anchored plus one CFrame write each is effectively free, and
    it is the reason a player can own a growing collection at all.

    Followers sit on the world ground plane and track the player in XZ only.
    That is exactly correct here, because the map is flat by construction, and
    it costs zero raycasts. Note for a future phase: the moment terrain exists,
    this line becomes a downward raycast.

    Rebuilds are signature driven. The set of visible creatures only changes
    when the collection changes, so the common tick does nothing but move parts.

    LERP_ALPHA is authored as a per-frame factor at 60 fps and rescaled to the
    real update rate, so the chase looks identical on a 30 fps and a 240 fps
    client instead of being frame-rate dependent.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local CreatureCatalog = Shared.CreatureCatalog
local CreatureFactory = Shared.CreatureFactory
local PlayerDataService = require(script.Parent.PlayerDataService)

local FollowerSystem = {}

local INTERVAL = 1 / Config.Follower.UPDATE_HZ

-- Per-frame alpha authored at 60 fps, rescaled to whatever rate we actually run.
local ALPHA = 1 - (1 - Config.Follower.LERP_ALPHA) ^ (INTERVAL * 60)

type Slot = {
    model: Model,
    creatureId: string,
    position: CFrame,
}

type PlayerFollowers = {
    signature: string,
    slots: { Slot },
}

export type Stats = {
    trackedPlayers: number,
    visibleCreatures: number,
}

local followersFolder = Instance.new("Folder")
followersFolder.Name = "Followers"

local followers: { [Player]: PlayerFollowers } = {}
local accumulator = 0
local running = false

-- Newest first, capped at what we are willing to render.
local function newestIds(player: Player): { string }
    local creatures = PlayerDataService.getCreatures(player)
    local ids: { string } = {}
    local limit = Config.Follower.MAX_VISIBLE_FOLLOWERS
    for index = #creatures, math.max(1, #creatures - limit + 1), -1 do
        local entry = creatures[index]
        if entry then
            table.insert(ids, entry.id)
        end
    end
    return ids
end

local function destroySlots(state: PlayerFollowers)
    for _, slot in ipairs(state.slots) do
        slot.model:Destroy()
    end
    table.clear(state.slots)
end

local function rebuild(state: PlayerFollowers, ids: { string })
    destroySlots(state)
    for _, creatureId in ipairs(ids) do
        local def = CreatureCatalog.get(creatureId)
        if def then
            table.insert(state.slots, {
                model = CreatureFactory.build(def, followersFolder),
                creatureId = creatureId,
                -- Starts far below the map so the first lerp does not drag the
                -- creature across the world in front of the player.
                position = CFrame.new(0, -500, 0),
            })
        end
    end
end

local function step()
    for _, player in ipairs(Players:GetPlayers()) do
        local session = PlayerDataService.getSession(player)
        if not session then
            continue
        end

        local state = followers[player]
        if not state then
            state = { signature = "", slots = {} }
            followers[player] = state
        end

        local ids = newestIds(player)
        local signature = table.concat(ids, "|")
        if signature ~= state.signature then
            rebuild(state, ids)
            state.signature = signature
        end

        if #state.slots == 0 then
            continue
        end

        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root or not root:IsA("BasePart") then
            continue
        end

        local look = root.CFrame.LookVector
        local groundY = Config.World.GROUND_Y

        for slotIndex, slot in ipairs(state.slots) do
            local def = CreatureCatalog.get(slot.creatureId)
            if not def then
                continue
            end

            local back = Config.Follower.FOLLOW_DISTANCE * slotIndex
            local side = Config.Follower.TRAIL_SIDE_OFFSET * (1 - (slotIndex % 2) * 2)
            local offset = root.CFrame * Vector3.new(side, 0, -back)
            local ground = Vector3.new(offset.X, groundY, offset.Z)

            local target = CreatureFactory.pivotCFrame(def, ground, look)
            slot.position = slot.position:Lerp(target, ALPHA)
            slot.model:PivotTo(slot.position)
        end
    end
end

local function forget(player: Player)
    local state = followers[player]
    if not state then
        return
    end
    destroySlots(state)
    followers[player] = nil
end

function FollowerSystem.start()
    if running then
        return
    end
    running = true

    followersFolder.Parent = Workspace
    Players.PlayerRemoving:Connect(forget)

    RunService.Heartbeat:Connect(function(delta: number)
        if not running then
            return
        end
        accumulator += delta
        if accumulator < INTERVAL then
            return
        end
        accumulator -= INTERVAL
        -- After a long hitch, do not burst through a backlog of catch-up frames.
        if accumulator > INTERVAL * 4 then
            accumulator = 0
        end
        step()
    end)
end

function FollowerSystem.stop()
    running = false
end

function FollowerSystem.getStats(): Stats
    local visible = 0
    for _, state in pairs(followers) do
        visible += #state.slots
    end
    local tracked = 0
    for _ in pairs(followers) do
        tracked += 1
    end
    return { trackedPlayers = tracked, visibleCreatures = visible }
end

return FollowerSystem
