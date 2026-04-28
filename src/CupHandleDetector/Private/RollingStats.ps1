# src/CupHandleDetector/Private/RollingStats.ps1
# Small rolling statistic helpers used by volume feature calculations.

Set-StrictMode -Version Latest

function _IsValidNumberRS {
    param([object] $Value)

    if ($null -eq $Value) { return $false }
    try {
        $d = [double]$Value
        return -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
    } catch {
        return $false
    }
}

function _GetStrictRollingWindowRS {
    param(
        [Parameter(Mandatory)][object[]] $Values,
        [Parameter(Mandatory)][int] $EndIndex,
        [Parameter(Mandatory)][int] $Window
    )

    if ($EndIndex -lt ($Window - 1)) { return $null }

    $items = New-Object System.Collections.Generic.List[double]
    $start = $EndIndex - $Window + 1
    for ($i = $start; $i -le $EndIndex; $i++) {
        if (-not (_IsValidNumberRS $Values[$i])) { return $null }
        $items.Add([double]$Values[$i])
    }

    return $items.ToArray()
}

function Get-RollingMean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Values,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $Window
    )

    $out = New-Object object[] $Values.Count
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $windowValues = _GetStrictRollingWindowRS -Values $Values -EndIndex $i -Window $Window
        if ($null -eq $windowValues) {
            $out[$i] = $null
            continue
        }

        $sum = 0.0
        foreach ($value in $windowValues) { $sum += $value }
        $out[$i] = $sum / $Window
    }

    return $out
}

function Get-RollingStd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Values,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $Window,
        [switch] $Sample
    )

    $out = New-Object object[] $Values.Count
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $windowValues = _GetStrictRollingWindowRS -Values $Values -EndIndex $i -Window $Window
        if ($null -eq $windowValues) {
            $out[$i] = $null
            continue
        }

        if ($Sample -and $Window -lt 2) {
            $out[$i] = $null
            continue
        }

        $sum = 0.0
        foreach ($value in $windowValues) { $sum += $value }
        $mean = $sum / $Window

        $sumSquares = 0.0
        foreach ($value in $windowValues) {
            $delta = $value - $mean
            $sumSquares += ($delta * $delta)
        }

        $denominator = if ($Sample) { $Window - 1 } else { $Window }
        $out[$i] = [Math]::Sqrt($sumSquares / $denominator)
    }

    return $out
}

function Get-RollingMedian {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Values,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $Window
    )

    $out = New-Object object[] $Values.Count
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $windowValues = _GetStrictRollingWindowRS -Values $Values -EndIndex $i -Window $Window
        if ($null -eq $windowValues) {
            $out[$i] = $null
            continue
        }

        $sorted = @($windowValues | Sort-Object)
        $mid = [int][Math]::Floor($Window / 2)
        if (($Window % 2) -eq 1) {
            $out[$i] = [double]$sorted[$mid]
        } else {
            $out[$i] = ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0
        }
    }

    return $out
}
