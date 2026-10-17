--!strict
--[[
    CursedGems :: server bootstrap
    ------------------------------------------------------------------
    The only server file that knows the whole system exists. Everything else is
    a module with one job, reachable through the package in Imports.

    The start order is the design, not an accident:

      1. Data first. A player who joins while the world is still being built
         still gets a session, and no gameplay system runs without one - they
         all refuse to act on a player whose data has not become authoritative.
      2. World second. Every gameplay system is HANDED positions from the build
         result rather than rediscovering them, so world layout stays owned by
         exactly one file.
      3. State sync last. The first snapshot a client receives is therefore a
         complete one.
]]

local Shared = require(script.Parent.Imports)
local Config = Shared.Config

local PlayerDataService = require(script.Parent.PlayerDataService)
local WorldBuilder = require(script.Parent.WorldBuilder)
local GemSystem = require(script.Parent.GemSystem)
local SummonSystem = require(script.Parent.SummonSystem)
local CurseSystem = require(script.Parent.CurseSystem)
local FollowerSystem = require(script.Parent.FollowerSystem)
local StateSync = require(script.Parent.StateSync)

local startedAt = os.clock()

PlayerDataService.start()

if PlayerDataService.isMemoryOnly() then
    warn(
        "[CursedGems] DataStore unavailable - running WITHOUT persistence. "
            .. "Progress will not survive a restart (expected in unpublished Studio)."
    )
end

local build = WorldBuilder.build()

GemSystem.start(build.gemSpawnPoints)
SummonSystem.start(build.pens)
CurseSystem.start(build.shrineCenter)
FollowerSystem.start()
StateSync.start()

print(string.format(
    -- %.4g, not %d: the base drain is 7.5 and %d truncates it to 7, which
    -- would print a boot line that contradicts the HUD.
    "[CursedGems] %s ready in %d ms: %d gem positions, %d summon altars, %.4g/%.4g/%.4g gems per minute base/mercy/shrine.",
    Config.VERSION,
    math.floor((os.clock() - startedAt) * 1000),
    #build.gemSpawnPoints,
    #build.pens,
    Config.Economy.BASE_DECAY_PER_MINUTE,
    Config.Economy.BASE_DECAY_PER_MINUTE * Config.Economy.MERCY_MULTIPLIER,
    Config.Economy.BASE_DECAY_PER_MINUTE * Config.Economy.SHRINE_DECAY_MULTIPLIER
))
