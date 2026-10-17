--!strict
--[[
    CursedGems :: SummonSystem
    ------------------------------------------------------------------
    The summoning pens: the only place a player converts gems into a creature.

    The loop this file closes: gems drain continuously, and every creature a
    player owns raises that drain FOREVER (see getUpkeepPerMinute). So the
    purchase below is not a one-off cost, it is a permanent liability. That is
    the whole design - collecting is a difficulty dial, and this is the only
    place the dial turns.

    Note what is deliberately absent: a collection cap. An arbitrary limit is a
    rule the player cannot see the reason for, whereas the upkeep curve is
    legible on the HUD as a drain rate. The curve IS the cap.

    Trust: the cost is re-read from the SERVER session at the instant of the
    spend, so a client that believes it is owed the first-summon discount still
    cannot be charged less than it owes. Position is re-measured server-side as
    well, which is what stops a teleport from bypassing the pad requirement.

    Prompts are per-pen with the binding captured in the closure. Four pens is
    few enough that a direct binding beats a global lookup table, and it means
    the activation path never has to work out WHICH pen was used.
]]

local Players = game:GetService("Players")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local Util = Shared.Util
local CreatureCatalog = Shared.CreatureCatalog
local Remotes = Shared.Remotes
local PlayerDataService = require(script.Parent.PlayerDataService)

-- Sibling require purely for the Pen TYPE. Luau resolves a module exported type
-- only through a local bound straight to require().
local WorldBuilder = require(script.Parent.WorldBuilder)

export type PenBinding = {
    index: number,
    center: Vector3,
    pedestal: Part,
    prompt: ProximityPrompt,
}

local SummonSystem = {}

local bindings: { PenBinding } = {}
local lastSummonAt: { [Player]: number } = {}
local rng = Random.new(Config.World.SEED + 4242)
local running = false

local function handleTriggered(binding: PenBinding, player: Player)
    -- No session means data is still loading or has been torn down. Refuse
    -- rather than mutate a table that is not yet authoritative.
    if not PlayerDataService.getSession(player) then
        return
    end

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or not root:IsA("BasePart") then
        return
    end

    -- Trust nothing but our own measurement of where the player is standing.
    local maxDistance = Config.Summon.INTERACT_RADIUS + Config.Net.MAX_POSITION_SLACK
    if Util.distanceXZ(root.Position, binding.center) > maxDistance then
        return
    end

    local now = os.clock()
    local previous = lastSummonAt[player]
    if previous and now - previous < Config.Summon.ACTION_COOLDOWN_SECONDS then
        return
    end

    local cost = PlayerDataService.getSummonCost(player)
    if not PlayerDataService.spendGems(player, cost) then
        -- A denial deliberately does NOT consume the cooldown. The prompt hold
        -- and the pad requirement already bound how often this can be asked.
        Remotes.Feedback:FireClient(player, {
            kind = "summonDenied",
            reason = "gems",
            cost = cost,
            balance = PlayerDataService.getGems(player),
        })
        return
    end

    lastSummonAt[player] = now

    local def = CreatureCatalog.roll(rng)
    local entry = PlayerDataService.addCreature(player, def.id)
    if not entry then
        -- The session vanished between the spend and the insert. Refund rather
        -- than silently eat the currency.
        PlayerDataService.addGems(player, cost)
        return
    end

    local balance = PlayerDataService.getGems(player)
    local owned = PlayerDataService.creatureCount(player)

    Remotes.Feedback:FireClient(player, {
        kind = "summonReveal",
        penIndex = binding.index,
        position = binding.center,
        cost = cost,
        balance = balance,
        creatureId = def.id,
        displayName = def.displayName,
        rarity = def.rarity,
        accent = def.accentColor,
        revealSeconds = Config.Summon.REVEAL_SECONDS,
        totalCreatures = owned,
    })

    -- Witnesses. The pen field is shared, and a summon nobody sees is a private
    -- spreadsheet event instead of a moment.
    for _, witness in ipairs(Players:GetPlayers()) do
        if witness == player then
            continue
        end
        local witnessCharacter = witness.Character
        local witnessRoot = witnessCharacter and witnessCharacter:FindFirstChild("HumanoidRootPart")
        if
            witnessRoot
            and witnessRoot:IsA("BasePart")
            and Util.distanceXZ(witnessRoot.Position, binding.center)
                <= Config.Summon.BROADCAST_RADIUS
        then
            Remotes.Feedback:FireClient(witness, {
                kind = "witnessSummon",
                penIndex = binding.index,
                -- The id travels as well, so a witness renders the SAME creature
                -- the summoner saw rather than a lookalike.
                creatureId = def.id,
                position = binding.center,
                displayName = def.displayName,
                rarity = def.rarity,
                accent = def.accentColor,
                revealSeconds = Config.Summon.REVEAL_SECONDS,
                playerName = player.DisplayName,
            })
        end
    end

    if Config.Debug.LOG_ECONOMY then
        print(
            string.format(
                "[CursedGems] %s summoned %s for %d gems (balance %d, owning %d, drain %d/min).",
                player.Name,
                def.displayName,
                cost,
                balance,
                owned,
                PlayerDataService.getUpkeepPerMinute(player)
            )
        )
    end
end

local function bindPen(pen: WorldBuilder.Pen): PenBinding
    local prompt = Instance.new("ProximityPrompt")
    prompt.Name = "SummonPrompt"
    prompt.ActionText = "Summon"
    prompt.ObjectText = "Summoning Altar"
    prompt.HoldDuration = Config.Summon.PROMPT_HOLD_SECONDS
    prompt.MaxActivationDistance = Config.Summon.PROMPT_MAX_DISTANCE
    -- The server distance check is the real gate; line of sight would only add
    -- a way for the interaction to mysteriously fail.
    prompt.RequiresLineOfSight = false
    prompt.Parent = pen.pedestal

    local binding: PenBinding = {
        index = pen.index,
        center = pen.center,
        pedestal = pen.pedestal,
        prompt = prompt,
    }

    prompt.Triggered:Connect(function(player: Player)
        handleTriggered(binding, player)
    end)

    return binding
end

function SummonSystem.start(penList: { WorldBuilder.Pen })
    if running then
        return
    end
    running = true

    for _, pen in ipairs(penList) do
        table.insert(bindings, bindPen(pen))
    end

    Players.PlayerRemoving:Connect(function(player: Player)
        lastSummonAt[player] = nil
    end)

    print(string.format("[CursedGems] SummonSystem online: %d altars.", #bindings))
end

function SummonSystem.stop()
    running = false
    for _, binding in ipairs(bindings) do
        binding.prompt:Destroy()
    end
    table.clear(bindings)
end

function SummonSystem.getAltarCount(): number
    return #bindings
end

return SummonSystem
