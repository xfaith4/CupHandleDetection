# src/CupHandleDetector/Public/Detect-Stages.ps1
# Stage labeling across bars + stage transition events.
#
# Public function:
#   Detect-Stages
#
# Inputs are intentionally flexible: you may pass precomputed indicator snapshots per bar,
# or pass raw OHLCV arrays and minimal fields; missing data is tolerated.
#
# Output:
#   PSCustomObject @{
#     Meta = @{ Status='OK'|'EMPTY'|'INSUFFICIENT_DATA'; Bars=<int>; Issues=<string[]> }
#     StageLabels = <string[]>                      # one label per bar index (may contain 'UNKNOWN')
#     TransitionEvents = <object[]>                 # events with From/To/Index/Time/Reason/Confidence
#   }
#
# Stage model (defaults; configurable via $Config.stage_labeling.*):
#   - UPTREND / DOWNTREND based on MA slope + price vs MA
#   - BASE / CONSOLIDATION when trend is weak and volatility is low
#   - BREAKOUT when price clears recent resistance with momentum
#
# Optional overlays:
#   - Cup/Handle stages emitted as events when $CupCandidates / $HandleCandidates are provided.

Set-StrictMode -Version Latest

function _IsFiniteNumberStages {
    param([object]$x)
    if ($null -eq $x) { return $false }
    try {
        $d = [double]$x
        return -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
    } catch { return $false }
}

function _ToDoubleOrNaNStages {
    param([object]$x)
    if (-not (_IsFiniteNumberStages $x)) { return [double]::NaN }
    return [double]$x
}

function _TryGetStages {
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

function _GetPropStages {
    param(
        [Parameter(Mandatory)] [object]$Obj,
        [Parameter(Mandatory)] [string]$Name
    )
    if ($null -eq $Obj) { return $null }

    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $null
    }

    try {
        $p = $Obj.PSObject.Properties[$Name]
        if ($null -ne $p) { return $p.Value }
    } catch {}
    return $null
}

function _SafeIntStages {
    param([object]$x, [int]$Fallback = -1)
    if (-not (_IsFiniteNumberStages $x)) { return $Fallback }
    return [int][Math]::Round([double]$x)
}

function _StageRank {
    param([string]$Stage)
    switch ($Stage) {
        'DOWNTREND' { return 0 }
        'BASE'      { return 1 }
        'UPTREND'   { return 2 }
        'BREAKOUT'  { return 3 }
        default     { return -1 }
    }
}

function _ComputeTransitionConfidence {
    param(
        [object]$Snapshot,
        [hashtable]$Config,
        [string]$FromStage,
        [string]$ToStage,
        [switch]$IncludeDiagnostics
    )

    # Try to call Private/Confidence.ps1 if available in session.
    if (Get-Command -Name Get-StageChangeConfidence -ErrorAction SilentlyContinue) {
        try {
            return Get-StageChangeConfidence -Snapshot $Snapshot -Config $Config -FromStage $FromStage -ToStage $ToStage -IncludeDiagnostics:$IncludeDiagnostics
        } catch {
            return [pscustomobject]@{ Confidence = $null; Diagnostics = @{ reason='CONFIDENCE_EXCEPTION'; error="$($_.Exception.Message)" } }
        }
    }

    # Fallback: no confidence module loaded.
    return [pscustomobject]@{ Confidence = $null; Diagnostics = $(if ($IncludeDiagnostics) { @{ reason='CONFIDENCE_MODULE_NOT_LOADED' } } else { $null }) }
}

function Detect-Stages {
    [CmdletBinding()]
    param(
        # Either provide Snapshots (one per bar), or provide Close + optional indicator arrays.
        [object[]]$Snapshots,

        [object[]]$Close,
        [object[]]$High,
        [object[]]$Low,
        [object[]]$Volume,
        [object[]]$Time,

        # Optional indicator arrays (if Snapshots not provided):
        # Trend / baseline
        [object[]]$MA,           # e.g., 50SMA (same length as Close)
        [object[]]$MASlope,      # per-bar slope of MA (fractional, e.g., 0.001 = 0.1% per bar)
        # Volatility proxy
        [object[]]$ATRpct,       # ATR / Close (0..1 typical)
        # Breakout proxy
        [object[]]$RS,           # Relative Strength (optional)
        [object[]]$RSIScore,     # optional (0..1)
        # Component scores (optional; used by confidence module)
        [object[]]$ScorePrice,
        [object[]]$ScoreVolume,
        [object[]]$ScoreDuration,
        [object[]]$ScoreGeometry,
        # Regime flags (optional)
        [object[]]$RegimeHighVol,
        [object[]]$RegimeVolScore,

        # Optional pattern detections to emit overlay events
        [object[]]$CupCandidates,
        [object[]]$HandleCandidates,

        # Config
        [hashtable]$Config = @{},
        [switch]$IncludeConfidence,
        [switch]$IncludeConfidenceDiagnostics,
        [switch]$EmitPatternOverlayEvents,
        [switch]$PatternOverlayAffectsStage
    )

    $issues = New-Object System.Collections.Generic.List[string]

    # ---- Determine bar count and construct snapshots if needed ----
    $n = 0
    if ($null -ne $Snapshots -and $Snapshots.Count -gt 0) {
        $n = $Snapshots.Count
    } elseif ($null -ne $Close -and $Close.Count -gt 0) {
        $n = $Close.Count
    } else {
        return [pscustomobject]@{
            Meta = @{ Status='EMPTY'; Bars=0; Issues=@('No Snapshots and no Close provided.') }
            StageLabels = @()
            TransitionEvents = @()
        }
    }

    if ($n -lt 2) {
        return [pscustomobject]@{
            Meta = @{ Status='INSUFFICIENT_DATA'; Bars=$n; Issues=@("Need at least 2 bars; got $n.") }
            StageLabels = @()
            TransitionEvents = @()
        }
    }

    # Build snapshots if caller didn't provide them.
    if ($null -eq $Snapshots -or $Snapshots.Count -eq 0) {
        $Snapshots = New-Object object[] $n
        for ($i=0; $i -lt $n; $i++) {
            $snap = [ordered]@{
                BarIndex = $i
                Close    = $(if ($null -ne $Close -and $Close.Count -eq $n) { $Close[$i] } else { $null })
                High     = $(if ($null -ne $High  -and $High.Count  -eq $n) { $High[$i] } else { $null })
                Low      = $(if ($null -ne $Low   -and $Low.Count   -eq $n) { $Low[$i] } else { $null })
                Volume   = $(if ($null -ne $Volume -and $Volume.Count -eq $n) { $Volume[$i] } else { $null })
                Time     = $(if ($null -ne $Time  -and $Time.Count  -eq $n) { $Time[$i] } else { $null })

                MA       = $(if ($null -ne $MA -and $MA.Count -eq $n) { $MA[$i] } else { $null })
                MASlope  = $(if ($null -ne $MASlope -and $MASlope.Count -eq $n) { $MASlope[$i] } else { $null })
                ATRpct   = $(if ($null -ne $ATRpct -and $ATRpct.Count -eq $n) { $ATRpct[$i] } else { $null })

                RS       = $(if ($null -ne $RS -and $RS.Count -eq $n) { $RS[$i] } else { $null })
                RSIScore = $(if ($null -ne $RSIScore -and $RSIScore.Count -eq $n) { $RSIScore[$i] } else { $null })

                ScorePrice    = $(if ($null -ne $ScorePrice -and $ScorePrice.Count -eq $n) { $ScorePrice[$i] } else { $null })
                ScoreVolume   = $(if ($null -ne $ScoreVolume -and $ScoreVolume.Count -eq $n) { $ScoreVolume[$i] } else { $null })
                ScoreDuration = $(if ($null -ne $ScoreDuration -and $ScoreDuration.Count -eq $n) { $ScoreDuration[$i] } else { $null })
                ScoreGeometry = $(if ($null -ne $ScoreGeometry -and $ScoreGeometry.Count -eq $n) { $ScoreGeometry[$i] } else { $null })

                RegimeHighVol = $(if ($null -ne $RegimeHighVol -and $RegimeHighVol.Count -eq $n) { $RegimeHighVol[$i] } else { $null })
                RegimeVolScore = $(if ($null -ne $RegimeVolScore -and $RegimeVolScore.Count -eq $n) { $RegimeVolScore[$i] } else { $null })
            }
            $Snapshots[$i] = [pscustomobject]$snap
        }
    } else {
        # Ensure BarIndex exists (for confidence gating)
        for ($i=0; $i -lt $n; $i++) {
            $bi = _GetPropStages -Obj $Snapshots[$i] -Name 'BarIndex'
            if ($null -eq $bi) {
                try { $Snapshots[$i] | Add-Member -NotePropertyName BarIndex -NotePropertyValue $i -Force } catch {}
            }
        }
    }

    # ---- Config defaults for stage labeling ----
    $slopeUp    = [double](_TryGetStages $Config 'stage_labeling.trend.slope_up' 0.0005)   # 0.05%/bar
    $slopeDown  = [double](_TryGetStages $Config 'stage_labeling.trend.slope_down' -0.0005)
    $priceAbove = [double](_TryGetStages $Config 'stage_labeling.trend.price_above_ma_pct' 0.002) # 0.2%
    $priceBelow = [double](_TryGetStages $Config 'stage_labeling.trend.price_below_ma_pct' 0.002)

    $atrLow     = [double](_TryGetStages $Config 'stage_labeling.base.atrpct_low' 0.02)     # 2%
    $atrHigh    = [double](_TryGetStages $Config 'stage_labeling.base.atrpct_high' 0.04)    # 4% (hysteresis)
    $slopeFlat  = [double](_TryGetStages $Config 'stage_labeling.base.abs_slope_flat' 0.0003)

    $breakoutLookback = [int](_TryGetStages $Config 'stage_labeling.breakout.lookback_bars' 20)
    $breakoutPct      = [double](_TryGetStages $Config 'stage_labeling.breakout.above_recent_high_pct' 0.005) # 0.5%
    $breakoutNeedsTrend = [bool](_TryGetStages $Config 'stage_labeling.breakout.require_uptrend_context' $true)

    $hysteresisBars = [int](_TryGetStages $Config 'stage_labeling.hysteresis.confirm_bars' 2)
    $unknownLabel = [string](_TryGetStages $Config 'stage_labeling.unknown_label' 'UNKNOWN')

    # ---- Helper: recent high for breakout ----
    function _RecentHigh {
        param([int]$idx)
        $start = [Math]::Max(0, $idx - $breakoutLookback)
        $best = [double]::NegativeInfinity
        for ($k=$start; $k -lt $idx; $k++) {
            $h = _ToDoubleOrNaNStages (_GetPropStages $Snapshots[$k] 'High')
            $c = _ToDoubleOrNaNStages (_GetPropStages $Snapshots[$k] 'Close')
            $v = if (-not [double]::IsNaN($h)) { $h } else { $c }
            if ([double]::IsNaN($v)) { continue }
            if ($v -gt $best) { $best = $v }
        }
        if ($best -eq [double]::NegativeInfinity) { return [double]::NaN }
        return $best
    }

    # ---- Core per-bar stage decision ----
    function _DecideStage {
        param([int]$i, [string]$PrevStage)

        $snap = $Snapshots[$i]
        $close = _ToDoubleOrNaNStages (_GetPropStages $snap 'Close')
        $ma    = _ToDoubleOrNaNStages (_GetPropStages $snap 'MA')
        $slope = _ToDoubleOrNaNStages (_GetPropStages $snap 'MASlope')
        $atrp  = _ToDoubleOrNaNStages (_GetPropStages $snap 'ATRpct')

        $haveTrend = (-not [double]::IsNaN($close)) -and (-not [double]::IsNaN($ma)) -and (-not [double]::IsNaN($slope)) -and $ma -ne 0
        $haveAtr   = (-not [double]::IsNaN($atrp))

        $stage = $unknownLabel
        $reason = 'INSUFFICIENT_INDICATORS'

        # Breakout check (requires close + recent high)
        $recentHigh = if ($i -gt 0) { _RecentHigh $i } else { [double]::NaN }
        $isBreakout = $false
        if (-not [double]::IsNaN($close) -and -not [double]::IsNaN($recentHigh) -and $recentHigh -gt 0) {
            if ($close -ge ($recentHigh * (1.0 + $breakoutPct))) { $isBreakout = $true }
        }

        $trendContextOk = $true
        if ($breakoutNeedsTrend -and $haveTrend) {
            $trendContextOk = ($slope -ge $slopeUp) -and ($close -ge $ma * (1.0 + $priceAbove))
        } elseif ($breakoutNeedsTrend -and -not $haveTrend) {
            $trendContextOk = $false
        }

        if ($isBreakout -and $trendContextOk) {
            $stage = 'BREAKOUT'
            $reason = 'RECENT_HIGH_CLEARED'
            return [pscustomobject]@{ Stage=$stage; Reason=$reason }
        }

        if ($haveTrend) {
            $above = ($close -ge $ma * (1.0 + $priceAbove))
            $below = ($close -le $ma * (1.0 - $priceBelow))

            if ($slope -ge $slopeUp -and $above) {
                $stage = 'UPTREND'
                $reason = 'MA_SLOPE_UP_AND_PRICE_ABOVE'
                return [pscustomobject]@{ Stage=$stage; Reason=$reason }
            }

            if ($slope -le $slopeDown -and $below) {
                $stage = 'DOWNTREND'
                $reason = 'MA_SLOPE_DOWN_AND_PRICE_BELOW'
                return [pscustomobject]@{ Stage=$stage; Reason=$reason }
            }

            # If trend exists but not strongly up/down, consider BASE if volatility low and slope flat.
            if ($haveAtr) {
                $flat = ([Math]::Abs($slope) -le $slopeFlat)
                $atrOk = ($atrp -le $atrLow)

                # Hysteresis: if we are already in BASE, allow atr up to atrHigh to stay BASE.
                if ($PrevStage -eq 'BASE' -and $atrp -le $atrHigh -and $flat) { $atrOk = $true }

                if ($flat -and $atrOk) {
                    $stage = 'BASE'
                    $reason = 'FLAT_TREND_LOW_VOL'
                    return [pscustomobject]@{ Stage=$stage; Reason=$reason }
                }
            }

            # Otherwise, default toward previous stage if known, else BASE if ATR low, else UNKNOWN.
            if ($PrevStage -ne $null -and $PrevStage -ne $unknownLabel) {
                $stage = $PrevStage
                $reason = 'HOLD_PREV_STAGE'
                return [pscustomobject]@{ Stage=$stage; Reason=$reason }
            }

            if ($haveAtr -and $atrp -le $atrLow) {
                $stage = 'BASE'
                $reason = 'LOW_VOL_FALLBACK'
                return [pscustomobject]@{ Stage=$stage; Reason=$reason }
            }

            $stage = $unknownLabel
            $reason = 'NO_CLEAR_STAGE'
            return [pscustomobject]@{ Stage=$stage; Reason=$reason }
        }

        # Without trend indicators, we can still do a weak BASE guess based on ATRpct.
        if ($haveAtr) {
            if ($atrp -le $atrLow) {
                return [pscustomobject]@{ Stage='BASE'; Reason='ATR_LOW_NO_TREND_INDICATORS' }
            }
        }

        return [pscustomobject]@{ Stage=$unknownLabel; Reason=$reason }
    }

    # ---- Hysteresis/confirmation: require proposed stage to persist for confirm_bars ----
    $labels = New-Object string[] $n
    $proposed = New-Object string[] $n
    $reasonArr = New-Object string[] $n

    $prev = $null
    for ($i=0; $i -lt $n; $i++) {
        $d = _DecideStage -i $i -PrevStage $prev
        $proposed[$i] = $d.Stage
        $reasonArr[$i] = $d.Reason
        $prev = $d.Stage
    }

    # Apply confirmation: a change is accepted only if next confirm bars also propose it.
    for ($i=0; $i -lt $n; $i++) {
        if ($i -eq 0) { $labels[$i] = $proposed[$i]; continue }

        $cur = $labels[$i-1]
        $p = $proposed[$i]
        if ($p -eq $cur) { $labels[$i] = $cur; continue }

        if ($hysteresisBars -le 0) { $labels[$i] = $p; continue }

        $ok = $true
        for ($k=0; $k -lt $hysteresisBars; $k++) {
            $j = $i + $k
            if ($j -ge $n) { $ok = $false; break }
            if ($proposed[$j] -ne $p) { $ok = $false; break }
        }

        $labels[$i] = $(if ($ok) { $p } else { $cur })
    }

    # ---- Build transition events whenever label changes ----
    $events = New-Object System.Collections.Generic.List[object]

    for ($i=1; $i -lt $n; $i++) {
        if ($labels[$i] -ne $labels[$i-1]) {
            $from = $labels[$i-1]
            $to   = $labels[$i]
            $snap = $Snapshots[$i]
            $t    = _GetPropStages -Obj $snap -Name 'Time'
            $evt = [ordered]@{
                Type      = 'STAGE_TRANSITION'
                Index     = $i
                Time      = $t
                FromStage = $from
                ToStage   = $to
                Reason    = $reasonArr[$i]
            }

            if ($IncludeConfidence) {
                $conf = _ComputeTransitionConfidence -Snapshot $snap -Config $Config -FromStage $from -ToStage $to -IncludeDiagnostics:$IncludeConfidenceDiagnostics
                $evt.Confidence = $conf.Confidence
                if ($IncludeConfidenceDiagnostics) { $evt.ConfidenceDiagnostics = $conf.Diagnostics }
            }

            $events.Add([pscustomobject]$evt)
        }
    }

    # ---- Optional: emit cup/handle overlay events (does not change labels unless enabled) ----
    if ($EmitPatternOverlayEvents) {

        function _EmitWindowEvents {
            param(
                [object]$cand,
                [string]$prefix,
                [string]$startProp,
                [string]$endProp
            )
            $sI = _SafeIntStages (_GetPropStages $cand $startProp) -1
            $eI = _SafeIntStages (_GetPropStages $cand $endProp) -1
            if ($sI -ge 0 -and $eI -ge 0 -and $sI -lt $n -and $eI -lt $n -and $eI -ge $sI) {
                $ts = _GetPropStages $Snapshots[$sI] 'Time'
                $te = _GetPropStages $Snapshots[$eI] 'Time'
                $events.Add([pscustomobject]@{
                    Type  = 'PATTERN_OVERLAY'
                    Index = $sI
                    Time  = $ts
                    FromStage = $null
                    ToStage   = "${prefix}_START"
                    Reason    = "${prefix} window start"
                })
                $events.Add([pscustomobject]@{
                    Type  = 'PATTERN_OVERLAY'
                    Index = $eI
                    Time  = $te
                    FromStage = $null
                    ToStage   = "${prefix}_END"
                    Reason    = "${prefix} window end"
                })

                if ($PatternOverlayAffectsStage) {
                    for ($x=$sI; $x -le $eI; $x++) {
                        if ($labels[$x] -eq $unknownLabel) {
                            $labels[$x] = $prefix
                        }
                    }
                }
            }
        }

        if ($null -ne $CupCandidates -and $CupCandidates.Count -gt 0) {
            foreach ($cup in $CupCandidates) {
                # Prefer explicit endpoints if present; else use LeftPeakIndex..RightPeakIndex
                $lp = _GetPropStages $cup 'LeftPeakIndex'
                $rp = _GetPropStages $cup 'RightPeakIndex'
                if ($null -ne $lp -and $null -ne $rp) {
                    _EmitWindowEvents -cand $cup -prefix 'CUP' -startProp 'LeftPeakIndex' -endProp 'RightPeakIndex'
                }
            }
        }

        if ($null -ne $HandleCandidates -and $HandleCandidates.Count -gt 0) {
            foreach ($h in $HandleCandidates) {
                # Expected props from DetectHandle: HandleStartIndex / HandleEndIndex (common)
                $hs = _GetPropStages $h 'HandleStartIndex'
                $he = _GetPropStages $h 'HandleEndIndex'
                if ($null -ne $hs -and $null -ne $he) {
                    _EmitWindowEvents -cand $h -prefix 'HANDLE' -startProp 'HandleStartIndex' -endProp 'HandleEndIndex'
                } else {
                    # Fallback to StartIndex/EndIndex if used by caller
                    $hs2 = _GetPropStages $h 'StartIndex'
                    $he2 = _GetPropStages $h 'EndIndex'
                    if ($null -ne $hs2 -and $null -ne $he2) {
                        _EmitWindowEvents -cand $h -prefix 'HANDLE' -startProp 'StartIndex' -endProp 'EndIndex'
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        Meta = @{
            Status = 'OK'
            Bars   = $n
            Issues = $issues.ToArray()
        }
        StageLabels = $labels
        TransitionEvents = $events.ToArray()
    }
}