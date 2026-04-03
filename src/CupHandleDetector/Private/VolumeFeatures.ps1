# src/CupHandleDetector/Private/VolumeFeatures.ps1
# Volume normalization features for Cup/Handle detection.
#
# Implements:
# - Z-score normalization with clipping (rolling mean/std)
# - Rolling percentile features
# - Surge ratio vs rolling baseline (mean/median) with degraded flags
#
# Output conventions:
# - All feature arrays are aligned to input length.
# - Missing/invalid inputs produce $null feature values.
# - "Degraded" flags indicate the feature could not be computed robustly at that bar.

Set-StrictMode -Version Latest

# Dot-source dependencies (same folder)
$script:_thisDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $script:_thisDir 'RollingStats.ps1')
. (Join-Path $script:_thisDir 'RollingPercentile.ps1')

function _IsFinite {
    param([object]$x)
    if ($null -eq $x) { return $false }
    try {
        $d = [double]$x
        return -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
    } catch { return $false }
}

function _SafeDiv {
    param(
        [Parameter(Mandatory)][double]$Num,
        [Parameter(Mandatory)][double]$Den,
        [double]$Eps = 1e-12
    )
    if ([double]::IsNaN($Num) -or [double]::IsInfinity($Num)) { return $null }
    if ([double]::IsNaN($Den) -or [double]::IsInfinity($Den)) { return $null }
    if ([math]::Abs($Den) -le $Eps) { return $null }
    return ($Num / $Den)
}

function Get-VolumeZScoreClipped {
    <#
    .SYNOPSIS
      Rolling z-score of volume with symmetric clipping.
    .PARAMETER Volume
      [object[]] numeric; $null/NaN/Inf treated as missing.
    .PARAMETER Window
      Rolling window size.
    .PARAMETER MinPeriods
      Minimum valid periods required (default = Window).
      NOTE: RollingStats currently enforces strict window validity; MinPeriods is used only for degraded flags.
    .PARAMETER Clip
      Absolute clip level for z-score, e.g. 3.0.
    .PARAMETER SampleStd
      Use sample std if set; otherwise population std.
    .PARAMETER StdEps
      Minimum std; if std < StdEps, z-score is $null and degraded.
    .OUTPUTS
      PSCustomObject { Z = object[]; Mean = object[]; Std = object[]; Degraded = bool[] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Volume,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Window,
        [ValidateRange(1, [int]::MaxValue)][int]$MinPeriods = $Window,
        [ValidateRange(0.0, [double]::MaxValue)][double]$Clip = 3.0,
        [switch]$SampleStd,
        [ValidateRange(0.0, [double]::MaxValue)][double]$StdEps = 1e-9
    )

    $n = $Volume.Count
    $z = New-Object object[] $n
    $degraded = New-Object bool[] $n

    $mean = Get-RollingMean -Values $Volume -Window $Window
    $std  = Get-RollingStd  -Values $Volume -Window $Window -Sample:$SampleStd

    for ($i = 0; $i -lt $n; $i++) {
        $v = $Volume[$i]
        $m = $mean[$i]
        $s = $std[$i]

        if (-not (_IsFinite $v) -or $null -eq $m -or $null -eq $s) {
            $z[$i] = $null
            $degraded[$i] = $true
            continue
        }

        $ds = [double]$s
        if ($ds -lt $StdEps) {
            $z[$i] = $null
            $degraded[$i] = $true
            continue
        }

        $raw = ([double]$v - [double]$m) / $ds
        if ($Clip -gt 0) {
            if ($raw -gt $Clip) { $raw = $Clip }
            elseif ($raw -lt (-1.0 * $Clip)) { $raw = -1.0 * $Clip }
        }
        $z[$i] = [double]$raw

        # RollingStats requires full valid window; if caller asked MinPeriods < Window,
        # we still treat early bars as degraded if mean/std missing (already handled).
        $degraded[$i] = $false
    }

    [pscustomobject]@{
        Z        = $z
        Mean     = $mean
        Std      = $std
        Degraded = $degraded
    }
}

function Get-VolumePercentileFeatures {
    <#
    .SYNOPSIS
      Rolling percentile-derived features.
    .DESCRIPTION
      Computes rolling percentile threshold (Pth volume) and feature(s):
      - AboveP: whether current volume >= Pth (boolean, $null if missing)
      - PthValue: the rolling percentile value
      Optionally computes a coarse "rank proxy" in 0..1 using rolling min/max
      proxies via P0/P100 percentiles.
    .PARAMETER Volume
      [object[]] volume series
    .PARAMETER Window
      Rolling window
    .PARAMETER Percentile
      0..100 percentile threshold (e.g., 80 for high-volume bar relative to lookback)
    .PARAMETER MinPeriods
      Minimum valid samples needed in window to emit Pth (passed to Get-RollingPercentile)
    .PARAMETER Interpolation
      Percentile interpolation mode
    .PARAMETER IncludeRankProxy
      If set, computes Rank01Proxy using rolling P0 and P100 as min/max proxies.
    .OUTPUTS
      PSCustomObject { PthValue=object[]; AboveP=object[]; Rank01Proxy=object[]; Degraded=bool[] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Volume,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Window,
        [Parameter(Mandatory)][ValidateRange(0.0, 100.0)][double]$Percentile,
        [ValidateRange(1, [int]::MaxValue)][int]$MinPeriods = $Window,
        [ValidateSet('Linear','Lower','Higher','Nearest')][string]$Interpolation = 'Linear',
        [switch]$IncludeRankProxy
    )

    $n = $Volume.Count
    $pth = Get-RollingPercentile -Values $Volume -Window $Window -Percentile $Percentile -MinPeriods $MinPeriods -Interpolation $Interpolation

    $above = New-Object object[] $n
    $rank = New-Object object[] $n
    $degraded = New-Object bool[] $n

    $p0 = $null
    $p100 = $null
    if ($IncludeRankProxy) {
        $p0 = Get-RollingPercentile -Values $Volume -Window $Window -Percentile 0.0   -MinPeriods $MinPeriods -Interpolation 'Lower'
        $p100 = Get-RollingPercentile -Values $Volume -Window $Window -Percentile 100.0 -MinPeriods $MinPeriods -Interpolation 'Higher'
    }

    for ($i = 0; $i -lt $n; $i++) {
        $v = $Volume[$i]
        if (-not (_IsFinite $v)) {
            $above[$i] = $null
            $rank[$i] = $null
            $degraded[$i] = $true
            continue
        }

        $t = $pth[$i]
        if ($null -eq $t) {
            $above[$i] = $null
            $rank[$i] = $null
            $degraded[$i] = $true
            continue
        }

        $above[$i] = ([double]$v -ge [double]$t)

        if ($IncludeRankProxy) {
            $mn = $p0[$i]
            $mx = $p100[$i]
            if ($null -eq $mn -or $null -eq $mx) {
                $rank[$i] = $null
                $degraded[$i] = $true
            } else {
                $den = ([double]$mx - [double]$mn)
                $r = _SafeDiv -Num ([double]$v - [double]$mn) -Den $den -Eps 1e-12
                if ($null -eq $r) {
                    $rank[$i] = $null
                    $degraded[$i] = $true
                } else {
                    # Clamp to [0,1]
                    if ($r -lt 0) { $r = 0.0 }
                    elseif ($r -gt 1) { $r = 1.0 }
                    $rank[$i] = [double]$r
                    $degraded[$i] = $false
                }
            }
        } else {
            $rank[$i] = $null
            $degraded[$i] = $false
        }
    }

    [pscustomobject]@{
        PthValue    = $pth
        AboveP      = $above
        Rank01Proxy = $rank
        Degraded    = $degraded
    }
}

function Get-VolumeSurgeRatio {
    <#
    .SYNOPSIS
      Ratio of current volume to rolling baseline (mean or median).
    .PARAMETER Volume
      [object[]] volume series
    .PARAMETER Window
      Lookback window
    .PARAMETER Baseline
      'Mean' or 'Median'
    .PARAMETER MinPeriods
      Minimum periods required to compute baseline. For Mean: enforced strictly by RollingMean.
      For Median: enforced strictly by RollingMedian. MinPeriods used for degraded semantics only.
    .PARAMETER BaselineEps
      If baseline <= BaselineEps, ratio is $null (degraded).
    .PARAMETER Cap
      Optional cap for ratio to limit outlier impact (0 means no cap).
    .OUTPUTS
      PSCustomObject { Ratio=object[]; Baseline=object[]; Degraded=bool[] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Volume,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Window,
        [ValidateSet('Mean','Median')][string]$Baseline = 'Median',
        [ValidateRange(1, [int]::MaxValue)][int]$MinPeriods = $Window,
        [ValidateRange(0.0, [double]::MaxValue)][double]$BaselineEps = 1e-9,
        [ValidateRange(0.0, [double]::MaxValue)][double]$Cap = 0.0
    )

    $n = $Volume.Count
    $ratio = New-Object object[] $n
    $degraded = New-Object bool[] $n

    $baseArr = switch ($Baseline) {
        'Mean'   { Get-RollingMean -Values $Volume -Window $Window }
        default  { Get-RollingMedian -Values $Volume -Window $Window }
    }

    for ($i = 0; $i -lt $n; $i++) {
        $v = $Volume[$i]
        $b = $baseArr[$i]
        if (-not (_IsFinite $v) -or $null -eq $b) {
            $ratio[$i] = $null
            $degraded[$i] = $true
            continue
        }

        $db = [double]$b
        if ($db -le $BaselineEps) {
            $ratio[$i] = $null
            $degraded[$i] = $true
            continue
        }

        $r = [double]$v / $db
        if ($Cap -gt 0 -and $r -gt $Cap) { $r = $Cap }
        $ratio[$i] = [double]$r
        $degraded[$i] = $false
    }

    [pscustomobject]@{
        Ratio    = $ratio
        Baseline = $baseArr
        Degraded = $degraded
    }
}

function New-VolumeFeatures {
    <#
    .SYNOPSIS
      Convenience orchestrator to compute common volume normalization features.
    .PARAMETER Volume
      Volume series
    .PARAMETER ZWindow
      Window for z-score mean/std
    .PARAMETER ZClip
      Z-score clip
    .PARAMETER PercentileWindow
      Window for percentile features
    .PARAMETER Percentile
      Percentile threshold used for AboveP and PthValue
    .PARAMETER SurgeWindow
      Window for surge ratio baseline
    .PARAMETER SurgeBaseline
      Mean or Median
    .OUTPUTS
      PSCustomObject { ZScoreClipped, ZDegraded, PthValue, AboveP, Rank01Proxy, PctDegraded, SurgeRatio, SurgeDegraded }
      Each property is an array aligned to input.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Volume,

        [ValidateRange(1, [int]::MaxValue)][int]$ZWindow = 20,
        [ValidateRange(0.0, [double]::MaxValue)][double]$ZClip = 3.0,

        [ValidateRange(1, [int]::MaxValue)][int]$PercentileWindow = 20,
        [ValidateRange(0.0, 100.0)][double]$Percentile = 80.0,
        [switch]$IncludeRankProxy,

        [ValidateRange(1, [int]::MaxValue)][int]$SurgeWindow = 20,
        [ValidateSet('Mean','Median')][string]$SurgeBaseline = 'Median'
    )

    $z = Get-VolumeZScoreClipped -Volume $Volume -Window $ZWindow -Clip $ZClip
    $p = Get-VolumePercentileFeatures -Volume $Volume -Window $PercentileWindow -Percentile $Percentile -IncludeRankProxy:$IncludeRankProxy
    $s = Get-VolumeSurgeRatio -Volume $Volume -Window $SurgeWindow -Baseline $SurgeBaseline

    [pscustomobject]@{
        ZScoreClipped = $z.Z
        ZMean         = $z.Mean
        ZStd          = $z.Std
        ZDegraded     = $z.Degraded

        PthValue      = $p.PthValue
        AboveP        = $p.AboveP
        Rank01Proxy   = $p.Rank01Proxy
        PctDegraded   = $p.Degraded

        SurgeRatio    = $s.Ratio
        SurgeBaseline = $s.Baseline
        SurgeDegraded = $s.Degraded
    }
}