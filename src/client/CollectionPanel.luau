--!strict
--[[
    CursedGems :: CollectionPanel (client)
    ------------------------------------------------------------------
    The collection, rendered as a grid of cards each showing a LIVE 3D preview
    built by the same factory that makes the followers. No uploaded icons, no
    sprite sheet, no art pipeline - the model IS the icon.

    Three deliberate touches:

      * UNDISCOVERED species are rendered as true silhouettes (the real model
        with its colour stripped) rather than hidden. A grid that fills in tells
        the player how much is left, which is most of what makes a collection
        fun; an empty panel tells them nothing. The silhouette teases the shape
        without giving away the creature.

      * Cards are capped at MAX_CARDS. Every card is a model, a camera and a
        ViewportFrame, and the panel must not get heavier as a collection grows.

      * The grid rebuilds only when the owned SET changes, never per frame, and
        the whole panel is set invisible when closed - which is also what stops
        the engine rendering a dozen viewports nobody is looking at.
]]

local Shared = require(script.Parent.Imports)
local CreatureCatalog = Shared.CreatureCatalog
local CreatureFactory = Shared.CreatureFactory
local Theme = require(script.Parent.Theme)
local ClientState = require(script.Parent.ClientState)

local CollectionPanel = {}

local PANEL_WIDTH = 400
local CARD_SIZE = UDim2.fromOffset(112, 132)
local MAX_CARDS = 30
local SILHOUETTE = Color3.fromRGB(26, 29, 38)

local frame: Frame? = nil
local grid: ScrollingFrame? = nil
local countLabel: TextLabel? = nil
local lastSignature: string? = nil

local function cardStrokeColor(def: typeof(CreatureCatalog.List[1]), discovered: boolean): Color3
    if not discovered then
        return Theme.Color.faint
    end
    return Theme.rarityColor(def.rarity)
end

local function frameCamera(viewport: ViewportFrame, def: typeof(CreatureCatalog.List[1]))
    local height = CreatureFactory.highestPoint(def)
    local camera = Instance.new("Camera")
    camera.FieldOfView = 34
    camera.CFrame = CFrame.lookAt(
        Vector3.new(0, height * 0.64, height * 2.4 + 3.5),
        Vector3.new(0, height * 0.46, 0)
    )
    camera.Parent = viewport
    viewport.CurrentCamera = camera
end

local function buildCard(
    parent: Instance,
    def: typeof(CreatureCatalog.List[1]),
    discovered: boolean
): Frame
    local card =
        Theme.frame(parent, def.id, CARD_SIZE, UDim2.fromOffset(0, 0), Theme.Color.panelLight, 0)
    Theme.corner(card, 10)
    Theme.stroke(card, cardStrokeColor(def, discovered), 1.2, discovered and 0.35 or 0.65)

    local viewport = Instance.new("ViewportFrame")
    viewport.Name = "Preview"
    viewport.Size = UDim2.new(1, -12, 0, 80)
    viewport.Position = UDim2.fromOffset(6, 6)
    viewport.BackgroundColor3 = Theme.Color.backdrop
    viewport.BackgroundTransparency = 0.15
    viewport.BorderSizePixel = 0
    viewport.Ambient = Color3.fromRGB(140, 146, 160)
    viewport.LightColor = Color3.fromRGB(255, 248, 238)
    viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)
    viewport.Parent = card
    Theme.corner(viewport, 8)

    local model = CreatureFactory.build(def, viewport)
    model:PivotTo(CFrame.new(0, 0, 0))
    if not discovered then
        -- Same geometry, colour stripped: the shape is the teaser.
        for _, part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") then
                part.Color = SILHOUETTE
                part.Material = Enum.Material.SmoothPlastic
            end
        end
    end
    frameCamera(viewport, def)

    local name = Theme.label(
        card,
        discovered and def.displayName or "???",
        UDim2.new(1, -12, 0, 18),
        UDim2.fromOffset(6, 90),
        14,
        Theme.Font.bold,
        discovered and Theme.Color.text or Theme.Color.faint
    )
    name.TextXAlignment = Enum.TextXAlignment.Center

    local rarity = Theme.label(
        card,
        string.upper(def.rarity),
        UDim2.new(1, -12, 0, 14),
        UDim2.fromOffset(6, 108),
        11,
        Theme.Font.body,
        discovered and Theme.rarityColor(def.rarity) or Theme.Color.faint
    )
    rarity.TextXAlignment = Enum.TextXAlignment.Center

    return card
end

function CollectionPanel.create(parent: Instance): Frame
    local created = Theme.frame(
        parent,
        "Collection",
        UDim2.new(0, PANEL_WIDTH, 1, -84),
        UDim2.new(1, -(PANEL_WIDTH + 20), 0, 64),
        Theme.Color.panel,
        0.06
    )
    Theme.corner(created, 14)
    Theme.stroke(created, Theme.Color.accent, 1.2, 0.6)

    Theme.label(
        created,
        "COLLECTION",
        UDim2.fromOffset(300, 26),
        UDim2.fromOffset(16, 14),
        20,
        Theme.Font.display,
        Theme.Color.text
    )
    countLabel = Theme.label(
        created,
        "",
        UDim2.new(1, -32, 0, 16),
        UDim2.fromOffset(16, 40),
        13,
        Theme.Font.body,
        Theme.Color.muted
    )

    local scroller = Instance.new("ScrollingFrame")
    scroller.Name = "Grid"
    scroller.Size = UDim2.new(1, -24, 1, -68)
    scroller.Position = UDim2.fromOffset(12, 56)
    scroller.BackgroundTransparency = 1
    scroller.BorderSizePixel = 0
    scroller.ScrollBarThickness = 6
    scroller.ScrollBarImageColor3 = Theme.Color.slab
    scroller.CanvasSize = UDim2.new()
    scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroller.Parent = created

    local layout = Instance.new("UIGridLayout")
    layout.CellSize = CARD_SIZE
    layout.CellPadding = UDim2.fromOffset(8, 8)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = scroller

    created.Visible = false
    frame = created
    grid = scroller
    return created
end

local function rebuild(entries: { ClientState.CollectionEntry })
    local scroller = grid
    if not scroller then
        return
    end

    for _, child in ipairs(scroller:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end

    local owned: { [string]: boolean } = {}
    for _, entry in ipairs(entries) do
        owned[entry.id] = true
    end

    -- Rarest last, so the grid reads as a progression rather than a pile.
    local ordered = table.clone(CreatureCatalog.List)
    table.sort(ordered, function(a, b)
        local rankA = Theme.rarityRank(a.rarity)
        local rankB = Theme.rarityRank(b.rarity)
        if rankA ~= rankB then
            return rankA < rankB
        end
        return a.weight > b.weight
    end)

    -- Counted across the whole catalog rather than the rendered cards, or a
    -- collection larger than MAX_CARDS would under-report itself.
    local discovered = 0
    for _, def in ipairs(ordered) do
        if owned[def.id] == true then
            discovered += 1
        end
    end

    local shown = 0
    for _, def in ipairs(ordered) do
        if shown >= MAX_CARDS then
            break
        end
        shown += 1
        local card = buildCard(scroller, def, owned[def.id] == true)
        card.LayoutOrder = shown
    end

    if countLabel then
        local text = string.format("%d of %d discovered", discovered, #ordered)
        if #ordered > MAX_CARDS then
            text = string.format("%s (showing %d)", text, MAX_CARDS)
        end
        countLabel.Text = text
    end
end

-- Rebuilds only when the owned SET changes. The collection arrives on the sync
-- stream a few times a session, never per frame, but this is what makes that
-- guarantee explicit rather than accidental.
function CollectionPanel.setEntries(entries: { ClientState.CollectionEntry })
    local parts: { string } = {}
    for _, entry in ipairs(entries) do
        table.insert(parts, string.format("%d:%s", entry.slot, entry.id))
    end

    local signature = table.concat(parts, ",")
    if signature == lastSignature then
        return
    end
    lastSignature = signature
    rebuild(entries)
end

function CollectionPanel.toggle(): boolean
    local current = frame
    if not current then
        return false
    end
    current.Visible = not current.Visible
    return current.Visible
end

function CollectionPanel.isOpen(): boolean
    return frame ~= nil and frame.Visible
end

return CollectionPanel
