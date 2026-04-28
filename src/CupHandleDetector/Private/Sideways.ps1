# src/CupHandleDetector/Private/Sideways.ps1
# Sideways / consolidation metrics
# - Rolling width: rolling (max - min) over a window (O(N) using monotonic deques)
# - WeeksSidewaysAtBottom: consecutive-week counter for "sideways at bottom" condition
#
# Conventions:
# - Inputs: [object[]] of prices (castable to [double]); $null/NaN/Inf treated as missing
# - Outputs: [object[]] aligned to input length; values are [double]/[int] or $null when insufficient data
# - Missing values break the running logic (emit $null and reset counters)
#
# Notes:
# - Rolling width uses only valid points in the last W positions.
# - MinPeriods controls minimum valid observations required to emit a width.

Set-StrictMode -Version Latest

function _IsValidNumber {
    param([object]$x)
    if ($null -eq $x) { return $false }
    try {
        $d = [double]$x
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Get-RollingWidth {
    <#
    .SYNOPSIS
    Rolling width (max - min) over a fixed window.

    .PARAMETER Values
    Sequence of prices.

    .PARAMETER Window
    Window size in observations (e.g., 5 for 5 trading days, 10, etc.).

    .PARAMETER MinPeriods
    Minimum number of valid observations within the last Window positions required
    to emit a value. Default = Window.

    .OUTPUTS
    object[] aligned to input length (double or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Values,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Window,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MinPeriods = $Window
    )

    $n = $Values.Count
    $out = New-Object object[] $n

    # Monotonic deques for max and min:
    # Each entry is a 2-item array: @(index, value)
    $dqMax = [System.Collections.Generic.List[object]]::new()
    $dqMin = [System.Collections.Generic.List[object]]::new()

    # Track valid count within the window
    $validInWindow = 0
    $validFlags = New-Object bool[] $Window

    for ($i = 0; $i -lt $n; $i++) {
        $slot = $i % $Window

        # Remove outgoing validity
        if ($i -ge $Window) {
            if ($validFlags[$slot]) { $validInWindow-- }
            $validFlags[$slot] = $false
        }

        # Expire old indices from fronts (older than i-Window+1)
        $minIdxAllowed = $i - $Window + 1
        while ($dqMax.Count -gt 0 -and [int]$dqMax[0][0] -lt $minIdxAllowed) {
            $dqMax.RemoveAt(0)
        }
        while ($dqMin.Count -gt 0 -and [int]$dqMin[0][0] -lt $minIdxAllowed) {
            $dqMin.RemoveAt(0)
        }

        $v = $Values[$i]
        if (-not (_IsValidNumber $v)) {
            # Missing breaks value emission for this index; keep state but it naturally decays as indices expire.
            $out[$i] = $null
            continue
        }

        $dv = [double]$v
        $validFlags[$slot] = $true
        $validInWindow++

        # Push to max deque (descending values)
        while ($dqMax.Count -gt 0) {
            $last = $dqMax[$dqMax.Count - 1]
            if ([double]$last[1] -ge $dv) { break }
            $dqMax.RemoveAt($dqMax.Count - 1)
        }
        $dqMax.Add(@($i, $dv))

        # Push to min deque (ascending values)
        while ($dqMin.Count -gt 0) {
            $last = $dqMin[$dqMin.Count - 1]
            if ([double]$last[1] -le $dv) { break }
            $dqMin.RemoveAt($dqMin.Count - 1)
        }
        $dqMin.Add(@($i, $dv))

        # Ensure fronts are not expired after pushes (edge cases)
        while ($dqMax.Count -gt 0 -and [int]$dqMax[0][0] -lt $minIdxAllowed) { $dqMax.RemoveAt(0) }
        while ($dqMin.Count -gt 0 -and [int]$dqMin[0][0] -lt $minIdxAllowed) { $dqMin.RemoveAt(0) }

        if ($validInWindow -ge $MinPeriods -and $dqMax.Count -gt 0 -and $dqMin.Count -gt 0) {
            $out[$i] = [double]$dqMax[0][1] - [double]$dqMin[0][1]
        } else {
            $out[$i] = $null
        }
    }

    return $out
}

function Get-WeeksSidewaysAtBottom {
    <#
    .SYNOPSIS
    Compute consecutive "weeks sideways at bottom" count.

    .DESCRIPTION
    For each week i, emits an integer count of consecutive weeks up to i where:
      1) The rolling width over BottomWindow weeks is below a sideways threshold, AND
      2) The current price is in the bottom part of the recent range (BottomBandPercent).

    Missing/invalid values reset the counter and emit $null.

    .PARAMETER Close
    Weekly close series (or any representative weekly price).

    .PARAMETER BottomWindow
    Lookback window (in weeks) for defining the "bottom" region and width.

    .PARAMETER SidewaysMaxWidthPct
    Sideways threshold: (rollingWidth / rollingMax) must be <= this value.
    Example: 0.12 means the range is <= 12% of the max in the window.

    .PARAMETER BottomBandPercent
    Bottom region height as a fraction of recent range.
    Example: 0.25 means bottom 25% of [min,max] range.

    .PARAMETER MinPeriods
    Minimum valid periods required to evaluate conditions. Default = BottomWindow.

    .OUTPUTS
    object[] aligned: [int] count, or $null when not enough history / missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Close,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$BottomWindow = 10,

        [ValidateRange(0.0, 10.0)]
        [double]$SidewaysMaxWidthPct = 0.12,

        [ValidateRange(0.0, 1.0)]
        [double]$BottomBandPercent = 0.25,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MinPeriods = $BottomWindow
    )

    $n = $Close.Count
    $out = New-Object object[] $n

    # We need rolling min, max, and width. Width can be derived from min/max, but
    # we already have an O(N) width; for bottom band we also need min/max.
    # Compute min/max using the same deque approach inline for efficiency.

    $dqMax = [System.Collections.Generic.List[object]]::new()
    $dqMin = [System.Collections.Generic.List[object]]::new()

    $validInWindow = 0
    $validFlags = New-Object bool[] $BottomWindow

    $runCount = 0

    for ($i = 0; $i -lt $n; $i++) {
        $slot = $i % $BottomWindow

        if ($i -ge $BottomWindow) {
            if ($validFlags[$slot]) { $validInWindow-- }
            $validFlags[$slot] = $false
        }

        $minIdxAllowed = $i - $BottomWindow + 1

        while ($dqMax.Count -gt 0 -and [int]$dqMax[0][0] -lt $minIdxAllowed) { $dqMax.RemoveAt(0) }
        while ($dqMin.Count -gt 0 -and [int]$dqMin[0][0] -lt $minIdxAllowed) { $dqMin.RemoveAt(0) }

        $v = $Close[$i]
        if (-not (_IsValidNumber $v)) {
            $out[$i] = $null
            $runCount = 0
            continue
        }

        $dv = [double]$v
        $validFlags[$slot] = $true
        $validInWindow++

        # Update deques
        while ($dqMax.Count -gt 0) {
            $last = $dqMax[$dqMax.Count - 1]
            if ([double]$last[1] -ge $dv) { break }
            $dqMax.RemoveAt($dqMax.Count - 1)
        }
        $dqMax.Add(@($i, $dv))

        while ($dqMin.Count -gt 0) {
            $last = $dqMin[$dqMin.Count - 1]
            if ([double]$last[1] -le $dv) { break }
            $dqMin.RemoveAt($dqMin.Count - 1)
        }
        $dqMin.Add(@($i, $dv))

        while ($dqMax.Count -gt 0 -and [int]$dqMax[0][0] -lt $minIdxAllowed) { $dqMax.RemoveAt(0) }
        while ($dqMin.Count -gt 0 -and [int]$dqMin[0][0] -lt $minIdxAllowed) { $dqMin.RemoveAt(0) }

        if ($validInWindow -lt $MinPeriods -or $dqMax.Count -eq 0 -or $dqMin.Count -eq 0) {
            $out[$i] = $null
            $runCount = 0
            continue
        }

        $wMax = [double]$dqMax[0][1]
        $wMin = [double]$dqMin[0][1]
        $width = $wMax - $wMin

        # Guards
        if ($wMax -le 0.0) {
            $out[$i] = $null
            $runCount = 0
            continue
        }

        $widthPct = $width / $wMax

        $bottomThreshold = $wMin + ($BottomBandPercent * $width)
        $isInBottomBand = ($dv -le $bottomThreshold)

        $isSideways = ($widthPct -le $SidewaysMaxWidthPct)

        if ($isSideways -and $isInBottomBand) {
            $runCount++
            $out[$i] = $runCount
        } else {
            $runCount = 0
            $out[$i] = 0
        }
    }

    return $out
}
