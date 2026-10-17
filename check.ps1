# ============================================================================
#  CursedGems :: offline gate
# ============================================================================
#  Wraps all four tools so one command proves the project is sound without
#  Studio, an account or a network connection:
#
#    1. stylua        - formatting is not a matter of taste here; it is checked
#    2. rojo sourcemap- the file tree Luau actually sees, regenerated every run
#                       (a stale sourcemap makes the analyzer silently blind)
#    3. luau-compile  - every file parses and compiles, individually
#    4. luau-lsp      - strict type checking, and ZERO diagnostics is the gate
#
#  Usage:
#      .\check.ps1          verify everything (read-only)
#      .\check.ps1 -Fix     also reformat with stylua first
#
#  Exits 0 only when all four pass, so it can be wired into a pre-commit hook or
#  CI unchanged.
# ============================================================================

[CmdletBinding()]
param(
    [switch]$Fix
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$stylua = Join-Path $PSScriptRoot 'tools\stylua\stylua.exe'
$rojo = Join-Path $PSScriptRoot 'tools\rojo\rojo.exe'
$luau = Join-Path $PSScriptRoot 'tools\luau\luau-compile.exe'
$lsp = Join-Path $PSScriptRoot 'tools\luau-lsp\luau-lsp.exe'
$definitions = 'tools/globalTypes.d.luau'
$sourcemap = 'sourcemap.json'
$analyzeLog = 'build\analyze.txt'
$rootPrefix = $PSScriptRoot.TrimEnd('\') + '\'

foreach ($tool in @($stylua, $rojo, $luau, $lsp)) {
    if (-not (Test-Path $tool)) {
        throw "Missing toolchain component: $tool"
    }
}
if (-not (Test-Path 'build')) {
    New-Item -ItemType Directory -Path 'build' | Out-Null
}

# ---------------------------------------------------------------- 1. format
if ($Fix) {
    & $stylua src
    if ($LASTEXITCODE -ne 0) { throw 'stylua failed' }
    Write-Host '[1/4] stylua       : formatted' -ForegroundColor Green
}
else {
    $diff = & $stylua --check src 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[1/4] stylua       : FAILED (run .\check.ps1 -Fix)' -ForegroundColor Red
        $diff | ForEach-Object { Write-Host "      $_" }
        exit 1
    }
    Write-Host '[1/4] stylua       : clean' -ForegroundColor Green
}

# ------------------------------------------------------------- 2. sourcemap
& $rojo sourcemap --output $sourcemap | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'rojo sourcemap failed' }
Write-Host "[2/4] rojo         : $sourcemap regenerated" -ForegroundColor Green

# --------------------------------------------------------------- 3. compile
$files = @(
    Get-ChildItem src -Recurse -Filter *.luau |
        ForEach-Object { $_.FullName.Replace($rootPrefix, '').Replace('\', '/') }
)

$compileFailures = @()
foreach ($file in $files) {
    & $luau --null $file *> $null
    if ($LASTEXITCODE -ne 0) { $compileFailures += $file }
}
if ($compileFailures.Count -gt 0) {
    Write-Host "[3/4] luau-compile : FAILED ($($compileFailures.Count) of $($files.Count))" -ForegroundColor Red
    $compileFailures | ForEach-Object { Write-Host "      $_" }
    exit 1
}
Write-Host "[3/4] luau-compile : $($files.Count) files compile" -ForegroundColor Green

# ---------------------------------------------------------------- 4. analyze
# Routed through cmd on purpose: PowerShell surfaces luau-lsp's [INFO] lines on
# stderr as terminating errors, which aborts this script for no reason at all.
$quoted = ($files | ForEach-Object { '"' + $_ + '"' }) -join ' '
$line = "`"$lsp`" analyze --definitions=$definitions --sourcemap=$sourcemap $quoted > `"$analyzeLog`" 2>&1"
cmd /c $line | Out-Null
$analyzeExit = $LASTEXITCODE

$log = @(Get-Content $analyzeLog -ErrorAction SilentlyContinue)
$diagnostics = @($log | Where-Object { $_ -match '\.luau\(\d+,\d+\)\s*:' -or $_ -match '^\[ERROR\]' })

if ($diagnostics.Count -gt 0 -or $analyzeExit -ne 0) {
    Write-Host "[4/4] luau-lsp     : FAILED ($($diagnostics.Count) diagnostics, exit $analyzeExit)" -ForegroundColor Red
    $diagnostics | ForEach-Object { Write-Host "      $_" }
    exit 1
}
Write-Host "[4/4] luau-lsp     : 0 diagnostics" -ForegroundColor Green

Write-Host ''
Write-Host 'gate: PASS' -ForegroundColor Green
exit 0
