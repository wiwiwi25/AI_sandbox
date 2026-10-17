--!strict
--[[
    CursedGems :: Main.client (client bootstrap)
    ------------------------------------------------------------------
    Start order is the entire content of this file, and it is not arbitrary:

      1. ClientState - the mirror every other module reads. Started first, so no
                       view can paint a default balance the player never had.
      2. Hud         - builds the widgets and subscribes to that mirror.
      3. EffectFx    - world-space feedback, the other subscriber to the same
                       event stream. Independent of the HUD on purpose.
      4. SpinFx      - the one ambient animation loop, started last: it only
                       needs to be running once the world exists, and it sweeps
                       for new tagged instances rather than requiring them to be
                       present at start.

    Nothing here simulates anything. The client draws what the server says is
    true; every number on screen arrived in a snapshot.
]]

local Shared = require(script.Parent.Imports)
local Config = Shared.Config

local ClientState = require(script.Parent.ClientState)
local Hud = require(script.Parent.Hud)
local EffectFx = require(script.Parent.EffectFx)
local SpinFx = require(script.Parent.SpinFx)

ClientState.start()
Hud.start()
EffectFx.start()

-- Two tags drive every ambient motion in the world. Registered here rather than
-- inside SpinFx, which stays free of any knowledge about this particular game.
SpinFx.track(Config.Tags.PEN_MARKER, math.rad(40), 0.5, 1.2)
SpinFx.track(Config.Tags.GEM, math.rad(160), 0.3, 2.2)

SpinFx.start()

if Config.Debug.VERBOSE then
    print(
        string.format("[CursedGems] Client ready, tracking %d animated instances.", SpinFx.count())
    )
end
