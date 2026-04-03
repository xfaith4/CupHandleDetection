# src/CupHandleDetector/Public/Compute-Indicators.ps1
# Compose all indicators into a single API returning:
# - Per-bar snapshots (aligned to input bars)
# - Global diagnostics (coverage, degraded rates, first-valid indices)
#
# This is a composition layer: it does not implement the math of indicators,
# it calls the already-implemented private modules.
#
# Expected input shape:
#   Bars: object[] where each item has at least:
#     Time (optional), Open, High, Low, Close, Volume
# Or you may pass explicit arrays via -Open/-High/-Low/-Close/-Volume.
#
# Output shape:
#   PSCustomObject @{
#     Meta        = @{ ... }
#     Diagnostics = @{ ... }
#     Series      = [object[]] per bar snapshots
#   }

Set-StrictMode -Version Latest

# Private dependencies
$script:ThisDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:PrivateDir = Join-Path (Split-Path -Parent $script:ThisDir) 'Private'

. (Join-Path $script:PrivateDir 'Atr.ps1')
. (Join-Path $script:PrivateDir 'Regime.ps1')
. (Join-Path $script:PrivateDir 'VolumeFeatures.ps1')
. (Join-Path $script:PrivateDir 'Sideways.ps1')

function _IsFiniteNumberCI {
    param([object]$x)
    if ($null -eq $x) { return $false }
    try {
        $d = [double]$x
        return -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
    } catch { return $false }
}

function _FirstValidIndex {
    param([object[]]$Values)
    for ($i=0; $i -lt $Values.Count; $i++) {
        if (_IsFiniteNumberCI $Values[$i]) { return $i }
    }
    return $null
}

function _CountNull {
    param([object[]]$Values)
    $c = 0
    foreach ($v in $Values) { if ($null -eq $v) { $c++ } }
    return $c
}

function _CountInvalidNumber {
    param([object[]]$Values)
    $c = 0
    foreach ($v in $Values) {
        if ($null -eq $v) { continue }
        try {
            $d = [double]$v
            if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { $c++ }
        } catch { $c++ }
    }
    return $c
}

function _Rate {
    param([int]$Numerator, [int]$Denominator)
    if ($Denominator -le 0) { return $null }
    return [double]$Numerator / [double]$Denominator
}

function _TryGet {
    param(
        [Parameter(Mandatory)] [hashtable]$Table,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] $Fallback
    )
    # Path format: "a.b.c"
    $cur = $Table
    foreach ($k in $Path.Split('.')) {
        if ($null -eq $cur) { return $Fallback }
        if ($cur -isnot [hashtable] -and $cur -isnot [System.Collections.IDictionary]) { return $Fallback }
        if (-not $cur.Contains($k)) { return $Fallback }
        $cur = $cur[$k]
    }
    if ($null -eq $cur) { return $Fallback }
    return $cur
}

function Compute-Indicators {
    [CmdletBinding(DefaultParameterSetName='Bars')]
    param(
        # --- Input forms ---
        [Parameter(Mandatory, ParameterSetName='Bars')]
        [object[]]$Bars,

        [Parameter(Mandatory, ParameterSetName='Arrays')]
        [object[]]$Open,
        [Parameter(Mandatory, ParameterSetName='Arrays')]
        [object[]]$High,
        [Parameter(Mandatory, ParameterSetName='Arrays')]
        [object[]]$Low,
        [Parameter(Mandatory, ParameterSetName='Arrays')]
        [object[]]$Close,
        [Parameter(Mandatory, ParameterSetName='Arrays')]
        [object[]]$Volume,

        [Parameter(ParameterSetName='Arrays')]
        [object[]]$Time,

        # Config object (ideally config/defaults.json parsed to hashtable then overridden)
        [hashtable]$Config = @{},
        [string]$Symbol = $null,

        # If set, returns per-bar snapshots as hashtables instead of PSCustomObjects
        [switch]$AsHashtable,

        # If set, do not throw on short history; return diagnostics with Status="INSUFFICIENT_DATA"
        [switch]$AllowInsufficientHistory
    )

    # ---- Normalize inputs into arrays ----
    if ($PSCmdlet.ParameterSetName -eq 'Bars') {
        $n = $Bars.Count
        $Open   = New-Object object[] $n
        $High   = New-Object object[] $n
        $Low    = New-Object object[] $n
        $Close  = New-Object object[] $n
        $Volume = New-Object object[] $n
        $Time   = New-Object object[] $n

        for ($i=0; $i -lt $n; $i++) {
            $b = $Bars[$i]
            $Time[$i]   = $b.Time
            $Open[$i]   = $b.Open
            $High[$i]   = $b.High
            $Low[$i]    = $b.Low
            $Close[$i]  = $b.Close
            $Volume[$i] = $b.Volume
        }
    } else {
        $n = $Close.Count
        if ($Open.Count -ne $n -or $High.Count -ne $n -or $Low.Count -ne $n -or $Volume.Count -ne $n) {
            throw "Open/High/Low/Close/Volume must have the same length."
        }
        if ($null -eq $Time) {
            $Time = New-Object object[] $n
        } elseif ($Time.Count -ne $n) {
            throw "Time must be null or have the same length as Close."
        }
    }

    # ---- Resolve config with safe fallbacks (mirrors config/defaults.json structure) ----
    $barsPerWeek = [int](_TryGet -Table $Config -Path 'data.bars_per_week' -Fallback 5)

    $minBarsTotal         = [int](_TryGet -Table $Config -Path 'data.requirements.min_bars_total' -Fallback 260)
    $minBarsForIndicators = [int](_TryGet -Table $Config -Path 'data.requirements.min_bars_for_indicators' -Fallback 60)

    $atrEnabled = [bool](_TryGet -Table $Config -Path 'indicators.atr.enabled' -Fallback $true)
    $atrPeriod  = [int] (_TryGet -Table $Config -Path 'indicators.atr.lookback' -Fallback 14)
    $atrMethod  = [string](_TryGet -Table $Config -Path 'indicators.atr.method' -Fallback 'wilder')

    $regimeEnabled = [bool](_TryGet -Table $Config -Path 'indicators.regime.enabled' -Fallback $true)
    $regimeWindow  = [int] (_TryGet -Table $Config -Path 'indicators.regime.atr_percentile_lookback' -Fallback 100)
    $regimeInterp  = [string](_TryGet -Table $Config -Path 'indicators.regime.percentile_method' -Fallback 'rank') # informational

    $volLookback = [int](_TryGet -Table $Config -Path 'indicators.volume.lookback' -Fallback 50)

    $volZEnabled  = [bool](_TryGet -Table $Config -Path 'indicators.volume.zscore.enabled' -Fallback $true)
    $volZClip     = [double](_TryGet -Table $Config -Path 'indicators.volume.zscore.clip' -Fallback 6.0)

    $volPctEnabled = [bool](_TryGet -Table $Config -Path 'indicators.volume.percentile.enabled' -Fallback $true)
    $volPctWindow  = [int] (_TryGet -Table $Config -Path 'indicators.volume.percentile.lookback' -Fallback 50)

    $surgeEnabled   = [bool](_TryGet -Table $Config -Path 'indicators.volume.surge_ratio.enabled' -Fallback $true)
    $surgeWindow    = [int] (_TryGet -Table $Config -Path 'indicators.volume.surge_ratio.median_lookback' -Fallback 20)

    $sidewaysEnabled = [bool](_TryGet -Table $Config -Path 'indicators.sideways.enabled' -Fallback $true)
    $widthWindowBars = [int] (_TryGet -Table $Config -Path 'indicators.sideways.width_window_bars' -Fallback 20)
    $widthThreshold  = [double](_TryGet -Table $Config -Path 'indicators.sideways.width_threshold' -Fallback 0.12)

    # ---- Basic history checks ----
    $status = 'OK'
    $issues = [System.Collections.Generic.List[string]]::new()

    if ($n -lt $minBarsForIndicators) {
        $status = 'INSUFFICIENT_DATA'
        $issues.Add("Need at least data.requirements.min_bars_for_indicators=$minBarsForIndicators bars; got $n.")
        if (-not $AllowInsufficientHistory) {
            throw ($issues -join ' ')
        }
    } elseif ($n -lt $minBarsTotal) {
        # Not fatal for computing indicators, but note it for later pattern detection expectations.
        $issues.Add("Below data.requirements.min_bars_total=$minBarsTotal bars; got $n. Some detections may be suppressed.")
    }

    # ---- Compute indicators (vectorized calls) ----
    $atr = $null
    $tr  = $null
    if ($atrEnabled) {
        if ($atrMethod -eq 'simple') {
            $atr = Get-Atr -High $High -Low $Low -Close $Close -Period $atrPeriod -Simple
        } else {
            $atr = Get-Atr -High $High -Low $Low -Close $Close -Period $atrPeriod
        }
        $tr = Get-TrueRange -High $High -Low $Low -Close $Close
    } else {
        $atr = New-Object object[] $n
        $tr  = New-Object object[] $n
    }

    $regime = $null
    if ($regimeEnabled) {
        # Note: defaults.json calls for rank/0..1 scaling, but our Regime.ps1 emits 0..100 percentile rank.
        $regime = Get-RegimeSignal -High $High -Low $Low -Close $Close -AtrPeriod $atrPeriod -PercentileWindow $regimeWindow -MinPeriods $regimeWindow -Interpolation 'Linear'
    } else {
        $regime = New-Object object[] $n
    }

    $vz = $null
    if ($volZEnabled) {
        $vz = Get-VolumeZScore -Volume $Volume -Window $volLookback -Clip $volZClip
    } else {
        $vz = [pscustomobject]@{
            Z        = New-Object object[] $n
            ZClipped = New-Object object[] $n
            Degraded = New-Object bool[] $n
            Mean     = New-Object object[] $n
            Std      = New-Object object[] $n
        }
        for ($i=0; $i -lt $n; $i++) { $vz.Degraded[$i] = $true }
    }

    $vp = $null
    if ($volPctEnabled) {
        $vp = Get-VolumePercentileRank -Volume $Volume -Window $volPctWindow -LowPercentile 5.0 -HighPercentile 95.0 -MinPeriods $volPctWindow -Interpolation 'Linear'
    } else {
        $vp = [pscustomobject]@{
            Rank01   = New-Object object[] $n
            PLow     = New-Object object[] $n
            PHigh    = New-Object object[] $n
            Degraded = New-Object bool[] $n
        }
        for ($i=0; $i -lt $n; $i++) { $vp.Degraded[$i] = $true }
    }

    $vs = $null
    if ($surgeEnabled) {
        # Surge ratio baseline per defaults.json is median_lookback; our function supports Mean/Median.
        $vs = Get-VolumeSurgeRatio -Volume $Volume -Window $surgeWindow -Baseline 'Median'
    } else {
        $vs = [pscustomobject]@{
            Ratio    = New-Object object[] $n
            Baseline = New-Object object[] $n
            Degraded = New-Object bool[] $n
        }
        for ($i=0; $i -lt $n; $i++) { $vs.Degraded[$i] = $true }
    }

    $width = $null
    if ($sidewaysEnabled) {
        # Compute absolute width; also provide widthPct = width / rollingMax-ish proxy by dividing by Close (simple, stable).
        $width = Get-RollingWidth -Values $Close -Window $widthWindowBars -MinPeriods $widthWindowBars
    } else {
        $width = New-Object object[] $n
    }

    $widthPct = New-Object object[] $n
    $sidewaysFlag = New-Object object[] $n
    for ($i=0; $i -lt $n; $i++) {
        if (_IsFiniteNumberCI $width[$i] -and _IsFiniteNumberCI $Close[$i]) {
            $c = [double]$Close[$i]
            if ($c -gt 0.0) {
                $wp = ([double]$width[$i]) / $c
                $widthPct[$i] = $wp
                $sidewaysFlag[$i] = [bool]($wp -le $widthThreshold)
            } else {
                $widthPct[$i] = $null
                $sidewaysFlag[$i] = $null
            }
        } else {
            $widthPct[$i] = $null
            $sidewaysFlag[$i] = $null
        }
    }

    # ---- Build per-bar snapshots ----
    $series = New-Object object[] $n

    for ($i=0; $i -lt $n; $i++) {
        $snap = if ($AsHashtable) { @{} } else { [pscustomobject]@{} }

        # Core OHLCV passthrough
        $snap.time   = $Time[$i]
        $snap.open   = $Open[$i]
        $snap.high   = $High[$i]
        $snap.low    = $Low[$i]
        $snap.close  = $Close[$i]
        $snap.volume = $Volume[$i]

        # ATR / TR
        $snap.tr  = $tr[$i]
        $snap.atr = $atr[$i]

        # Regime (0..100)
        $snap.regime_atr_pct = $regime[$i]

        # Volume features
        $snap.vol_z        = $vz.Z[$i]
        $snap.vol_zc       = $vz.ZClipped[$i]
        $snap.vol_mean     = $vz.Mean[$i]
        $snap.vol_std      = $vz.Std[$i]
        $snap.vol_z_degraded = [bool]$vz.Degraded[$i]

        $snap.vol_rank01     = $vp.Rank01[$i]
        $snap.vol_plow       = $vp.PLow[$i]
        $snap.vol_phigh      = $vp.PHigh[$i]
        $snap.vol_pctl_degraded = [bool]$vp.Degraded[$i]

        $snap.vol_surge_ratio   = $vs.Ratio[$i]
        $snap.vol_surge_base    = $vs.Baseline[$i]
        $snap.vol_surge_degraded = [bool]$vs.Degraded[$i]

        # Sideways / consolidation
        $snap.width_abs  = $width[$i]
        $snap.width_pct  = $widthPct[$i]
        $snap.is_sideways = $sidewaysFlag[$i]

        $series[$i] = $snap
    }

    # ---- Diagnostics ----
    $diag = @{
        status = $status
        issues = $issues.ToArray()
        counts = @{
            bars = $n
            nulls = @{
                atr = (_CountNull $atr)
                tr  = (_CountNull $tr)
                regime_atr_pct = (_CountNull $regime)
                vol_zc = (_CountNull $vz.ZClipped)
                vol_rank01 = (_CountNull $vp.Rank01)
                vol_surge_ratio = (_CountNull $vs.Ratio)
                width_abs = (_CountNull $width)
            }
            invalid_numbers = @{
                atr = (_CountInvalidNumber $atr)
                tr  = (_CountInvalidNumber $tr)
                regime_atr_pct = (_CountInvalidNumber $regime)
            }
            degraded_true = @{
                vol_z = ($vz.Degraded | Where-Object { $_ } | Measure-Object).Count
                vol_pctl = ($vp.Degraded | Where-Object { $_ } | Measure-Object).Count
                vol_surge = ($vs.Degraded | Where-Object { $_ } | Measure-Object).Count
            }
        }
        first_valid_index = @{
            atr = (_FirstValidIndex $atr)
            regime_atr_pct = (_FirstValidIndex $regime)
            vol_zc = (_FirstValidIndex $vz.ZClipped)
            vol_rank01 = (_FirstValidIndex $vp.Rank01)
            vol_surge_ratio = (_FirstValidIndex $vs.Ratio)
            width_abs = (_FirstValidIndex $width)
        }
        rates = @{
            vol_z_degraded = (_Rate -Numerator (($vz.Degraded | Where-Object { $_ } | Measure-Object).Count) -Denominator $n)
            vol_pctl_degraded = (_Rate -Numerator (($vp.Degraded | Where-Object { $_ } | Measure-Object).Count) -Denominator $n)
            vol_surge_degraded = (_Rate -Numerator (($vs.Degraded | Where-Object { $_ } | Measure-Object).Count) -Denominator $n)
        }
        config_used = @{
            symbol = $Symbol
            bars_per_week = $barsPerWeek
            min_bars_total = $minBarsTotal
            min_bars_for_indicators = $minBarsForIndicators
            atr = @{ enabled = $atrEnabled; period = $atrPeriod; method = $atrMethod }
            regime = @{ enabled = $regimeEnabled; window = $regimeWindow; method = $regimeInterp; output = 'percent_rank_0_100' }
            volume = @{
                lookback = $volLookback
                zscore = @{ enabled = $volZEnabled; clip = $volZClip }
                percentile = @{ enabled = $volPctEnabled; window = $volPctWindow; low_high = '5_95_rank_proxy_0_1' }
                surge_ratio = @{ enabled = $surgeEnabled; window = $surgeWindow; baseline = 'median' }
            }
            sideways = @{ enabled = $sidewaysEnabled; width_window_bars = $widthWindowBars; width_threshold = $widthThreshold }
        }
    }

    $meta = @{
        api = 'Compute-Indicators'
        version = '1.0.0'
        generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    }

    return [pscustomobject]@{
        Meta        = $meta
        Diagnostics = $diag
        Series      = $series
    }
}