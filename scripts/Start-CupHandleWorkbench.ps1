# Launches the Cup & Handle workbench UI from the repository root.

[CmdletBinding()]
param(
    [switch] $Install,
    [switch] $Build
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$UiRoot = Join-Path $RepoRoot 'ui/workbench'
$PackageJson = Join-Path $UiRoot 'package.json'
$NodeModules = Join-Path $UiRoot 'node_modules'
$ConcurrentlyBin = Join-Path $UiRoot 'node_modules/.bin/concurrently'
$ConcurrentlyCmd = Join-Path $UiRoot 'node_modules/.bin/concurrently.cmd'
$ViteBin = Join-Path $UiRoot 'node_modules/.bin/vite'
$ViteCmd = Join-Path $UiRoot 'node_modules/.bin/vite.cmd'

if (-not (Test-Path -LiteralPath $PackageJson)) {
    throw "Workbench package.json not found at $PackageJson"
}

if (
    $Install -or
    -not (Test-Path -LiteralPath $NodeModules) -or
    (-not (Test-Path -LiteralPath $ConcurrentlyBin) -and -not (Test-Path -LiteralPath $ConcurrentlyCmd)) -or
    (-not (Test-Path -LiteralPath $ViteBin) -and -not (Test-Path -LiteralPath $ViteCmd))
) {
    & npm --prefix $UiRoot install
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if ($Build) {
    & npm --prefix $UiRoot run build
    exit $LASTEXITCODE
}

& npm --prefix $UiRoot run dev
exit $LASTEXITCODE
