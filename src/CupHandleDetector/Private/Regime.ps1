# src/CupHandleDetector/Private/Regime.ps1
# ATR-percentile market regime helper.

Set-StrictMode -Version Latest

$script:_regimeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:_regimeDir 'Atr.ps1')

function Get-RegimeSignal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $High,
        [Parameter(Mandatory)][object[]] $Low,
        [Parameter(Mandatory)][object[]] $Close,
        [ValidateRange(1, [int]::MaxValue)][int] $AtrPeriod = 14,
        [ValidateRange(1, [int]::MaxValue)][int] $PercentileWindow = 100,
        [ValidateRange(1, [int]::MaxValue)][int] $MinPeriods = $PercentileWindow,
        [ValidateSet('Linear','Lower','Higher','Nearest','Rank')][string] $Interpolation = 'Rank'
    )

    $atr = Get-Atr -High $High -Low $Low -Close $Close -Period $AtrPeriod
    $out = New-Object object[] $atr.Count

    for ($i = 0; $i -lt $atr.Count; $i++) {
        if ($i -lt ($PercentileWindow - 1) -or $null -eq $atr[$i]) {
            $out[$i] = $null
            continue
        }

        $start = $i - $PercentileWindow + 1
        $valid = @()
        for ($j = $start; $j -le $i; $j++) {
            if ($null -ne $atr[$j]) { $valid += [double]$atr[$j] }
        }

        if ($valid.Count -lt $MinPeriods) {
            $out[$i] = $null
            continue
        }

        $current = [double]$atr[$i]
        $lessOrEqual = @($valid | Where-Object { $_ -le $current }).Count
        $rank = [double]$lessOrEqual / [double]$valid.Count
        if ($rank -lt 0) { $rank = 0.0 }
        if ($rank -gt 1) { $rank = 1.0 }
        $out[$i] = $rank
    }

    return $out
}

function Get-Regime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $High,
        [Parameter(Mandatory)][object[]] $Low,
        [Parameter(Mandatory)][object[]] $Close,
        [ValidateRange(1, [int]::MaxValue)][int] $Window = 100,
        [ValidateRange(1, [int]::MaxValue)][int] $AtrPeriod = 14
    )

    [pscustomobject]@{
        R = Get-RegimeSignal -High $High -Low $Low -Close $Close -AtrPeriod $AtrPeriod -PercentileWindow $Window -MinPeriods $Window
    }
}
