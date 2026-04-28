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

if (-not (Test-Path -LiteralPath $PackageJson)) {
    throw "Workbench package.json not found at $PackageJson"
}

if ($Install -or -not (Test-Path -LiteralPath $NodeModules)) {
    & npm --prefix $UiRoot install
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if ($Build) {
    & npm --prefix $UiRoot run build
    exit $LASTEXITCODE
}

& npm --prefix $UiRoot run dev
exit $LASTEXITCODE
