# src/CupHandleDetector/Public/Confirm-Breakout.ps1
# Breakout confirmation for Cup-with-Handle pattern with:
# - Price criteria (close above pivot with optional ATR buffer and min percent)
# - Volume confirmation (zscore / percentile / surge ratio; OR/AND logic)
# - Regime-scaled thresholds (uses regime scale factor to relax/tighten thresholds)
# - Tentative breakout state (pending bars + optional follow-through close)
#
# Expected usage:
#   - Compute-Indicators -> provides Series[] snapshots with ATR, RegimeScale, VolumeZ, VolumePctl, VolumeSurgeRatio, etc.
#   - Detect-CupCandidates + Detect-HandleCandidates -> provides handle/cup geometry and pivot levels.
#   - This function validates breakout at a given bar index (or across all bars).
#
# Output:
#   PSCustomObject @{
#     Meta      = @{ Status='OK'|'EMPTY'|'INSUFFICIENT_DATA' ... }
#     Signals   = object[]  # per evaluated bar: status + evidence
#     Diagnostics = @{ Issues = string[]; ... }
#   }

Set-StrictMode -Version Latest

function _TryGetBO {
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

function _IsFiniteNumberBO {
    param([object]$x)
    if ($null -eq $x) { return $false }
    try {
        $d = [double]$x
        return -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
    } catch { return $false }
}

function _ToDoubleOrNaNBO {
    param([object]$x)
    while ($x -is [System.Array]) {
        if ($x.Count -eq 0) { return [double]::NaN }
        $x = $x[$x.Count - 1]
    }
    if (-not (_IsFiniteNumberBO $x)) { return [double]::NaN }
    return [double]$x
}

function _ClampBO {
    param([double]$x, [double]$min, [double]$max)
    if ($x -lt $min) { return $min }
    if ($x -gt $max) { return $max }
    return $x
}

function _ResolveRegimeScaleBO {
    param(
        [object]$SeriesItem,
        [hashtable]$Config
    )
    $enabled  = [bool](_TryGetBO $Config 'detection.breakout.regime_scaling.enabled' $true)
    $alpha    = [double](_TryGetBO $Config 'detection.breakout.regime_scaling.alpha' 0.4)
    $minScale = [double](_TryGetBO $Config 'detection.breakout.regime_scaling.min_scale' 0.8)
    $maxScale = [double](_TryGetBO $Config 'detection.breakout.regime_scaling.max_scale' 1.2)

    if (-not $enabled) { return 1.0 }

    # Prefer explicit regime scale from indicators if present
    # Compute-Indicators (Regime.ps1) typically returns:
    # - RegimeScale (float around 1.0)
    # - RegimeVolPercentile (0..1) (optional)
    if ($null -ne $SeriesItem -and ($SeriesItem.PSObject.Properties.Name -contains 'RegimeScale')) {
        $rs = _ToDoubleOrNaNBO $SeriesItem.RegimeScale
        if (-not [double]::IsNaN($rs) -and $rs -gt 0) {
            return _ClampBO $rs $minScale $maxScale
        }
    }

    # Fallback: if we have RegimeVolPercentile, map to [1-alpha, 1+alpha]
    if ($null -ne $SeriesItem -and ($SeriesItem.PSObject.Properties.Name -contains 'RegimeVolPercentile')) {
        $p = _ToDoubleOrNaNBO $SeriesItem.RegimeVolPercentile
        if (-not [double]::IsNaN($p)) {
            $p = _ClampBO $p 0.0 1.0
            $scale = 1.0 + $alpha * (2.0*$p - 1.0)
            return _ClampBO $scale $minScale $maxScale
        }
    }

    return 1.0
}

function _GetPivotLevelBO {
    param(
        [object]$Pattern,   # expected to be a HandleCandidate enriched with cup indices/prices
        [object[]]$High,
        [object[]]$Close,
        [int]$BarIndex,
        [hashtable]$Config
    )
    $refMode = [string](_TryGetBO $Config 'detection.breakout.reference_level' 'handle_high_or_rim')

    # Pattern is expected to include some of:
    # HandleHigh, HandleHighIndex, RightPeak (price), RightPeakIndex
    # Also may include: Pivot, PivotIndex if upstream standardized.
    $pivot = [double]::NaN
    $pivotSrc = $null

    if ($null -eq $Pattern) {
        return [pscustomobject]@{ Pivot=[double]::NaN; Source=$null }
    }

    # If upstream already computed pivot explicitly, use it.
    if ($Pattern.PSObject.Properties.Name -contains 'Pivot') {
        $pv = _ToDoubleOrNaNBO $Pattern.Pivot
        if (-not [double]::IsNaN($pv) -and $pv -gt 0) {
            return [pscustomobject]@{ Pivot=$pv; Source='pattern.pivot' }
        }
    }

    $hasHandleHigh = ($Pattern.PSObject.Properties.Name -contains 'HandleHigh')
    $hasRightRim   = ($Pattern.PSObject.Properties.Name -contains 'RightPeak')

    $handleHigh = if ($hasHandleHigh) { _ToDoubleOrNaNBO $Pattern.HandleHigh } else { [double]::NaN }
    $rightRim   = if ($hasRightRim)   { _ToDoubleOrNaNBO $Pattern.RightPeak } else { [double]::NaN }

    switch ($refMode) {
        'handle_high_or_rim' {
            if (-not [double]::IsNaN($handleHigh) -and $handleHigh -gt 0) {
                $pivot = $handleHigh; $pivotSrc = 'handle_high'
            } elseif (-not [double]::IsNaN($rightRim) -and $rightRim -gt 0) {
                $pivot = $rightRim; $pivotSrc = 'right_rim'
            }
        }
        'handle_high' {
            if (-not [double]::IsNaN($handleHigh) -and $handleHigh -gt 0) {
                $pivot = $handleHigh; $pivotSrc = 'handle_high'
            }
        }
        'right_rim' {
            if (-not [double]::IsNaN($rightRim) -and $rightRim -gt 0) {
                $pivot = $rightRim; $pivotSrc = 'right_rim'
            }
        }
        default {
            # Be permissive: behave like handle_high_or_rim
            if (-not [double]::IsNaN($handleHigh) -and $handleHigh -gt 0) {
                $pivot = $handleHigh; $pivotSrc = 'handle_high'
            } elseif (-not [double]::IsNaN($rightRim) -and $rightRim -gt 0) {
                $pivot = $rightRim; $pivotSrc = 'right_rim'
            }
        }
    }

    return [pscustomobject]@{ Pivot=$pivot; Source=$pivotSrc }
}

function _EvalVolumeConfirmBO {
    param(
        [object]$SeriesItem,
        [double]$RegimeScale,
        [hashtable]$Config
    )
    $require = [bool](_TryGetBO $Config 'detection.breakout.volume.require_confirmation' $true)
    if (-not $require) {
        return [pscustomobject]@{
            Required = $false
            Passed   = $true
            Logic    = $null
            Tests    = @()
        }
    }

    $logic = [string](_TryGetBO $Config 'detection.breakout.volume.logic' 'or') # 'or'|'and'

    $useZ   = [bool](_TryGetBO $Config 'detection.breakout.volume.use_zscore' $true)
    $usePct = [bool](_TryGetBO $Config 'detection.breakout.volume.use_percentile' $true)
    $useSur = [bool](_TryGetBO $Config 'detection.breakout.volume.use_surge_ratio' $false)

    $zThrBase   = [double](_TryGetBO $Config 'detection.breakout.volume.z_threshold' 1.5)
    $pThrBase   = [double](_TryGetBO $Config 'detection.breakout.volume.pctl_threshold' 0.85)
    $srThrBase  = [double](_TryGetBO $Config 'detection.breakout.volume.surge_ratio_threshold' 1.25)

    $scaleVol = [bool](_TryGetBO $Config 'detection.breakout.regime_scaling.scale_volume_thresholds' $true)

    # Direction: in higher vol regimes we generally want stricter confirmation, not looser.
    # So thresholds increase with RegimeScale (>1 => stricter).
    $zThr  = if ($scaleVol) { $zThrBase  * $RegimeScale } else { $zThrBase }
    $pThr  = if ($scaleVol) { 1.0 - ((1.0 - $pThrBase) / $RegimeScale) } else { $pThrBase } # pushes closer to 1 when scale>1
    $srThr = if ($scaleVol) { $srThrBase * $RegimeScale } else { $srThrBase }

    $tests = New-Object System.Collections.Generic.List[object]

    $anyEnabled = $false

    if ($useZ) {
        $anyEnabled = $true
        $z = [double]::NaN
        if ($null -ne $SeriesItem -and ($SeriesItem.PSObject.Properties.Name -contains 'VolumeZ')) {
            $z = _ToDoubleOrNaNBO $SeriesItem.VolumeZ
        } elseif ($null -ne $SeriesItem -and ($SeriesItem.PSObject.Properties.Name -contains 'VolZ')) {
            $z = _ToDoubleOrNaNBO $SeriesItem.VolZ
        }
        $pass = (-not [double]::IsNaN($z)) -and ($z -ge $zThr)
        $tests.Add([pscustomobject]@{ Name='zscore'; Enabled=$true; Value=$z; Threshold=$zThr; Passed=$pass })
    }

    if ($usePct) {
        $anyEnabled = $true
        $p = [double]::NaN
        if ($null -ne $SeriesItem -and ($SeriesItem.PSObject.Properties.Name -contains 'VolumePercentile')) {
            $p = _ToDoubleOrNaNBO $SeriesItem.VolumePercentile
        } elseif ($null -ne $SeriesItem -and ($SeriesItem.PSObject.Properties.Name -contains 'VolumePctl')) {
            $p = _ToDoubleOrNaNBO $SeriesItem.VolumePctl
        } elseif ($null -ne $SeriesItem -and ($SeriesItem.PSObject.Properties.Name -contains 'VolPctl')) {
            $p = _ToDoubleOrNaNBO $SeriesItem.VolPctl
        }
        $pass = (-not [double]::IsNaN($p)) -and ($p -ge $pThr)
        $tests.Add([pscustomobject]@{ Name='percentile'; Enabled=$true; Value=$p; Threshold=$pThr; Passed=$pass })
    }

    if ($useSur) {
        $anyEnabled = $true
        $sr = [double]::NaN
        if ($null -ne $SeriesItem -and ($SeriesItem.PSObject.Properties.Name -contains 'VolumeSurgeRatio')) {
            $sr = _ToDoubleOrNaNBO $SeriesItem.VolumeSurgeRatio
        } elseif ($null -ne $SeriesItem -and ($SeriesItem.PSObject.Properties.Name -contains 'VolSurgeRatio')) {
            $sr = _ToDoubleOrNaNBO $SeriesItem.VolSurgeRatio
        }
        $pass = (-not [double]::IsNaN($sr)) -and ($sr -ge $srThr)
        $tests.Add([pscustomobject]@{ Name='surge_ratio'; Enabled=$true; Value=$sr; Threshold=$srThr; Passed=$pass })
    }

    # If nothing enabled, treat as not required (degraded config)
    if (-not $anyEnabled) {
        return [pscustomobject]@{
            Required = $false
            Passed   = $true
            Logic    = $logic
            Tests    = @()
        }
    }

    $passed = $false
    if ($logic -eq 'and') {
        $passed = $true
        foreach ($t in $tests) { if (-not $t.Passed) { $passed = $false; break } }
    } else {
        foreach ($t in $tests) { if ($t.Passed) { $passed = $true; break } }
    }

    return [pscustomobject]@{
        Required = $true
        Passed   = $passed
        Logic    = $logic
        Tests    = $tests.ToArray()
    }
}

function Confirm-Breakout {
    [CmdletBinding()]
    param(
        # Indicators composition output (Compute-Indicators)
        [pscustomobject]$Indicators,

        # Pattern object (a single handle candidate) to confirm breakout against
        # Should contain indices/prices for handle and cup; at minimum HandleEndIndex + HandleHigh/RightPeak.
        [pscustomobject]$Pattern,

        # Legacy/test harness shape: snapshots plus one or more handle candidates.
        [object[]]$Series,
        [object[]]$Close,
        [object[]]$High,
        [object[]]$Volume,
        [object[]]$HandleCandidates,

        # Evaluate at a specific bar index (default: last bar)
        [int]$BarIndex = -1,

        # Config (merged defaults + overrides)
        [hashtable]$Config = @{}
    )

    if ($PSBoundParameters.ContainsKey('Series')) {
        $signals = [System.Collections.Generic.List[object]]::new()
        $seriesItems = @(
            foreach ($entry in @($Series)) {
                if ($entry -is [System.Array]) {
                    foreach ($nested in $entry) { $nested }
                } else {
                    $entry
                }
            }
        )
        $patterns = @($HandleCandidates)
        if ($patterns.Count -eq 0) {
            return [pscustomobject]@{
                Meta = @{ Status='EMPTY'; Bars=$seriesItems.Count; Issues=@('HandleCandidates is empty.') }
                Signals = @()
                Diagnostics = @{ Issues=@('HandleCandidates is empty.') }
            }
        }

        foreach ($candidate in $patterns) {
            $result = Confirm-Breakout -Indicators ([pscustomobject]@{ Series = ,$seriesItems }) -Pattern $candidate -Config $Config
            foreach ($signal in @($result.Signals)) { $signals.Add($signal) }
        }

        return [pscustomobject]@{
            Meta = @{ Status='OK'; Bars=$seriesItems.Count; Issues=@() }
            Signals = $signals.ToArray()
            Diagnostics = @{ Issues=@() }
        }
    }

    $issues = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Indicators -or $null -eq $Indicators.Series) {
        return [pscustomobject]@{
            Meta = @{ Status='EMPTY'; Issues=@('Indicators.Series is null.') }
            Signals = @()
            Diagnostics = @{ Issues=@('Indicators.Series is null.') }
        }
    }

    $series = @(
        foreach ($entry in @($Indicators.Series)) {
            if ($entry -is [System.Array]) {
                foreach ($nested in $entry) { $nested }
            } else {
                $entry
            }
        }
    )
    $n = $series.Count
    if ($n -le 0) {
        return [pscustomobject]@{
            Meta = @{ Status='EMPTY'; Bars=0; Issues=@('No bars.') }
            Signals = @()
            Diagnostics = @{ Issues=@('No bars.') }
        }
    }

    if ($BarIndex -lt 0) { $BarIndex = $n - 1 }
    if ($BarIndex -ge $n) { throw "BarIndex out of range: $BarIndex >= $n" }

    $breakoutEnabled = [bool](_TryGetBO $Config 'detection.breakout.enabled' $true)
    if (-not $breakoutEnabled) {
        return [pscustomobject]@{
            Meta = @{ Status='DISABLED'; Bars=$n }
            Signals = @([pscustomobject]@{ BarIndex=$BarIndex; Status='DISABLED'; Evidence=$null })
            Diagnostics = @{ Issues=@() }
        }
    }

    # ---- Determine evaluation start: cannot breakout before handle ends ----
    $handleEndI = $null
    if ($Pattern.PSObject.Properties.Name -contains 'HandleEndIndex') { $handleEndI = [int]$Pattern.HandleEndIndex }
    elseif ($Pattern.PSObject.Properties.Name -contains 'HandleEnd') { $handleEndI = [int]$Pattern.HandleEnd }

    if ($null -eq $handleEndI) {
        $issues.Add("Pattern missing HandleEndIndex; cannot enforce breakout timing.")
        $handleEndI = 0
    }
    $evalI = $BarIndex
    if ($evalI -lt $handleEndI) {
        return [pscustomobject]@{
            Meta = @{ Status='OK'; Bars=$n; Issues=$issues.ToArray() }
            Signals = @([pscustomobject]@{
                BarIndex=$evalI
                Status='NOT_READY'
                Evidence=[pscustomobject]@{ Reason="BarIndex before handle end"; HandleEndIndex=$handleEndI }
            })
            Diagnostics = @{ Issues=$issues.ToArray() }
        }
    }

    # ---- Resolve OHLCV at bar ----
    $item = $series[$evalI]

    $closeValue = [double](@(_ToDoubleOrNaNBO $item.Close)[-1])
    $highValue  = if ($item.PSObject.Properties.Name -contains 'High') { [double](@(_ToDoubleOrNaNBO $item.High)[-1]) } else { [double]::NaN }
    $atrValue   = if ($item.PSObject.Properties.Name -contains 'ATR') { [double](@(_ToDoubleOrNaNBO $item.ATR)[-1]) } elseif ($item.PSObject.Properties.Name -contains 'Atr') { [double](@(_ToDoubleOrNaNBO $item.Atr)[-1]) } else { [double]::NaN }

    if ([double]::IsNaN($closeValue) -or $closeValue -le 0) {
        return [pscustomobject]@{
            Meta = @{ Status='OK'; Bars=$n; Issues=$issues.ToArray() }
            Signals = @([pscustomobject]@{
                BarIndex=$evalI
                Status='NO_SIGNAL'
                Evidence=[pscustomobject]@{ Reason='Invalid close'; Close=$closeValue }
            })
            Diagnostics = @{ Issues=$issues.ToArray() }
        }
    }

    $regimeScale = _ResolveRegimeScaleBO -SeriesItem $item -Config $Config

    # ---- Pivot/reference ----
    $pivotInfo = _GetPivotLevelBO -Pattern $Pattern -High $null -Close $null -BarIndex $evalI -Config $Config
    $pivot = [double]$pivotInfo.Pivot
    if ([double]::IsNaN($pivot) -or $pivot -le 0) {
        $issues.Add("Could not resolve breakout pivot (reference_level=$(_TryGetBO $Config 'detection.breakout.reference_level' 'handle_high_or_rim')).")
        return [pscustomobject]@{
            Meta = @{ Status='OK'; Bars=$n; Issues=$issues.ToArray() }
            Signals = @([pscustomobject]@{
                BarIndex=$evalI
                Status='NO_SIGNAL'
                Evidence=[pscustomobject]@{ Reason='Missing pivot'; Pivot=$pivot; PivotSource=$pivotInfo.Source }
            })
            Diagnostics = @{ Issues=$issues.ToArray() }
        }
    }

    # ---- Price thresholds (regime-scaled) ----
    $atrKBase    = [double](_TryGetBO $Config 'detection.breakout.price.atr_buffer_k' (_TryGetBO $Config 'detection.breakout.price.atr_buffer_mult' 0.25))
    $minClosePct = [double](_TryGetBO $Config 'detection.breakout.price.min_close_above_ref_pct' (_TryGetBO $Config 'detection.breakout.price.min_percent_above_pivot' 0.0))
    $allowHiTrig = [bool](_TryGetBO $Config 'detection.breakout.price.allow_intraday_high_trigger' $false)

    $scalePrice = [bool](_TryGetBO $Config 'detection.breakout.regime_scaling.scale_price_thresholds' $true)

    # Direction: in higher vol regimes we require more clearance (stricter).
    $atrK = if ($scalePrice) { $atrKBase * $regimeScale } else { $atrKBase }
    $minClosePctScaled = if ($scalePrice) { $minClosePct * $regimeScale } else { $minClosePct }

    $atrBuf = 0.0
    if (-not [double]::IsNaN($atrValue) -and $atrValue -gt 0) {
        $atrBuf = $atrK * $atrValue
    } else {
        if ($atrKBase -gt 0) { $issues.Add("ATR missing/invalid at bar $evalI; ATR buffer treated as 0.") }
        $atrBuf = 0.0
    }

    $pctBuf = $pivot * $minClosePctScaled
    $refPlus = $pivot + $atrBuf + $pctBuf

    # Price pass logic
    $closePass = ($closeValue -ge $refPlus)
    $highPass  = $false
    if ($allowHiTrig -and -not [double]::IsNaN($highValue) -and $highValue -gt 0) {
        $highPass = ($highValue -ge $refPlus)
    }

    $pricePassed = $closePass -or $highPass

    # ---- Volume confirmation ----
    $volEval = _EvalVolumeConfirmBO -SeriesItem $item -RegimeScale $regimeScale -Config $Config
    $volumePassed = [bool]$volEval.Passed

    # ---- Tentative logic ----
    $tentEnabled  = [bool](_TryGetBO $Config 'detection.breakout.tentative.enabled' $true)
    $maxPending   = [int] (_TryGetBO $Config 'detection.breakout.tentative.max_bars_pending' 3)
    $needFollow   = [bool](_TryGetBO $Config 'detection.breakout.tentative.require_followthrough_close' $true)

    $status = 'NO_SIGNAL'
    $tentative = $false
    $confirmed = $false

    if ($pricePassed -and $volumePassed) {
        $confirmed = $true
        $status = 'CONFIRMED'
    } elseif ($tentEnabled -and $pricePassed -and -not $volumePassed) {
        # Price breakout on insufficient volume -> tentative
        $tentative = $true
        $status = 'TENTATIVE'
    }

    # If tentative, optionally require follow-through close within next N bars (caller may evaluate at last bar; we can look back)
    $follow = $null
    if ($tentative -and $needFollow) {
        # Look for any bar within [evalI, evalI+maxPending] (bounded) with close above refPlus and volume confirm
        $end = [Math]::Min($n-1, $evalI + [Math]::Max(0, $maxPending))
        $got = $false
        $hitI = $null
        for ($j=$evalI; $j -le $end; $j++) {
            $it = $series[$j]
            $cl = _ToDoubleOrNaNBO $it.Close
            if ([double]::IsNaN($cl)) { continue }

            $rsj = _ResolveRegimeScaleBO -SeriesItem $it -Config $Config
            $atrj = if ($it.PSObject.Properties.Name -contains 'ATR') { _ToDoubleOrNaNBO $it.ATR } elseif ($it.PSObject.Properties.Name -contains 'Atr') { _ToDoubleOrNaNBO $it.Atr } else { [double]::NaN }
            $atrKj = if ($scalePrice) { $atrKBase * $rsj } else { $atrKBase }
            $minPctJ = if ($scalePrice) { $minClosePct * $rsj } else { $minClosePct }
            $atrBufJ = if (-not [double]::IsNaN($atrj) -and $atrj -gt 0) { $atrKj * $atrj } else { 0.0 }
            $refPlusJ = $pivot + $atrBufJ + ($pivot * $minPctJ)

            $priceJ = ($cl -ge $refPlusJ)
            $volJ   = (_EvalVolumeConfirmBO -SeriesItem $it -RegimeScale $rsj -Config $Config).Passed

            if ($priceJ -and $volJ) { $got = $true; $hitI = $j; break }
        }

        $follow = [pscustomobject]@{
            Required = $true
            MaxBarsPending = $maxPending
            Found = $got
            ConfirmedAtIndex = $hitI
        }

        if ($follow.Found) {
            $tentative = $false
            $confirmed = $true
            $status = 'CONFIRMED'
        }
    } else {
        $follow = [pscustomobject]@{ Required=$needFollow; MaxBarsPending=$maxPending; Found=$null; ConfirmedAtIndex=$null }
    }

    $evidence = [pscustomobject]@{
        Pivot = $pivot
        PivotSource = $pivotInfo.Source
        RegimeScale = $regimeScale

        Price = [pscustomobject]@{
            Close = $closeValue
            High = $highValue
            ATR = $atrValue
            AllowIntradayHighTrigger = $allowHiTrig
            AtrBufferKBase = $atrKBase
            AtrBufferKScaled = $atrK
            MinCloseAboveRefPctBase = $minClosePct
            MinCloseAboveRefPctScaled = $minClosePctScaled
            AtrBuffer = $atrBuf
            PctBuffer = $pctBuf
            ReferencePlusBuffer = $refPlus
            ClosePassed = $closePass
            HighPassed  = $highPass
            Passed = $pricePassed
        }

        Volume = [pscustomobject]@{
            Required = $volEval.Required
            Logic = $volEval.Logic
            Passed = $volEval.Passed
            Tests = $volEval.Tests
        }

        Tentative = [pscustomobject]@{
            Enabled = $tentEnabled
            WasTentative = $tentative
            FollowThrough = $follow
        }
    }

    return [pscustomobject]@{
        Meta = @{
            Status = 'OK'
            Bars   = $n
            Issues = $issues.ToArray()
        }
        Signals = @([pscustomobject]@{
            BarIndex = $evalI
            Status   = $status
            Confirmed = $confirmed
            Evidence = $evidence
        })
        Diagnostics = @{
            Issues = $issues.ToArray()
        }
    }
}
