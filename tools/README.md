# tools/ — the toolchain (intentionally not committed)

`check.ps1` couples this project to four executables and one definitions file. They are
downloads rather than source, so `.gitignore` keeps `tools/*` out of the repository —
except this file, which records what a working tree has to contain. Recreate the folder
and the gate runs again with no edits.

| Path the gate expects | What it is |
|---|---|
| `tools/stylua/stylua.exe` | [StyLua](https://github.com/JohnnyMorganz/StyLua) — step 1, `--check` against `.stylua.toml` |
| `tools/rojo/rojo.exe` | [Rojo](https://github.com/rojo-rbx/rojo) — step 2 (`sourcemap`) and the `build` in the README |
| `tools/luau/luau-compile.exe` | [Luau](https://github.com/luau-lang/luau) CLI — step 3, every file compiles individually |
| `tools/luau-lsp/luau-lsp.exe` | [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) — step 4, strict types; zero diagnostics is the gate |
| `tools/globalTypes.d.luau` | Roblox engine API definitions, passed as `--definitions` to `luau-lsp analyze` |

A working tree also holds files the gate never reads: the release zips (`stylua.zip`,
`rojo.zip`, `luau.zip`, `luau-lsp.zip`, ~14 MB), the extra Luau CLI binaries (`luau.exe`,
`luau-analyze.exe`, `luau-ast.exe`) and `Rojo.rbxm`, which is the Rojo **Studio plugin** —
the [live-sync path](../docs/PHASE1_ARCHITECTURE.md#the-live-sync-path), not the offline
one. That lot is ~64 MB in total, which is the whole argument for ignoring it.

Nothing here is version-pinned: each tool is whatever release was current when it was
fetched. `globalTypes.d.luau` therefore has to match the `luau-lsp` beside it — the
definitions file and the analyzer are published together. If `stylua --check` or
`luau-lsp analyze` disagrees with the tree, suspect the tool versions before the tree.
