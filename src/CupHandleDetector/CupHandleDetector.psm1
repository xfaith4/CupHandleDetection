# src/CupHandleDetector/CupHandleDetector.psm1
# Root module: dot-sources private/public function scripts and exports the public API.

Set-StrictMode -Version Latest

$script:ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function script:Import-CHDScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    # Deterministic ordering: alphabetical by full name
    Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            try {
                . $_.FullName
            }
            catch {
                throw "Failed dot-sourcing '$($_.FullName)': $($_.Exception.Message)"
            }
        }
}

# Load internals first, then public functions
$privatePath = Join-Path $script:ModuleRoot 'Private'
$publicPath  = Join-Path $script:ModuleRoot 'Public'

Import-CHDScripts -Path $privatePath
Import-CHDScripts -Path $publicPath

# Export the public API surface (keep in sync with manifest)
Export-ModuleMember -Function @(
    'Invoke-CHDScan',
    'Invoke-CHDAnalyze',
    'Invoke-CHDIndicators',
    'Invoke-CHDBacktest',
    'Invoke-CHDWatch'
)

# Intentionally do not export internal helper functions from Private/