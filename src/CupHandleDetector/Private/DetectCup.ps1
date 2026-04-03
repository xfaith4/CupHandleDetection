# src/CupHandleDetector/Private/DetectCup.ps1
```powershell
# src/CupHandleDetector/Private/DetectCup.ps1
# Cup candidate detection:
# - Depth constraints (peak-to-trough drawdown)
# - Duration constraints (left+right window lengths)
# - Symmetry constraint (left vs right duration similarity)
# - Curvature proxy (how "rounded" vs "V-shaped" the cup is)
#
# This file is intended to be consumed by a higher-level orchestrator.
# It does not attempt to detect the handle; only the cup candidate.

Set-StrictMode -Version Latest

function _IsFiniteNumberCup {
    param([object]$x)
    if ($null -eq $x) { return $false }
    try {
        $d = [double]$x
        return -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
    } catch { return $false }
}

function _ToDoubleOrNullCup {
    param([object]$x)
    if (-not (_IsFiniteNumberCup $x)) { return $null }
    return [double]$x
}

function _Clamp01Cup {
    param([double]$x)
    if ($x -lt 0) { return 0.0 }
    if ($x -gt 1) { return 1.0 }
    return $x
}

function _ArgMaxInRangeCup {
    param(
        [double[]]$Arr,
        [int]$Start,
        [int]$End
    )
    $bestI = $null
    $bestV = [double]::NegativeInfinity
    for ($i=$Start; $i -le $End; $i++) {
        $v = $Arr[$i]
        if ([double]::IsNaN($v)) { continue }
        if ($v -gt $bestV) { $bestV = $v; $bestI = $i }
    }
    return $bestI
}

function _ArgMinInRangeCup {
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

function _LocalPeakCup {
    param(
        [double[]]$Arr,
        [int]$Center,
        [int]$Radius
    )
    $n = $Arr.Count
    $s = [Math]::Max(0, $Center - $Radius)
    $e = [Math]::Min($n-1, $Center + $Radius)
    return _ArgMaxInRangeCup -Arr $Arr -Start $s -End $e
}

function _LocalTroughCup {
    param(
        [double[]]$Arr,
        [int]$Center,
        [int]$Radius
    )
    $n = $Arr.Count
    $s = [Math]::Max(0, $Center - $Radius)
    $e = [Math]::Min($n-1, $Center + $Radius)
    return _ArgMinInRangeCup -Arr $Arr -Start $s -End $e
}

function Detect-CupCandidates {
    [CmdletBinding()]
    param(
        # Price arrays (Close required; High/Low optional but recommended)
        [Parameter(Mandatory)] [object[]]$Close,
        [object[]]$High,
        [object[]]$Low,
        [object[]]$Time,

        # Config dictionary (mirrors config/defaults.json-ish structure)
        [hashtable]$Config = @{}
    )

    # ---- Defaults (safe fallbacks) ----
    function _TryGetCup {
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

    $n = $Close.Count
    if ($n -le 0) {
        return [pscustomobject]@{
            Meta       = @{ Status='EMPTY'; Bars=0 }
            Candidates = @()
        }
    }

    # Cup scan windows
    $minCupBars = [int](_TryGetCup $Config 'patterns.cup.min_cup_bars' 30)
    $maxCupBars = [int](_TryGetCup $Config 'patterns.cup.max_cup_bars' 260)

    # Pivot search radii (to find local left/right peaks around endpoints)
    $peakRadius = [int](_TryGetCup $Config 'patterns.cup.peak_radius_bars' 5)
    $troughRadius = [int](_TryGetCup $Config 'patterns.cup.trough_radius_bars' 5)

    # Depth constraints (as fraction of peak)
    $minDepthPct = [double](_TryGetCup $Config 'patterns.cup.depth.min_pct' 0.12)  # 12%
    $maxDepthPct = [double](_TryGetCup $Config 'patterns.cup.depth.max_pct' 0.50)  # 50%

    # Symmetry constraint: max |L-R|/((L+R)/2)
    $maxAsym = [double](_TryGetCup $Config 'patterns.cup.symmetry.max_asymmetry' 0.60)

    # Rim similarity: right rim should be close to left rim (not mandatory breakout)
    $minRimRecover = [double](_TryGetCup $Config 'patterns.cup.rim.min_recovery_frac' 0.80) # rightPeak >= leftPeak*0.8

    # Curvature proxy: require some rounding (avoid sharp V)
    $minCurvature = [double](_TryGetCup $Config 'patterns.cup.curvature.min_score' 0.20)

    # Step: how many bars to advance the left anchor while scanning
    $leftStep = [int](_TryGetCup $Config 'patterns.cup.scan.left_step' 1)

    # Limit candidates to avoid blowups
    $maxCandidates = [int](_TryGetCup $Config 'patterns.cup.scan.max_candidates' 200)

    # ---- Normalize to double arrays with NaN for invalid ----
    $c = New-Object double[] $n
    $h = $null
    $l = $null
    if ($null -ne $High -and $High.Count -eq $n) { $h = New-Object double[] $n }
    if ($null -ne $Low  -and $Low.Count  -eq $n) { $l = New-Object double[] $n }

    for ($i=0; $i -lt $n; $i++) {
        $cd = _ToDoubleOrNullCup $Close[$i]
        $c[$i] = if ($null -eq $cd) { [double]::NaN } else { $cd }

        if ($null -ne $h) {
            $hd = _ToDoubleOrNullCup $High[$i]
            $h[$i] = if ($null -eq $hd) { [double]::NaN } else { $hd }
        }
        if ($null -ne $l) {
            $ld = _ToDoubleOrNullCup $Low[$i]
            $l[$i] = if ($null -eq $ld) { [double]::NaN } else { $ld }
        }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $status = 'OK'
    $issues = New-Object System.Collections.Generic.List[string]

    if ($n -lt $minCupBars + 2) {
        $status = 'INSUFFICIENT_DATA'
        $issues.Add("Need at least min_cup_bars=$minCupBars; got $n.")
        return [pscustomobject]@{
            Meta       = @{ Status=$status; Bars=$n; Issues=$issues }
            Candidates = @()
        }
    }

    # ---- Main scan ----
    # We treat i as tentative left rim index; j as tentative right rim index.
    # For each (i,j) window, find:
    # - leftPeak: local peak near i
    # - rightPeak: local peak near j
    # - trough: local trough between them
    # Then apply constraints.
    for ($i=0; $i -lt $n - $minCupBars; $i += $leftStep) {
        if ($candidates.Count -ge $maxCandidates) { break }
        if ([double]::IsNaN($c[$i])) { continue }

        $jMin = $i + $minCupBars
        $jMax = [Math]::Min($n-1, $i + $maxCupBars)

        # To reduce compute, we can try a few right endpoints rather than all.
        # But keep it deterministic: test all endpoints with a modest stride when long.
        $range = $jMax - $jMin + 1
        $jStride = if ($range -gt 200) { 2 } else { 1 }

        for ($j=$jMin; $j -le $jMax; $j += $jStride) {
            if ($candidates.Count -ge $maxCandidates) { break }
            if ([double]::IsNaN($c[$j])) { continue }

            # Local rim peaks around endpoints (on Close)
            $leftPeakI  = _LocalPeakCup -Arr $c -Center $i -Radius $peakRadius
            $rightPeakI = _LocalPeakCup -Arr $c -Center $j -Radius $peakRadius
            if ($null -eq $leftPeakI -or $null -eq $rightPeakI) { continue }
            if ($rightPeakI -le $leftPeakI + 5) { continue }

            $leftPeak  = $c[$leftPeakI]
            $rightPeak = $c[$rightPeakI]
            if ([double]::IsNaN($leftPeak) -or [double]::IsNaN($rightPeak)) { continue }
            if ($leftPeak -le 0 -or $rightPeak -le 0) { continue }

            # Rim recovery constraint
            if ($rightPeak -lt ($minRimRecover * $leftPeak)) { continue }

            # Find trough between peaks using Low if available, else Close
            $troughArr = if ($null -ne $l) { $l } else { $c }
            $midTroughI = _ArgMinInRangeCup -Arr $troughArr -Start $leftPeakI -End $rightPeakI
            if ($null -eq $midTroughI) { continue }
            $troughI = _LocalTroughCup -Arr $troughArr -Center $midTroughI -Radius $troughRadius
            if ($null -eq $troughI) { continue }

            $trough = $troughArr[$troughI]
            if ([double]::IsNaN($trough)) { continue }
            if ($trough -le 0) { continue }

            # Depth vs average rim (more stable than using one rim)
            $rimAvg = 0.5 * ($leftPeak + $rightPeak)
            if ($rimAvg -le 0) { continue }

            $depthPct = ($rimAvg - $trough) / $rimAvg
            if ($depthPct -lt $minDepthPct -or $depthPct -gt $maxDepthPct) { continue }

            # Duration split and symmetry
            $leftDur  = $troughI - $leftPeakI
            $rightDur = $rightPeakI - $troughI
            if ($leftDur -le 2 -or $rightDur -le 2) { continue }

            $totalDur = $rightPeakI - $leftPeakI
            if ($totalDur -lt $minCupBars -or $totalDur -gt $maxCupBars) { continue }

            $avgDur = 0.5 * ($leftDur + $rightDur)
            $asym = [Math]::Abs($leftDur - $rightDur) / [Math]::Max(1.0, $avgDur)
            if ($asym -gt $maxAsym) { continue }

            # ---- Curvature proxy (rounded bottom vs V) ----
            # Compute the "sag area" relative to a straight line between rims:
            #   baseline(t) = leftPeak + (rightPeak-leftPeak)*t
            # sag = mean( (baseline - price) / rimAvg ) for points between rims, clipped at 0
            # Then normalize by depthPct to penalize V-shapes:
            # curvatureScore = sag / depthPct (bounded 0..1-ish)
            #
            # Use Close as the body series (avoid low wicks dominating curvature).
            $sumSag = 0.0
            $countSag = 0
            $span = [Math]::Max(1, ($rightPeakI - $leftPeakI))
            for ($k=$leftPeakI; $k -le $rightPeakI; $k++) {
                $pk = $c[$k]
                if ([double]::IsNaN($pk)) { continue }
                $t = ($k - $leftPeakI) / [double]$span
                $baseline = $leftPeak + ($rightPeak - $leftPeak) * $t
                $sag = ($baseline - $pk) / $rimAvg
                if ($sag -lt 0) { $sag = 0 }
                $sumSag += $sag
                $countSag++
            }
            if ($countSag -lt 5) { continue }
            $meanSag = $sumSag / $countSag

            $curvatureScore = if ($depthPct -gt 1e-9) { $meanSag / $depthPct } else { 0.0 }
            if ($curvatureScore -lt $minCurvature) { continue }

            # Candidate score: prefer moderate depth, good symmetry, good curvature, strong rim recovery
            $symScore = 1.0 - _Clamp01Cup $asym
            $recoverScore = _Clamp01Cup (($rightPeak / $leftPeak - $minRimRecover) / [Math]::Max(1e-9, 1.0 - $minRimRecover))
            $depthScore = 1.0 - [Math]::Abs($depthPct - 0.28) / 0.28
            $depthScore = _Clamp01Cup $depthScore
            $curvScore = _Clamp01Cup $curvatureScore

            $score = (0.30 * $symScore) + (0.30 * $curvScore) + (0.25 * $depthScore) + (0.15 * $recoverScore)

            $candidates.Add([pscustomobject]@{
                LeftRimIndex   = $leftPeakI
                BottomIndex    = $troughI
                RightRimIndex  = $rightPeakI

                LeftRimPrice   = $leftPeak
                BottomPrice    = $trough
                RightRimPrice  = $rightPeak

                DepthPct       = [double]$depthPct
                TotalBars      = [int]$totalDur
                LeftBars       = [int]$leftDur
                RightBars      = [int]$rightDur
                Asymmetry      = [double]$asym

                CurvatureProxy = [double]$curvatureScore
                MeanSag        = [double]$meanSag

                Score          = [double]$score

                # Optional time stamps if provided
                LeftTime       = if ($null -ne $Time -and $Time.Count -eq $n) { $Time[$leftPeakI] } else { $null }
                BottomTime     = if ($null -ne $Time -and $Time.Count -eq $n) { $Time[$troughI] } else { $null }
                RightTime      = if ($null -ne $Time -and $Time.Count -eq $n) { $Time[$rightPeakI] } else { $null }
            })

            # Avoid producing many near-duplicates: after finding a good candidate for this left rim,
            # skip ahead a bit on right endpoint.
            $j += [Math]::Max(0, [int]([Math]::Floor($totalDur / 6)))
        }
    }

    # Sort candidates by Score descending, then by recency (right rim index)
    $sorted = $candidates.ToArray() | Sort-Object -Property @{Expression='Score';Descending=$true}, @{Expression='RightRimIndex';Descending=$true}

    return [pscustomobject]@{
        Meta = @{
            Status        = $status
            Bars          = $n
            CandidateCount= $sorted.Count
            Issues        = $issues
            Params        = @{
                minCupBars     = $minCupBars
                maxCupBars     = $maxCupBars
                minDepthPct    = $minDepthPct
                maxDepthPct    = $maxDepthPct
                maxAsymmetry   = $maxAsym
                minRimRecover  = $minRimRecover
                minCurvature   = $minCurvature
                peakRadiusBars = $peakRadius
                troughRadiusBars = $troughRadius
                maxCandidates  = $maxCandidates
            }
        }
        Candidates = $sorted
    }
}