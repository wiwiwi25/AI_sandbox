--!strict
--[[
    CursedGems :: CurseSystem
    ------------------------------------------------------------------
    The clock. Gems are not only currency here, they are the life meter: they
    drain continuously, and the drain rises with every creature a player owns.

    The whole rate, in one place - BASE + creatures * UPKEEP, halved below the
    mercy threshold, quartered inside the shrine, and switched off entirely
    during spawn grace.

    Three deliberate anti-frustration choices:
      * No periodic damage when the meter empties. Timer-death reads as unfair,
        and the curse already communicates itself through movement speed and a
        HUD that is visibly running down.
      * The shrine is a safe zone. It is a panic button that needs no
        explanation, and it doubles as the social hub.
      * Mercy. Below a handful of gems the drain halves, so a player is never
        in a spiral they cannot read their way out of. Gems stop at zero and
        never go negative.

    Grace is skipped, not merely reduced, so the first minute of play is
    unconditionally safe.

    cursedSeconds is a STAT, not currency. It is flushed on the next autosave
    instead of marking dirty every tick, because losing a few seconds of a
    career counter to a crash is not worth a write mark per second per player.

    A server hitch must not be charged to the player either, which is why the
    elapsed delta is clamped before it is billed.
]]

local Players = game:GetService("Players")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local Util = Shared.Util
local Remotes = Shared.Remotes
local PlayerDataService = require(script.Parent.PlayerDataService)

local CurseSystem = {}

local TICK_SECONDS = 1

local shrineCenter = Config.World.SHRINE_POSITION
local lastWarnLevel: { [Player]: number } = {}
local cursedState: { [Player]: boolean } = {}
local running = false

-- Highest warning tier the balance is currently under. WARN_AT is authored
-- descending, so the last threshold crossed wins.
local function warnLevel(gems: number): number
    local level = 0
    for index, threshold in ipairs(Config.Curse.WARN_AT) do
        if gems <= threshold then
            level = index
        end
    end
    return level
end

local function rootPosition(player: Player): Vector3?
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        return root.Position
    end
    return nil
end

-- Gems per minute after every multiplier. Exported because the HUD displays
-- it: a drain the player cannot see is a drain that feels arbitrary.
local function currentRatePerMinute(player: Player): number
    local rate = PlayerDataService.getUpkeepPerMinute(player)

    if PlayerDataService.getGems(player) < Config.Economy.MERCY_THRESHOLD then
        rate *= Config.Economy.MERCY_MULTIPLIER
    end

    local position = rootPosition(player)
    if
        position
        and Util.distanceXZ(position, shrineCenter) <= Config.Economy.SHRINE_SAFE_RADIUS
    then
        rate *= Config.Economy.SHRINE_DECAY_MULTIPLIER
    end

    return rate
end

local function applyMovement(player: Player, cursed: boolean)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return
    end

    -- JumpPower is only honoured while the humanoid is in Power mode, so the
    -- mode is switched first; otherwise the write below is silently ignored.
    if not humanoid.UseJumpPower then
        humanoid.UseJumpPower = true
    end

    local walkSpeed = cursed and Config.Curse.CURSED_WALK_SPEED or Config.Curse.NORMAL_WALK_SPEED
    local jumpPower = cursed and Config.Curse.CURSED_JUMP_POWER or Config.Curse.NORMAL_JUMP_POWER

    -- Guarded writes. Unexplained writes every tick would fight any other
    -- system that also wants a say in how fast a player moves.
    if humanoid.WalkSpeed ~= walkSpeed then
        humanoid.WalkSpeed = walkSpeed
    end
    if humanoid.JumpPower ~= jumpPower then
        humanoid.JumpPower = jumpPower
    end
end

local function updateCurseState(player: Player, gems: number)
    local cursed = gems <= Config.Curse.CLEAR_ABOVE_GEMS
    if cursedState[player] == cursed then
        return
    end

    cursedState[player] = cursed
    applyMovement(player, cursed)

    -- Marked dirty on the TRANSITION only: it carries the cursedSeconds
    -- accumulated since the last one, which would otherwise never be written.
    PlayerDataService.markDirty(player)

    Remotes.Feedback:FireClient(player, {
        kind = "curseChanged",
        cursed = cursed,
        balance = gems,
    })

    if cursed and Config.Debug.LOG_ECONOMY then
        print(string.format("[CursedGems] %s is cursed (0 gems).", player.Name))
    end
end

local function step(delta: number)
    for _, player in ipairs(Players:GetPlayers()) do
        if not PlayerDataService.getSession(player) then
            continue
        end

        if PlayerDataService.getGraceRemaining(player) > 0 then
            continue
        end

        local before = PlayerDataService.getGems(player)
        if before <= 0 then
            -- Nothing left to take, and the curse is already showing through
            -- the movement penalty. All that remains is to count the time.
            PlayerDataService.addCursedSeconds(player, delta)
            updateCurseState(player, 0)
            continue
        end

        local rate = currentRatePerMinute(player)
        local after = PlayerDataService.applyDrain(player, rate / 60 * delta)

        updateCurseState(player, after)

        local level = warnLevel(after)
        local previous = lastWarnLevel[player] or 0
        if level > previous then
            lastWarnLevel[player] = level
            Remotes.Feedback:FireClient(player, {
                kind = "curseWarning",
                level = level,
                balance = after,
                drainPerMinute = rate,
            })
        elseif level < previous then
            -- Recovered back above a threshold. Reset silently, so a player who
            -- hovers on the line is not warned over and over.
            lastWarnLevel[player] = level
        end
    end
end

local function bindCharacter(player: Player)
    player.CharacterAdded:Connect(function()
        -- Deferred, because the default character scripts are still finishing
        -- at this moment and would overwrite the penalty a frame later.
        task.defer(function()
            applyMovement(player, cursedState[player] == true)
        end)
    end)
end

function CurseSystem.start(center: Vector3)
    if running then
        return
    end
    running = true
    shrineCenter = center

    for _, player in ipairs(Players:GetPlayers()) do
        bindCharacter(player)
    end
    Players.PlayerAdded:Connect(bindCharacter)
    Players.PlayerRemoving:Connect(function(player: Player)
        lastWarnLevel[player] = nil
        cursedState[player] = nil
    end)

    task.spawn(function()
        local last = os.clock()
        while running do
            task.wait(TICK_SECONDS)
            local now = os.clock()
            -- Clamped: a server hitch must never be billed to the player as
            -- several minutes of drain in one tick.
            local delta = math.min(now - last, TICK_SECONDS * 3)
            last = now
            step(delta)
        end
    end)

    print(
        string.format(
            "[CursedGems] CurseSystem online: base drain %d/min, %.1f per creature.",
            Config.Economy.BASE_DECAY_PER_MINUTE,
            Config.Economy.UPKEEP_PER_CREATURE_PER_MINUTE
        )
    )
end

function CurseSystem.stop()
    running = false
end

function CurseSystem.isCursed(player: Player): boolean
    return PlayerDataService.getGems(player) <= Config.Curse.CLEAR_ABOVE_GEMS
end

CurseSystem.currentRatePerMinute = currentRatePerMinute

return CurseSystem
