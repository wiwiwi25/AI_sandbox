--!strict
--[[
    CursedGems :: SpinFx (client)
    ------------------------------------------------------------------
    One animation loop for every cosmetic that turns in place: the gems in the
    field, and the marker rings on the summon altars.

    Three decisions worth stating:

      * Every tracked object runs off ONE Heartbeat callback, however many of
        them exist. The cost is N CFrame writes per frame and a single closure,
        which is what keeps this affordable as the gem pool grows.

      * The origin CFrame is captured on the first frame AFTER an instance is
        visible, not inside the tag signal. The server position replicates, so
        an instance can exist for a frame without its true CFrame; capturing it
        inside the signal would anchor the animation to (0, 0, 0).

      * Each frame is rebuilt from that single captured origin, so rotation and
        bob cannot accumulate floating-point drift - the classic bug where a
        long-running spinner slowly slides off its own axis.

    Purely visual. Nothing here is ever read back by gameplay.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local SpinFx = {}

type Entry = {
    origin: CFrame?,
    angle: number,
    phase: number,
}

type Track = {
    entries: { [BasePart]: Entry },
    spin: number,
    bobHeight: number,
    bobSpeed: number,
}

local tracks: { [string]: Track } = {}
local bound: { [string]: boolean } = {}
local running = false

local function phaseFor(position: Vector3): number
    -- Deterministic from world position, so neighbours never bob in lockstep and
    -- the pattern is identical every time an object respawns on that spot.
    return (position.X * 0.7 + position.Z * 1.3) % (math.pi * 2)
end

local function step(clock: number, delta: number)
    for _, track in pairs(tracks) do
        for instance, entry in pairs(track.entries) do
            if not instance.Parent then
                track.entries[instance] = nil
                continue
            end

            local origin = entry.origin
            if origin == nil then
                -- First visible frame: the replicated CFrame is authoritative now.
                origin = instance.CFrame
                entry.origin = origin
                entry.phase = phaseFor(instance.Position)
            end

            entry.angle += delta * track.spin
            local bob = math.sin(clock * track.bobSpeed + entry.phase) * track.bobHeight
            -- Cast rather than re-test: the branch above guarantees a CFrame, and
            -- the alias keeps the arithmetic below readable.
            local base: CFrame = origin :: CFrame
            instance.CFrame = base * CFrame.Angles(0, entry.angle, 0) + Vector3.new(0, bob, 0)
        end
    end
end

function SpinFx.track(tagName: string, spin: number, bobHeight: number, bobSpeed: number)
    local track = tracks[tagName]
    if track then
        track.spin, track.bobHeight, track.bobSpeed = spin, bobHeight, bobSpeed
    else
        track = { entries = {}, spin = spin, bobHeight = bobHeight, bobSpeed = bobSpeed }
        tracks[tagName] = track
    end

    if bound[tagName] then
        return
    end
    bound[tagName] = true

    local function add(instance: Instance)
        if instance:IsA("BasePart") then
            track.entries[instance] = { origin = nil, angle = 0, phase = 0 }
        end
    end

    for _, instance in ipairs(CollectionService:GetTagged(tagName)) do
        add(instance)
    end
    CollectionService:GetInstanceAddedSignal(tagName):Connect(add)
    CollectionService:GetInstanceRemovedSignal(tagName):Connect(function(instance: Instance)
        if instance:IsA("BasePart") then
            track.entries[instance] = nil
        end
    end)
end

function SpinFx.start()
    if running then
        return
    end
    running = true

    local clock = 0
    RunService.Heartbeat:Connect(function(delta: number)
        -- Clamped, or a single long stall would snap every tracked object
        -- through a huge rotation in one frame.
        delta = math.min(delta, 0.25)
        clock += delta
        step(clock, delta)
    end)
end

function SpinFx.count(): number
    local total = 0
    for _, track in pairs(tracks) do
        for _ in pairs(track.entries) do
            total += 1
        end
    end
    return total
end

return SpinFx
