--!strict
--[[
    CursedGems :: Hud (client)
    ------------------------------------------------------------------
    The only place the player reads the game's single most important number.

    Everything here is a pure function of ClientState.get(). The HUD keeps no
    independent copy of the balance and runs no economy of its own, because the
    two would eventually disagree, and a gem counter that argues with the server
    is worse than no counter at all. The one value it projects between snapshots
    is the countdown, and even that is not a second economy: it is
    `gems - rate * age` at the rate the server itself sent, so a rate change
    corrects it on the next 4 Hz tick (see ClientState.remainingSeconds).

    What it shows, and why:

      * balance and drain per minute, because a drain the player cannot see
        feels arbitrary rather than fair;
      * TIME UNTIL EMPTY rather than a percentage - "10m 20s" is something a
        player can act on, "63%" is not;
      * a reserve bar normalised against a fixed window, so it reads as a life
        meter without pretending to be exact;
      * the next summon price, so the currency has a purpose before it has a
        use;
      * a curse banner plus a full-screen tint, because the movement penalty on
        its own is too quiet a signal for someone who has never seen it before.

    This is also the client's UI composition root: it builds the collection
    button and the panel behind it, so widget ownership stays in one file
    instead of being split across the bootstrap.

    Side note on the altar text: the client rewrites each summon prompt's
    ObjectText to include the current price. The server owns the prompt's
    existence and hold time; the text a local player reads is presentation, and
    presentation belongs on the client that reads it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = require(script.Parent.Imports)
local Config = Shared.Config
local Util = Shared.Util
local Remotes = Shared.Remotes
local CreatureCatalog = Shared.CreatureCatalog

local Theme = require(script.Parent.Theme)
local ClientState = require(script.Parent.ClientState)
local CollectionPanel = require(script.Parent.CollectionPanel)

local Hud = {}

local localPlayer = Players.LocalPlayer

-- The bar is full at this balance and empties as it drains away. Balances above
-- it simply peg the bar, which is the correct read: past a point the exact
-- number stops mattering.
local BAR_FULL_AT = 60
local BANNER_SECONDS = 3.5
local TOAST_SECONDS = 4
local MAX_TOASTS = 4

type Widgets = {
    root: ScreenGui,
    card: Frame,
    balance: TextLabel,
    drain: TextLabel,
    countdown: TextLabel,
    grace: TextLabel,
    summon: TextLabel,
    barFill: Frame,
    banner: Frame,
    bannerStroke: UIStroke,
    bannerText: TextLabel,
    tint: Frame,
    tintText: TextLabel,
    tintNote: TextLabel,
    toasts: Frame,
    collectionButton: TextButton,
}

local widgets: Widgets? = nil
local bannerToken = 0
local toastOrder = 0

local function formatDuration(seconds: number): string
    if seconds <= 0 then
        return "0s"
    end
    if seconds < 60 then
        return string.format("%ds", math.floor(seconds))
    end
    return string.format("%dm %02ds", math.floor(seconds / 60), math.floor(seconds % 60))
end

-- One colour ramp for the whole HUD, keyed off the same thresholds the server
-- warns on - so the bar, the number and the banner can never disagree about how
-- bad things are.
local function tierColor(gems: number): Color3
    local level = 0
    for index, threshold in ipairs(Config.Curse.WARN_AT) do
        if gems <= threshold then
            level = index
        end
    end
    if level >= 2 then
        return Theme.Color.danger
    end
    if level == 1 then
        return Theme.Color.warn
    end
    return Theme.Color.good
end

local function build(root: ScreenGui): Widgets
    -- Built first, so it renders behind everything else, and built invisible: a
    -- full-screen tint is the one widget that ruins the view entirely if it
    -- ever leaks into a non-cursed state.
    local tint = Theme.frame(
        root,
        "CurseTint",
        UDim2.fromScale(1, 1),
        UDim2.fromScale(0, 0),
        Theme.Color.curse,
        1
    )
    tint.Visible = false

    -- A gradient rather than a flat wash: clear across the middle where the
    -- altar and the creatures actually are, colour pulled in at the top and
    -- bottom edges. Flat would be a fog; this is a mood.
    local gradient = Instance.new("UIGradient")
    gradient.Rotation = 90
    gradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.15),
        NumberSequenceKeypoint.new(0.42, 1),
        NumberSequenceKeypoint.new(0.58, 1),
        NumberSequenceKeypoint.new(1, 0.2),
    })
    gradient.Parent = tint

    local tintText = Theme.label(
        tint,
        "CURSED",
        UDim2.new(1, 0, 0, 34),
        UDim2.new(0, 0, 0.64, 0),
        26,
        Theme.Font.display,
        Theme.Color.text
    )
    tintText.TextXAlignment = Enum.TextXAlignment.Center
    tintText.TextTransparency = 0.1

    local tintNote = Theme.label(
        tint,
        "Collect a gem to lift it",
        UDim2.new(1, 0, 0, 20),
        UDim2.new(0, 0, 0.64, 36),
        15,
        Theme.Font.body,
        Theme.Color.text
    )
    tintNote.TextXAlignment = Enum.TextXAlignment.Center
    tintNote.TextTransparency = 0.25

    -- Top-RIGHT, not top-left. The native chat window owns the top-left corner,
    -- and a reserve card underneath it is a card nobody can read - the exact bug
    -- the first playtest reported. The card stacks under the COLLECTION button,
    -- which was already anchored here, so the right edge is a single column:
    -- button, reserve, then the collection panel below.
    local card = Theme.frame(
        root,
        "Reserve",
        UDim2.fromOffset(272, 160),
        UDim2.new(1, -20, 0, 62),
        Theme.Color.panel,
        0.1
    )
    card.AnchorPoint = Vector2.new(1, 0)
    Theme.corner(card, 14)
    Theme.stroke(card, Theme.Color.accent, 1.2, 0.65)

    Theme.label(
        card,
        "GEM RESERVE",
        UDim2.fromOffset(150, 14),
        UDim2.fromOffset(18, 12),
        12,
        Theme.Font.bold,
        Theme.Color.muted
    )
    local grace = Theme.label(
        card,
        "",
        UDim2.fromOffset(88, 14),
        UDim2.fromOffset(166, 12),
        12,
        Theme.Font.bold,
        Theme.Color.good
    )
    grace.TextXAlignment = Enum.TextXAlignment.Right
    grace.Visible = false

    -- The big number. Everything else on the card exists to explain it.
    local balance = Theme.label(
        card,
        "0",
        UDim2.fromOffset(200, 48),
        UDim2.fromOffset(16, 24),
        42,
        Theme.Font.display,
        Theme.Color.text
    )
    local drain = Theme.label(
        card,
        "",
        UDim2.fromOffset(220, 18),
        UDim2.fromOffset(18, 72),
        15,
        Theme.Font.bold,
        Theme.Color.danger
    )
    local countdown = Theme.label(
        card,
        "",
        UDim2.new(1, -36, 0, 16),
        UDim2.fromOffset(18, 90),
        13,
        Theme.Font.body,
        Theme.Color.muted
    )
    local track = Theme.frame(
        card,
        "Track",
        UDim2.new(1, -36, 0, 6),
        UDim2.fromOffset(18, 114),
        Theme.Color.slab,
        0.3
    )
    Theme.corner(track, 3)

    local barFill = Theme.frame(
        track,
        "Fill",
        UDim2.new(1, 0, 1, 0),
        UDim2.fromOffset(0, 0),
        Theme.Color.good,
        0
    )
    Theme.corner(barFill, 3)

    local summon = Theme.label(
        card,
        "",
        UDim2.new(1, -36, 0, 16),
        UDim2.fromOffset(18, 128),
        12,
        Theme.Font.body,
        Theme.Color.faint
    )

    local banner = Theme.frame(
        root,
        "Banner",
        UDim2.fromOffset(440, 46),
        UDim2.new(0.5, 0, 0, 22),
        Theme.Color.panel,
        0.05
    )
    banner.AnchorPoint = Vector2.new(0.5, 0)
    banner.Visible = false
    Theme.corner(banner, 10)
    local bannerStroke = Theme.stroke(banner, Theme.Color.warn, 1.6, 0.25)
    local bannerText = Theme.label(
        banner,
        "",
        UDim2.new(1, -24, 1, 0),
        UDim2.fromOffset(12, 0),
        16,
        Theme.Font.bold,
        Theme.Color.text
    )
    bannerText.TextXAlignment = Enum.TextXAlignment.Center

    -- Bottom-anchored, because toasts stack upward from the floor of the screen
    -- and must never be the thing that covers the altar being used.
    local toasts = Theme.frame(
        root,
        "Toasts",
        UDim2.fromOffset(460, 220),
        UDim2.new(0.5, -230, 1, -240),
        Theme.Color.panel,
        1
    )
    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
    layout.Padding = UDim.new(0, 6)
    layout.Parent = toasts

    local collectionButton = Theme.button(
        root,
        "COLLECTION",
        UDim2.fromOffset(176, 34),
        UDim2.new(1, -20, 0, 20),
        Theme.Color.accent
    )
    collectionButton.Name = "CollectionButton"
    collectionButton.AnchorPoint = Vector2.new(1, 0)

    -- The panel is built closed and hidden. A hidden ScrollingFrame of hidden
    -- ViewportFrames costs nothing to render, which is what makes it acceptable
    -- for this to live in memory the whole session.
    CollectionPanel.create(root)
    collectionButton.MouseButton1Click:Connect(function()
        CollectionPanel.toggle()
    end)

    return {
        root = root,
        card = card,
        balance = balance,
        drain = drain,
        countdown = countdown,
        grace = grace,
        summon = summon,
        barFill = barFill,
        banner = banner,
        bannerStroke = bannerStroke,
        bannerText = bannerText,
        tint = tint,
        tintText = tintText,
        tintNote = tintNote,
        toasts = toasts,
        collectionButton = collectionButton,
    }
end

-- --------------------------------------------------------------------------
-- Transient feedback
-- --------------------------------------------------------------------------

local function showBanner(text: string, color: Color3)
    local w = widgets
    if not w then
        return
    end

    bannerToken += 1
    local token = bannerToken
    w.bannerText.Text = text
    w.bannerText.TextColor3 = color
    w.bannerStroke.Color = color
    w.banner.Visible = true

    -- Token guard: without it, two warnings in quick succession mean the older
    -- one's timer dismisses the newer banner and the second warning flashes for
    -- a single frame. Cheap to add, very obvious when missing.
    task.delay(BANNER_SECONDS, function()
        if token == bannerToken and widgets then
            widgets.banner.Visible = false
        end
    end)
end

local function pushToast(text: string, color: Color3)
    local w = widgets
    if not w then
        return
    end

    -- Capped. Several players summoning at once is a normal social moment, and
    -- the toast column must not grow past the point of being readable.
    local live: { Frame } = {}
    for _, child in ipairs(w.toasts:GetChildren()) do
        if child:IsA("Frame") then
            table.insert(live, child)
        end
    end
    if #live >= MAX_TOASTS then
        local oldest = live[1]
        for _, toast in ipairs(live) do
            if toast.LayoutOrder < oldest.LayoutOrder then
                oldest = toast
            end
        end
        oldest:Destroy()
    end

    toastOrder += 1
    local toast = Theme.frame(
        w.toasts,
        "Toast",
        UDim2.new(1, 0, 0, 34),
        UDim2.new(0, 0, 0, 0),
        Theme.Color.panel,
        0.05
    )
    toast.LayoutOrder = toastOrder
    Theme.corner(toast, 8)
    Theme.stroke(toast, color, 1.4, 0.35)

    local label = Theme.label(
        toast,
        text,
        UDim2.new(1, -24, 1, 0),
        UDim2.fromOffset(12, 0),
        14,
        Theme.Font.bold,
        color
    )
    label.TextXAlignment = Enum.TextXAlignment.Center

    -- No entry animation: the UIListLayout owns Position, so tweening it here
    -- would fight the layout. The reflow of the stack is the animation.
    task.delay(TOAST_SECONDS, function()
        if toast.Parent then
            toast:Destroy()
        end
    end)
end

-- --------------------------------------------------------------------------
-- Cursed state
-- --------------------------------------------------------------------------

local tintPulsing = false

local function setCursedTint(active: boolean)
    local w = widgets
    if not w then
        return
    end

    -- Called from the sync loop, so this has to be free when nothing changed.
    if w.tint.Visible == active then
        return
    end

    local tint = w.tint
    tint.Visible = active

    if not active then
        tintPulsing = false
        return
    end

    -- A slow breath rather than a blink: the tint is a mood, and anything faster
    -- reads as a flashing warning light rather than a state the player is in.
    tintPulsing = true
    task.spawn(function()
        while tintPulsing do
            Theme.tween(tint, { BackgroundTransparency = 0.78 }, 1.6).Completed:Wait()
            if not tintPulsing then
                break
            end
            Theme.tween(tint, { BackgroundTransparency = 0.9 }, 1.6).Completed:Wait()
        end
    end)
end

-- --------------------------------------------------------------------------
-- Altar price
-- --------------------------------------------------------------------------

local promptText: string? = nil
local promptScanConnected = false

local function visitPrompt(instance: Instance)
    local text = promptText
    if text ~= nil and instance:IsA("ProximityPrompt") and instance.Name == "SummonPrompt" then
        instance.ObjectText = text
    end
end

-- The server owns each prompt and its hold time; the string the local player
-- reads is presentation, so the client writes it - and only when the cost
-- actually changes, which happens once, after the first summon.
local function applyPromptCost(cost: number)
    local text = string.format("Summoning Altar  -  %d gems", cost)
    if text == promptText then
        return
    end
    promptText = text

    for _, descendant in ipairs(workspace:GetDescendants()) do
        visitPrompt(descendant)
    end

    -- Parts of the world can replicate after this script starts, so new prompts
    -- are picked up as they arrive rather than only in the initial sweep.
    if not promptScanConnected then
        promptScanConnected = true
        workspace.DescendantAdded:Connect(visitPrompt)
    end
end

-- --------------------------------------------------------------------------
-- Feedback and update
-- --------------------------------------------------------------------------

-- Only the kinds this HUD has something to say about. Spatial effects are
-- EffectFx's business; the two subscribe to the same event independently on
-- purpose, so a problem in one cannot take the other down.
local function handleFeedback(payload: any)
    if type(payload) ~= "table" then
        return
    end

    local kind = payload.kind

    if kind == "curseWarning" then
        local balance = Util.isFiniteNumber(payload.balance) and math.floor(payload.balance) or 0
        local level = Util.isFiniteNumber(payload.level) and payload.level or 1
        if level >= 2 then
            showBanner(string.format("CRITICAL: %d gems left", balance), Theme.Color.danger)
        else
            showBanner(string.format("Gem reserves low: %d left", balance), Theme.Color.warn)
        end
    elseif kind == "curseChanged" then
        if payload.cursed == true then
            pushToast("Cursed - collect a gem to lift it", Theme.Color.danger)
        else
            pushToast("Curse lifted", Theme.Color.good)
        end
    elseif kind == "summonDenied" then
        -- The only denial the server currently sends is an empty wallet, and it
        -- sends the numbers needed to say exactly why it refused.
        if payload.reason == "gems" and Util.isFiniteNumber(payload.cost) then
            local held = Util.isFiniteNumber(payload.balance) and math.floor(payload.balance) or 0
            pushToast(
                string.format("Not enough gems: %d of %d", held, math.floor(payload.cost)),
                Theme.Color.warn
            )
        else
            pushToast("Summon denied", Theme.Color.warn)
        end
    elseif kind == "summonReveal" then
        if type(payload.displayName) == "string" then
            local rarity = type(payload.rarity) == "string" and payload.rarity or "?"
            pushToast(
                string.format("Summoned %s  (%s)", payload.displayName, rarity),
                Theme.Color.accent
            )
        end
    elseif kind == "witnessSummon" then
        if type(payload.displayName) == "string" and type(payload.playerName) == "string" then
            pushToast(
                string.format("%s summoned %s", payload.playerName, payload.displayName),
                Theme.Color.accent
            )
        end
    end
end

-- The countdown is the one value on this HUD that has to move continuously: it
-- is a rate, not an event. Drawn from the snapped balance it advanced in steps
-- of 60/drain seconds - eight of them at the base drain - so it sat still and
-- then lurched. Drawn from ClientState.remainingSeconds() it is projected
-- between snapshots and decrements one second at a time.
--
-- The writes are guarded on the rendered string: Heartbeat calls this sixty
-- times a second and the text changes once, so the other fifty-nine calls are a
-- comparison and a table read.
local lastCountdownText = ""
local lastCountdownColor: Color3? = nil

local function paintCountdown()
    local w = widgets
    if not w then
        return
    end

    local state = ClientState.get()

    local text: string
    local color: Color3

    if state.gems <= 0 then
        text = "empty - grab a gem"
        color = Theme.Color.danger
    elseif state.grace > 0 then
        -- Drain pauses while the shield is up, so quoting a countdown during
        -- grace would be a lie about the number the player watches most closely.
        text = "drain resumes when the shield drops"
        color = Theme.Color.good
    else
        local seconds = ClientState.remainingSeconds()
        if seconds then
            text = string.format("runs dry in %s", formatDuration(seconds))
            color = Theme.Color.muted
        else
            text = "holding steady"
            color = Theme.Color.muted
        end
    end

    if text ~= lastCountdownText then
        lastCountdownText = text
        w.countdown.Text = text
    end
    if color ~= lastCountdownColor then
        lastCountdownColor = color
        w.countdown.TextColor3 = color
    end
end

-- Repaints every widget from the mirror. Idempotent and cheap, so it runs on
-- every sync tick rather than tracking which fields changed - a view that has to
-- remember what it last drew is a view that will eventually draw something
-- stale.
local function update()
    local w = widgets
    if not w then
        return
    end

    local state = ClientState.get()
    local color = tierColor(state.gems)

    w.balance.Text = Util.abbreviate(state.gems)
    w.balance.TextColor3 = color

    if state.grace > 0 then
        w.grace.Text = string.format("SHIELDED %s", formatDuration(state.grace))
        w.grace.Visible = true
    else
        w.grace.Visible = false
    end

    if state.drainPerMinute > 0 then
        w.drain.Text = string.format("-%.1f gems / min", state.drainPerMinute)
        w.drain.TextColor3 = Theme.Color.danger
    else
        w.drain.Text = "no drain"
        w.drain.TextColor3 = Theme.Color.good
    end

    paintCountdown()

    -- Assigned rather than tweened: this is refreshed four times a second, and
    -- four overlapping tweens of one property is a fight, not an animation.
    w.barFill.Size = UDim2.new(math.clamp(state.gems / BAR_FULL_AT, 0, 1), 0, 1, 0)
    w.barFill.BackgroundColor3 = color

    w.summon.Text = string.format(
        "next summon %d gems   |   %d creatures",
        state.summonCost,
        state.creatureCount
    )

    local discovered = state.collection and #state.collection or 0
    w.collectionButton.Text = string.format("COLLECTION  %d/%d", discovered, #CreatureCatalog.List)

    if state.collection then
        CollectionPanel.setEntries(state.collection)
    end

    setCursedTint(state.cursed)
    applyPromptCost(state.summonCost)
end

function Hud.start()
    if widgets then
        return
    end

    local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

    local root = Instance.new("ScreenGui")
    root.Name = "CursedGemsHud"
    -- ResetOnSpawn off: the HUD mirrors state that survives respawns, and
    -- rebuilding it on death would rebuild the collection panel's models too.
    root.ResetOnSpawn = false
    root.IgnoreGuiInset = true
    root.DisplayOrder = 10
    root.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    root.Parent = playerGui

    widgets = build(root)

    ClientState.onChanged(function()
        update()
    end)

    -- The countdown alone is repainted off the frame clock rather than the
    -- snapshot clock: it is the one number that has to be continuous, and four
    -- repaints a second is what made it stair-step.
    RunService.Heartbeat:Connect(function()
        paintCountdown()
    end)
    Remotes.Feedback.OnClientEvent:Connect(handleFeedback)

    -- Paint once from whatever is already known: a snapshot can land before this
    -- script finishes starting, and waiting for the next tick would show a zero
    -- balance on join.
    update()
end

return Hud
