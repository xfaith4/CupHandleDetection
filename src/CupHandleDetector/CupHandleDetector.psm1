# src/CupHandleDetector/CupHandleDetector.psm1
# Root module: dot-sources private/public function scripts and exports the public API.

Set-StrictMode -Version Latest

$script:ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function script:Get-CHDScriptFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    return @(Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File -Recurse | Sort-Object FullName)
}

# Load internals first, then public functions
$privatePath = Join-Path $script:ModuleRoot 'Private'
$publicPath  = Join-Path $script:ModuleRoot 'Public'

foreach ($file in @((Get-CHDScriptFiles -Path $privatePath) + (Get-CHDScriptFiles -Path $publicPath))) {
    $scriptFile = $file.FullName
    try {
        . $scriptFile
    }
    catch {
        throw "Failed dot-sourcing '$scriptFile': $($_.Exception.Message)"
    }
}

# Export the public API surface (keep in sync with manifest)
Export-ModuleMember -Function @(
    'Compute-Indicators',
    'Confirm-Breakout',
    'ConvertTo-OhlcvSeries',
    'Detect-Stages',
    'Emit-CHDAlert',
    'Persist-CHDHistory',
    'Resample-Ohlcv'
)

# Intentionally do not export internal helper functions from Private/
