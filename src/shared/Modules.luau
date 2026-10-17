--!strict
--[[
    CursedGems :: Modules
    ------------------------------------------------------------------
    Requires every shared module ONCE, in dependency order, and returns them as
    a package table.

    Why this exists: server and client otherwise need long
    game:GetService(...):WaitForChild(...) chains in every single file. Here the
    chain appears once per side (in Imports.luau) and nowhere else.

    NOTE: a table constructor holds VALUES only. Luau exported types are not
    values and cannot be re-exported through a table, so consumers that need a
    shared type require the declaring module directly. See TypeProbe notes in
    docs/PHASE1_ARCHITECTURE.md.

    Require direction is strictly one-way:
        Modules -> Config, Util, Pool, GemCatalog, CreatureCatalog,
                   CreatureFactory, Remotes
    No shared module may ever require Modules itself, or the cycle fails at
    runtime when the first script requires it.
]]

return {
    Config = require(script.Parent.Config),
    Util = require(script.Parent.Util),
    Pool = require(script.Parent.Pool),
    GemCatalog = require(script.Parent.GemCatalog),
    CreatureCatalog = require(script.Parent.CreatureCatalog),
    CreatureFactory = require(script.Parent.CreatureFactory),
    Remotes = require(script.Parent.Remotes),
}
