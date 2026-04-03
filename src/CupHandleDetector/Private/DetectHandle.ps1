# src/CupHandleDetector/Private/DetectHandle.ps1
# Handle detection for Cup-with-Handle pattern.
#
# Requirements implemented:
# - Time bounds: min/max handle duration; optional bound for how long after right rim handle may start
# - Depth bounds: handle pullback depth relative to right rim
# - Midpoint rule: handle should stay in upper half of cup depth (configurable)
# - Volume contraction trend: handle volume should contract over time (early > late)
#
# This file is intended to be consumed by a higher-level orchestrator which:
# - Computes indicators
# - Detects cup candidates (DetectCup.ps1)
# - Then applies handle detection to cup candidates
#
# Input:
#   Close/High/Low/Volume arrays aligned to bars
#   CupCandidates: output objects from Detect-CupCandidates (Candidates entries)
#
# Output:
#   PSCustomObject @{ Meta = @{...}; Handles = object[] }

Set-StrictMode -Version Latest

function _IsFiniteNumberHandle {
    param([object]$x)
    if ($null -eq $x) { return $false }
    try {
        $d = [double]$x
        return -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
    } catch { return $false }
}

function _ToDoubleOrNaNHandle {
    param([object]$x)
    if (-not (_IsFiniteNumberHandle $x)) { return [double]::NaN }
    return [double]$x
}

function _TryGetHandle {
    param([hashtable]$Table, [string]$Path, $Fallback)
    $cur = $Table
    foreach ($k in $Path.Split('.')) {
        if ($null -eq $cur) { return $Fallback }
        if ($cur -isnot [System.Collections.IDictionary]) { return $Fallback }
        if (-not $cur.Contains($k)) { return $Fallback }
        $cur = $cur[$k]
    }
    if ($null -eq $cur) { return $Fallback }
    return $cur
}

function _ArgMinInRangeHandle {
    param(
        [double[]]$Arr,
        [int]$Start,
        [int]$End
    )
    $bestI = $null
    $bestV = [double]::PositiveInfinity
    for ($i=$Start; $i -le $End; $i++) {
        $v = $Arr[$i]
        if ([double]::IsNaN($v)) { continue }
        if ($v -lt $bestV) { $bestV = $v; $bestI = $i }
    }
    return $bestI
}

function _MedianHandle {
    param([double[]]$Arr, [int]$Start, [int]$End)
    if ($End -lt $Start) { return $null }
    $tmp = New-Object System.Collections.Generic.List[double]
    for ($i=$Start; $i -le $End; $i++) {
        $v = $Arr[$i]
        if ([double]::IsNaN($v)) { continue }
        $tmp.Add($v)
    }
    if ($tmp.Count -eq 0) { return $null }
    $sorted = $tmp.ToArray()
    [Array]::Sort($sorted)
    $m = [int][Math]::Floor(($sorted.Length - 1) / 2)
    if ($sorted.Length % 2 -eq 1) {
        return [double]$sorted[$m]
    } else {
        return ([double]$sorted[$m] + [double]$sorted[$m+1]) / 2.0
    }
}

function Detect-HandleCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]]$Close,
        [object[]]$High,
        [object[]]$Low,
        [object[]]$Volume,
        [object[]]$Time,

        # Cup candidates from Detect-CupCandidates (the .Candidates array)
        [Parameter(Mandatory)] [object[]]$CupCandidates,

        [hashtable]$Config = @{}
    )

    $n = $Close.Count
    if ($n -le 0) {
        return [pscustomobject]@{
            Meta    = @{ Status='EMPTY'; Bars=0 }
            Handles = @()
        }
    }

    # ---- Config defaults ----
    $minHandleBars = [int](_TryGetHandle $Config 'patterns.handle.min_handle_bars' 5)
    $maxHandleBars = [int](_TryGetHandle $Config 'patterns.handle.max_handle_bars' 40)

    # How long after right rim the handle is allowed to begin (0 = must start immediately)
    $maxStartDelayBars = [int](_TryGetHandle $Config 'patterns.handle.time.max_start_delay_bars' 10)

    # Depth: pullback from right rim peak
    $minDepthPct = [double](_TryGetHandle $Config 'patterns.handle.depth.min_pct' 0.01) # avoid "no handle"
    $maxDepthPct = [double](_TryGetHandle $Config 'patterns.handle.depth.max_pct' 0.12) # typical <10-15%

    # Midpoint rule: handle lows should stay above this fraction of cup depth
    # threshold = trough + midpoint_frac*(rightRim - trough)
    $midpointFrac = [double](_TryGetHandle $Config 'patterns.handle.midpoint.midpoint_frac' 0.50)
    $midpointTolerancePct = [double](_TryGetHandle $Config 'patterns.handle.midpoint.tolerance_pct' 0.01) # 1% leeway

    # Volume contraction: late median volume should be <= early median volume * max_ratio
    $requireVolContraction = [bool](_TryGetHandle $Config 'patterns.handle.volume.require_contraction' $true)
    $volMaxRatio = [double](_TryGetHandle $Config 'patterns.handle.volume.max_late_to_early_ratio' 0.90)
    $volSegmentMinBars = [int](_TryGetHandle $Config 'patterns.handle.volume.segment_min_bars' 3)

    # Candidate limiting
    $maxHandles = [int](_TryGetHandle $Config 'patterns.handle.scan.max_candidates' 200)

    # ---- Normalize arrays to double[] with NaN ----
    $c = New-Object double[] $n
    $h = $null
    $l = $null
    $v = $null

    if ($null -ne $High -and $High.Count -eq $n)   { $h = New-Object double[] $n }
    if ($null -ne $Low  -and $Low.Count  -eq $n)   { $l = New-Object double[] $n }
    if ($null -ne $Volume -and $Volume.Count -eq $n) { $v = New-Object double[] $n }

    for ($i=0; $i -lt $n; $i++) {
        $c[$i] = _ToDoubleOrNaNHandle $Close[$i]
        if ($null -ne $h) { $h[$i] = _ToDoubleOrNaNHandle $High[$i] }
        if ($null -ne $l) { $l[$i] = _ToDoubleOrNaNHandle $Low[$i] }
        if ($null -ne $v) { $v[$i] = _ToDoubleOrNaNHandle $Volume[$i] }
    }

    $handles = New-Object System.Collections.Generic.List[object]
    $issues = New-Object System.Collections.Generic.List[string]
    $status = 'OK'

    if ($CupCandidates.Count -eq 0) {
        return [pscustomobject]@{
            Meta    = @{ Status='NO_CUPS'; Bars=$n }
            Handles = @()
        }
    }

    if ($n -lt ($minHandleBars + 3)) {
        $status = 'INSUFFICIENT_DATA'
        $issues.Add("Need at least min_handle_bars=$minHandleBars; got $n.")
        return [pscustomobject]@{
            Meta    = @{ Status=$status; Bars=$n; Issues=$issues }
            Handles = @()
        }
    }

    foreach ($cup in $CupCandidates) {
        if ($handles.Count -ge $maxHandles) { break }

        # Expect indices from DetectCup:
        # leftPeakI, rightPeakI, troughI and prices leftPeak, rightPeak, trough
        $leftPeakI  = $cup.LeftPeakIndex
        $rightPeakI = $cup.RightPeakIndex
        $troughI    = $cup.TroughIndex

        if ($null -eq $leftPeakI -or $null -eq $rightPeakI -or $null -eq $troughI) { continue }

        $leftPeakI  = [int]$leftPeakI
        $rightPeakI = [int]$rightPeakI
        $troughI    = [int]$troughI

        if ($rightPeakI -ge $n-1) { continue }
        if ($rightPeakI -le $troughI) { continue }

        $rightRim = $c[$rightPeakI]
        $trough  = $c[$troughI]
        if ([double]::IsNaN($rightRim) -or [double]::IsNaN($trough)) { continue }
        if ($rightRim -le 0) { continue }

        $cupDepth = ($rightRim - $trough)
        if ($cupDepth -le 0) { continue }

        # Midpoint threshold (cup upper half rule)
        $midThresh = $trough + ($midpointFrac * $cupDepth)
        $midThreshAdj = $midThresh * (1.0 - $midpointTolerancePct)

        # Handle start window bounds
        $startMin = $rightPeakI + 1
        $startMax = [Math]::Min($n-1, $rightPeakI + [Math]::Max(0, $maxStartDelayBars))
        if ($startMin -gt $n-1) { continue }

        # Try a few plausible starts; simplest: evaluate each start, and for each, try handle end lengths
        for ($hs = $startMin; $hs -le $startMax; $hs++) {
            if ($handles.Count -ge $maxHandles) { break }
            if ([double]::IsNaN($c[$hs])) { continue }

            $endMin = $hs + $minHandleBars - 1
            $endMax = [Math]::Min($n-1, $hs + $maxHandleBars - 1)
            if ($endMin -gt $n-1) { continue }

            # Evaluate possible handle ends; choose the first that satisfies all constraints
            $accepted = $false
            for ($he = $endMin; $he -le $endMax; $he++) {
                if ($handles.Count -ge $maxHandles) { break }
                if ([double]::IsNaN($c[$he])) { continue }

                # Use Low if available to measure handle drawdown; else Close
                $ddArr = if ($null -ne $l) { $l } else { $c }
                $lowI = _ArgMinInRangeHandle -Arr $ddArr -Start $hs -End $he
                if ($null -eq $lowI) { continue }
                $low = $ddArr[$lowI]
                if ([double]::IsNaN($low)) { continue }

                $depthPct = ($rightRim - $low) / $rightRim
                $passDepth = ($depthPct -ge $minDepthPct -and $depthPct -le $maxDepthPct)

                # Midpoint rule: lowest low of handle should be above mid threshold (with tolerance)
                $passMidpoint = ($low -ge $midThreshAdj)

                # Volume contraction: compare early vs late medians inside handle
                $volDiag = $null
                $passVol = $true
                if ($requireVolContraction) {
                    if ($null -eq $v) {
                        $passVol = $false
                        $volDiag = @{ Status='NO_VOLUME' }
                    } else {
                        $len = $he - $hs + 1
                        # Split into early and late segments
                        $seg = [Math]::Max($volSegmentMinBars, [int][Math]::Floor($len / 2))
                        if ($len -lt (2 * $volSegmentMinBars)) {
                            # Short handle: fallback heuristic - require last volume <= first volume (if both finite)
                            $v0 = $v[$hs]
                            $v1 = $v[$he]
                            if ([double]::IsNaN($v0) -or [double]::IsNaN($v1) -or $v0 -le 0) {
                                $passVol = $false
                                $volDiag = @{ Status='INSUFFICIENT_VOLUME_DATA'; Len=$len }
                            } else {
                                $ratio = $v1 / $v0
                                $passVol = ($ratio -le 1.0)
                                $volDiag = @{ Status='SHORT_FALLBACK'; First=$v0; Last=$v1; Ratio=$ratio }
                            }
                        } else {
                            $earlyS = $hs
                            $earlyE = $hs + $seg - 1
                            $lateS  = $he - $seg + 1
                            $lateE  = $he

                            $medEarly = _MedianHandle -Arr $v -Start $earlyS -End $earlyE
                            $medLate  = _MedianHandle -Arr $v -Start $lateS  -End $lateE
                            if ($null -eq $medEarly -or $null -eq $medLate -or $medEarly -le 0) {
                                $passVol = $false
                                $volDiag = @{ Status='INSUFFICIENT_VOLUME_DATA'; Len=$len; Seg=$seg; MedEarly=$medEarly; MedLate=$medLate }
                            } else {
                                $ratio = [double]$medLate / [double]$medEarly
                                $passVol = ($ratio -le $volMaxRatio)
                                $volDiag = @{ Status='OK'; Len=$len; Seg=$seg; MedEarly=$medEarly; MedLate=$medLate; Ratio=$ratio; MaxRatio=$volMaxRatio }
                            }
                        }
                    }
                }

                $passAll = ($passDepth -and $passMidpoint -and $passVol)
                if (-not $passAll) { continue }

                # Accepted handle candidate for this cup
                $handleObj = [pscustomobject]@{
                    Cup = @{
                        LeftPeakIndex  = $leftPeakI
                        RightPeakIndex = $rightPeakI
                        TroughIndex    = $troughI
                        RightRim       = $rightRim
                        Trough         = $trough
                        CupDepth       = $cupDepth
                        MidpointThresh = $midThresh
                    }
                    Handle = @{
                        StartIndex = $hs
                        EndIndex   = $he
                        LowIndex   = $lowI
                        Low        = $low
                        DepthPct   = $depthPct
                        Bars       = ($he - $hs + 1)
                    }
                    Checks = @{
                        TimeBoundsPassed     = $true  # implied by construction
                        DepthBoundsPassed    = $passDepth
                        MidpointRulePassed   = $passMidpoint
                        VolumeContractPassed = $passVol
                    }
                    Volume = $volDiag
                }

                $handles.Add($handleObj)
                $accepted = $true
                break
            }

            if ($accepted) { break } # don't add multiple handles per cup+start; keep first valid
        }
    }

    if ($handles.Count -eq 0) {
        $status = 'NO_HANDLES'
    }

    return [pscustomobject]@{
        Meta    = @{
            Status = $status
            Bars   = $n
            CupsIn = $CupCandidates.Count
            HandlesOut = $handles.Count
            Issues = $issues
        }
        Handles = $handles.ToArray()
    }
}