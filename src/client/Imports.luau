--!strict
-- Single entry point for shared modules. See src/shared/Modules.luau.
return require(
    game:GetService("ReplicatedStorage"):WaitForChild("CursedGems"):WaitForChild("Modules")
)
