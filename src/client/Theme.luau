--!strict
--[[
    CursedGems :: Theme (client)
    ------------------------------------------------------------------
    Every colour, font and construction helper the HUD uses, in one file.

    Deliberately ASSET-FREE: no ImageLabel, no uploaded icons, no sounds with
    asset ids. Everything is built from Frames, UICorner, UIStroke, UIGradient
    and TextLabels, all of which ship with the engine. That is what lets a fresh
    clone of this repository run in Studio with zero uploads, zero moderation
    and zero missing-asset warnings - the most common practical reason small
    Roblox projects stall before they are ever playable.

    Rarity colours are keyed by the exact strings authored in CreatureCatalog,
    with a neutral fallback so an unrecognised tier renders as unremarkable
    rather than taking the whole collection panel down.
]]

local TweenService = game:GetService("TweenService")

local Theme = {}

Theme.Color = {
    backdrop = Color3.fromRGB(11, 13, 19),
    panel = Color3.fromRGB(21, 24, 33),
    panelLight = Color3.fromRGB(31, 35, 47),
    slab = Color3.fromRGB(44, 50, 66),
    text = Color3.fromRGB(236, 240, 248),
    muted = Color3.fromRGB(146, 156, 176),
    faint = Color3.fromRGB(96, 105, 124),
    good = Color3.fromRGB(104, 226, 148),
    warn = Color3.fromRGB(255, 190, 74),
    danger = Color3.fromRGB(255, 92, 92),
    accent = Color3.fromRGB(120, 190, 255),
    curse = Color3.fromRGB(196, 60, 220),
    black = Color3.fromRGB(0, 0, 0),
    white = Color3.fromRGB(255, 255, 255),
}

Theme.Font = {
    display = Enum.Font.GothamBlack,
    bold = Enum.Font.GothamBold,
    body = Enum.Font.Gotham,
}

-- Mirrors CreatureCatalog's rarity strings. Order is presentation order, so the
-- grid reads rarest-last regardless of how the catalog is authored.
Theme.Rarity = {
    Common = Color3.fromRGB(178, 190, 210),
    Uncommon = Color3.fromRGB(104, 226, 148),
    Rare = Color3.fromRGB(120, 190, 255),
}

Theme.RarityOrder = { "Common", "Uncommon", "Rare" }

function Theme.rarityColor(rarity: string): Color3
    return Theme.Rarity[rarity] or Theme.Color.muted
end

function Theme.rarityRank(rarity: string): number
    for index, name in ipairs(Theme.RarityOrder) do
        if name == rarity then
            return index
        end
    end
    return 0
end

function Theme.corner(instance: Instance, radius: number): UICorner
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius)
    corner.Parent = instance
    return corner
end

function Theme.stroke(
    instance: Instance,
    color: Color3,
    thickness: number,
    transparency: number
): UIStroke
    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Thickness = thickness
    stroke.Transparency = transparency
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = instance
    return stroke
end

function Theme.pad(instance: Instance, all: number): UIPadding
    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, all)
    padding.PaddingBottom = UDim.new(0, all)
    padding.PaddingLeft = UDim.new(0, all)
    padding.PaddingRight = UDim.new(0, all)
    padding.Parent = instance
    return padding
end

-- A tween factory, because every HUD animation is "change X over Y seconds", and
-- building the TweenInfo inline in each caller buries the easing choice in the
-- middle of layout code.
function Theme.tween(instance: Instance, goal: { [string]: any }, seconds: number): Tween
    local tween = TweenService:Create(
        instance,
        TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        goal
    )
    tween:Play()
    return tween
end

function Theme.frame(
    parent: Instance,
    name: string,
    size: UDim2,
    position: UDim2,
    background: Color3,
    transparency: number
): Frame
    local frame = Instance.new("Frame")
    frame.Name = name
    frame.Size = size
    frame.Position = position
    frame.BackgroundColor3 = background
    frame.BackgroundTransparency = transparency
    frame.BorderSizePixel = 0
    frame.Parent = parent
    return frame
end

function Theme.label(
    parent: Instance,
    text: string,
    size: UDim2,
    position: UDim2,
    textSize: number,
    font: Enum.Font,
    color: Color3
): TextLabel
    local label = Instance.new("TextLabel")
    label.Text = text
    label.Size = size
    label.Position = position
    label.BackgroundTransparency = 1
    label.BorderSizePixel = 0
    label.Font = font
    label.TextSize = textSize
    label.TextColor3 = color
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Parent = parent
    return label
end

function Theme.button(
    parent: Instance,
    text: string,
    size: UDim2,
    position: UDim2,
    accent: Color3
): TextButton
    local button = Instance.new("TextButton")
    button.Name = "Button"
    button.Text = text
    button.Size = size
    button.Position = position
    button.BackgroundColor3 = Theme.Color.panelLight
    button.BackgroundTransparency = 0
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.Font = Theme.Font.bold
    button.TextSize = 14
    button.TextColor3 = accent
    button.Parent = parent

    Theme.corner(button, 8)
    local stroke = Theme.stroke(button, accent, 1.4, 0.55)

    -- Hover feedback matters more than it looks: the HUD is the only thing on
    -- screen, so a button that does not react reads as broken.
    button.MouseEnter:Connect(function()
        Theme.tween(button, { BackgroundColor3 = accent, TextColor3 = Theme.Color.backdrop }, 0.12)
        Theme.tween(stroke, { Transparency = 0.1 }, 0.12)
    end)
    button.MouseLeave:Connect(function()
        Theme.tween(
            button,
            { BackgroundColor3 = Theme.Color.panelLight, TextColor3 = accent },
            0.18
        )
        Theme.tween(stroke, { Transparency = 0.55 }, 0.18)
    end)

    return button
end

return Theme
