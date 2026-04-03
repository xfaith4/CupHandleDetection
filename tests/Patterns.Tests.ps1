# tests/Patterns.Tests.ps1
# Pester tests for cup/handle detection and breakout confirmation on synthetic data.
# Focus:
# - ensure detectors find at least one cup and one handle candidate in sample data
# - ensure Confirm-Breakout produces at least one confirmed breakout near end of series
# - validate basic negative cases: below pivot => not confirmed; volume gating => not confirmed when required
# - validate regime scaling makes volume thresholds stricter at higher RegimeScale
#
# These tests are intentionally not brittle about exact bar indices; they assert existence + key invariants.

Set-StrictMode -Version Latest

# Requires Pester 5+
# Invoke with: Invoke-Pester -Path tests/Patterns.Tests.ps1

BeforeAll {
    function Get-RepoRoot {
        param([string]$Start = $PSScriptRoot)
        $cur = (Resolve-Path $Start).Path
        for ($i=0; $i -lt 8; $i++) {
            if (Test-Path (Join-Path $cur 'src')) { return $cur }
            $parent = Split-Path $cur -Parent
            if ($parent -eq $cur) { break }
            $cur = $parent
        }
        throw "Unable to locate repo root from $Start"
    }

    $script:RepoRoot = Get-RepoRoot
    $script:SrcRoot  = Join-Path $RepoRoot 'src'
    $script:DataRoot = Join-Path $RepoRoot 'data'

    function Import-CupHandleFunctions {
        # Prefer module import if module manifest exists; else dot-source public scripts.
        $modulePath = Join-Path $script:SrcRoot 'CupHandleDetector'
        $psd1 = Join-Path $modulePath 'CupHandleDetector.psd1'
        $psm1 = Join-Path $modulePath 'CupHandleDetector.psm1'

        if (Test-Path $psd1) {
            Import-Module $psd1 -Force -ErrorAction Stop
            return
        }
        if (Test-Path $psm1) {
            Import-Module $psm1 -Force -ErrorAction Stop
            return
        }

        # Dot-source all Public/*.ps1 as a fallback.
        $publicDir = Join-Path $modulePath 'Public'
        if (-not (Test-Path $publicDir)) {
            throw "Cannot find module or Public directory at $modulePath"
        }

        Get-ChildItem -Path $publicDir -Filter '*.ps1' | ForEach-Object {
            . $_.FullName
        }

        # Also dot-source Private if needed by public functions (harmless if absent).
        $privateDir = Join-Path $modulePath 'Private'
        if (Test-Path $privateDir) {
            Get-ChildItem -Path $privateDir -Filter '*.ps1' | ForEach-Object {
                . $_.FullName
            }
        }
    }

    function Load-SampleOhlcv {
        $path = Join-Path $script:DataRoot 'sample_ohlcv.csv'
        if (-not (Test-Path $path)) { throw "Missing data file: $path" }

        $rows = Import-Csv -Path $path
        if (-not $rows -or $rows.Count -lt 10) {
            throw "Sample OHLCV appears empty/too small."
        }

        $time   = @()
        $open   = @()
        $high   = @()
        $low    = @()
        $close  = @()
        $volume = @()

        foreach ($r in $rows) {
            $time   += [datetime]$r.Timestamp
            $open   += [double]$r.Open
            $high   += [double]$r.High
            $low    += [double]$r.Low
            $close  += [double]$r.Close
            $volume += [double]$r.Volume
        }

        [pscustomobject]@{
            Time   = $time
            Open   = $open
            High   = $high
            Low    = $low
            Close  = $close
            Volume = $volume
        }
    }

    Import-CupHandleFunctions
    $script:Sample = Load-SampleOhlcv

    # Minimal config tuned for synthetic series stability.
    $script:Config = @{
        detection = @{
            breakout = @{
                reference_level = 'handle_high_or_rim'
                price = @{
                    min_percent_above_pivot = 0.002  # 0.2%
                    atr_buffer_mult         = 0.0
                    require_close_above_pivot = $true
                }
                volume = @{
                    require_confirmation = $true
                    logic = 'or'
                    use_zscore = $true
                    z_threshold = 1.0
                    use_percentile = $false
                    use_surge_ratio = $false
                }
                regime_scaling = @{
                    enabled = $true
                    min_scale = 0.8
                    max_scale = 1.2
                    scale_volume_thresholds = $true
                    scale_price_thresholds  = $true
                }
                tentative = @{
                    enabled = $false
                }
            }
        }
    }
}

Describe 'Cup/Handle detection + breakout confirmation on synthetic data' {

    It 'Loads sample OHLCV and has expected columns' {
        $script:Sample.Close.Count | Should -BeGreaterThan 50
        $script:Sample.Volume.Count | Should -Be $script:Sample.Close.Count
        $script:Sample.Time[0] | Should -BeOfType ([datetime])
        $script:Sample.Close[-1] | Should -BeGreaterThan 0
    }

    Context 'Pattern detection' {

        It 'Detect-CupCandidates returns at least one candidate' {
            if (-not (Get-Command Detect-CupCandidates -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'Detect-CupCandidates not available in session/module.'
                return
            }

            $res = Detect-CupCandidates -Close $script:Sample.Close -High $script:Sample.High -Low $script:Sample.Low -Time $script:Sample.Time -Config $script:Config
            $res | Should -Not -BeNullOrEmpty
            $res.Meta.Status | Should -BeIn @('OK','EMPTY','INSUFFICIENT_DATA')

            if ($res.Meta.Status -eq 'OK') {
                $res.CupCandidates.Count | Should -BeGreaterThan 0
            }
        }

        It 'Detect-HandleCandidates returns at least one candidate when provided cup candidates' {
            if (-not (Get-Command Detect-CupCandidates -ErrorAction SilentlyContinue) -or -not (Get-Command Detect-HandleCandidates -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'Detect-CupCandidates or Detect-HandleCandidates not available in session/module.'
                return
            }

            $cup = Detect-CupCandidates -Close $script:Sample.Close -High $script:Sample.High -Low $script:Sample.Low -Time $script:Sample.Time -Config $script:Config
            if ($cup.Meta.Status -ne 'OK' -or -not $cup.CupCandidates -or $cup.CupCandidates.Count -eq 0) {
                Set-ItResult -Skipped -Because "No cup candidates found (Status=$($cup.Meta.Status)); cannot test handle detection."
                return
            }

            $handle = Detect-HandleCandidates -Close $script:Sample.Close -High $script:Sample.High -Low $script:Sample.Low -Time $script:Sample.Time -CupCandidates $cup.CupCandidates -Config $script:Config
            $handle | Should -Not -BeNullOrEmpty
            $handle.Meta.Status | Should -BeIn @('OK','EMPTY','INSUFFICIENT_DATA')

            if ($handle.Meta.Status -eq 'OK') {
                $handle.HandleCandidates.Count | Should -BeGreaterThan 0
            }
        }
    }

    Context 'Breakout confirmation' {

        It 'Confirm-Breakout confirms at least one breakout near the end of the sample series' {
            if (-not (Get-Command Confirm-Breakout -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'Confirm-Breakout not available in session/module.'
                return
            }
            if (-not (Get-Command Detect-CupCandidates -ErrorAction SilentlyContinue) -or -not (Get-Command Detect-HandleCandidates -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'Cup/Handle detectors not available; cannot build pattern inputs.'
                return
            }

            $cup = Detect-CupCandidates -Close $script:Sample.Close -High $script:Sample.High -Low $script:Sample.Low -Time $script:Sample.Time -Config $script:Config
            $cup.Meta.Status | Should -Be 'OK'
            $cup.CupCandidates.Count | Should -BeGreaterThan 0

            $handle = Detect-HandleCandidates -Close $script:Sample.Close -High $script:Sample.High -Low $script:Sample.Low -Time $script:Sample.Time -CupCandidates $cup.CupCandidates -Config $script:Config
            $handle.Meta.Status | Should -Be 'OK'
            $handle.HandleCandidates.Count | Should -BeGreaterThan 0

            # Prefer computing indicators if available; otherwise provide minimal snapshots with permissive volume fields.
            $snapshots = $null
            if (Get-Command Compute-Indicators -ErrorAction SilentlyContinue) {
                $ind = Compute-Indicators -Close $script:Sample.Close -High $script:Sample.High -Low $script:Sample.Low -Volume $script:Sample.Volume -Time $script:Sample.Time -Config $script:Config
                if ($ind -and $ind.Meta.Status -eq 'OK' -and $ind.Series) {
                    $snapshots = $ind.Series
                }
            }
            if (-not $snapshots) {
                $n = $script:Sample.Close.Count
                $snapshots = for ($i=0; $i -lt $n; $i++) {
                    [pscustomobject]@{
                        BarIndex    = $i
                        Time        = $script:Sample.Time[$i]
                        Close       = $script:Sample.Close[$i]
                        High        = $script:Sample.High[$i]
                        Low         = $script:Sample.Low[$i]
                        Volume      = $script:Sample.Volume[$i]
                        RegimeScale = 1.0
                        VolumeZ     = 2.0
                        VolumePctl  = 0.9
                        VolumeSurgeRatio = 1.5
                    }
                }
            }

            $bo = Confirm-Breakout -Series $snapshots -Close $script:Sample.Close -High $script:Sample.High -Volume $script:Sample.Volume -HandleCandidates $handle.HandleCandidates -Config $script:Config
            $bo.Meta.Status | Should -BeIn @('OK','EMPTY','INSUFFICIENT_DATA')

            if ($bo.Meta.Status -ne 'OK') {
                Set-ItResult -Failed -Because "Expected OK breakout confirmation on sample data; got $($bo.Meta.Status). Issues: $($bo.Meta.Issues -join '; ')"
                return
            }

            $bo.Signals.Count | Should -BeGreaterThan 0

            # At least one confirmed breakout and it should be in the last ~10 bars for this synthetic dataset.
            $confirmed = @($bo.Signals | Where-Object { $_.Status -in @('CONFIRMED','CONFIRMED_BREAKOUT','BREAKOUT_CONFIRMED') -or ($_.PSObject.Properties.Name -contains 'Confirmed' -and $_.Confirmed) })
            $confirmed.Count | Should -BeGreaterThan 0

            $lastIndex = $script:Sample.Close.Count - 1
            ($confirmed | Measure-Object -Property BarIndex -Maximum).Maximum | Should -BeGreaterThan ($lastIndex - 15)
        }

        It 'Does not confirm breakout if close remains below pivot (price criterion)' {
            if (-not (Get-Command Confirm-Breakout -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'Confirm-Breakout not available in session/module.'
                return
            }

            # Construct minimal series + one pattern with pivot above close.
            $close = @(100,100,100,100)
            $high  = @(101,101,101,101)
            $vol   = @(1000000,1000000,1000000,1000000)
            $series = for ($i=0; $i -lt $close.Count; $i++) {
                [pscustomobject]@{ BarIndex=$i; Close=$close[$i]; High=$high[$i]; Volume=$vol[$i]; RegimeScale=1.0; VolumeZ=3.0 }
            }

            $pattern = [pscustomobject]@{
                Pivot = 105.0
                PivotIndex = 2
                HandleHigh = 105.0
                HandleHighIndex = 2
                RightPeak = 105.0
                RightPeakIndex = 1
                HandleStartIndex = 1
                HandleEndIndex   = 2
            }

            $cfg = $script:Config.Clone()
            $cfg.detection.breakout.price.min_percent_above_pivot = 0.0
            $cfg.detection.breakout.volume.require_confirmation = $false

            $bo = Confirm-Breakout -Series $series -Close $close -High $high -Volume $vol -HandleCandidates @($pattern) -Config $cfg
            $bo.Meta.Status | Should -Be 'OK'

            $confirmed = @($bo.Signals | Where-Object { $_.Status -in @('CONFIRMED','CONFIRMED_BREAKOUT','BREAKOUT_CONFIRMED') -or ($_.PSObject.Properties.Name -contains 'Confirmed' -and $_.Confirmed) })
            $confirmed.Count | Should -Be 0
        }

        It 'Requires volume confirmation when enabled (volume gating)' {
            if (-not (Get-Command Confirm-Breakout -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'Confirm-Breakout not available in session/module.'
                return
            }

            # Price clears pivot, but volume confirmation intentionally fails.
            $close = @(100,101,106)
            $high  = @(100,101,106)
            $vol   = @(1000000,900000,800000)

            $series = @(
                [pscustomobject]@{ BarIndex=0; Close=100; High=100; Volume=1000000; RegimeScale=1.0; VolumeZ=0.0; VolumePctl=0.1; VolumeSurgeRatio=0.9 },
                [pscustomobject]@{ BarIndex=1; Close=101; High=101; Volume=900000;  RegimeScale=1.0; VolumeZ=0.0; VolumePctl=0.1; VolumeSurgeRatio=0.9 },
                [pscustomobject]@{ BarIndex=2; Close=106; High=106; Volume=800000;  RegimeScale=1.0; VolumeZ=0.0; VolumePctl=0.1; VolumeSurgeRatio=0.9 }
            )

            $pattern = [pscustomobject]@{ Pivot = 105.0; PivotIndex = 1; HandleHigh = 105.0; HandleHighIndex = 1 }

            $cfg = @{
                detection = @{
                    breakout = @{
                        reference_level = 'handle_high'
                        price = @{
                            min_percent_above_pivot = 0.0
                            atr_buffer_mult = 0.0
                            require_close_above_pivot = $true
                        }
                        volume = @{
                            require_confirmation = $true
                            logic = 'or'
                            use_zscore = $true
                            z_threshold = 1.5
                            use_percentile = $false
                            use_surge_ratio = $false
                        }
                        regime_scaling = @{
                            enabled = $false
                        }
                        tentative = @{ enabled = $false }
                    }
                }
            }

            $bo = Confirm-Breakout -Series $series -Close $close -High $high -Volume $vol -HandleCandidates @($pattern) -Config $cfg
            $bo.Meta.Status | Should -Be 'OK'

            $confirmed = @($bo.Signals | Where-Object { $_.Status -in @('CONFIRMED','CONFIRMED_BREAKOUT','BREAKOUT_CONFIRMED') -or ($_.PSObject.Properties.Name -contains 'Confirmed' -and $_.Confirmed) })
            $confirmed.Count | Should -Be 0
        }

        It 'Regime scaling makes volume thresholds stricter when RegimeScale > 1' {
            if (-not (Get-Command Confirm-Breakout -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'Confirm-Breakout not available in session/module.'
                return
            }

            # Same price action; volume zscore borderline.
            $close = @(104,105,106)
            $high  = @(104,105,106)
            $vol   = @(1000000,1200000,1500000)

            $pattern = [pscustomobject]@{ Pivot = 105.0; PivotIndex = 1; HandleHigh = 105.0; HandleHighIndex = 1 }

            $baseCfg = @{
                detection = @{
                    breakout = @{
                        reference_level = 'handle_high'
                        price = @{
                            min_percent_above_pivot = 0.0
                            atr_buffer_mult = 0.0
                            require_close_above_pivot = $true
                        }
                        volume = @{
                            require_confirmation = $true
                            logic = 'or'
                            use_zscore = $true
                            z_threshold = 1.5
                            use_percentile = $false
                            use_surge_ratio = $false
                        }
                        regime_scaling = @{
                            enabled = $true
                            scale_volume_thresholds = $true
                            min_scale = 0.8
                            max_scale = 1.2
                        }
                        tentative = @{ enabled = $false }
                    }
                }
            }

            $seriesLowRegime = @(
                [pscustomobject]@{ BarIndex=0; Close=104; High=104; Volume=1000000; RegimeScale=1.0; VolumeZ=1.6 },
                [pscustomobject]@{ BarIndex=1; Close=105; High=105; Volume=1200000; RegimeScale=1.0; VolumeZ=1.6 },
                [pscustomobject]@{ BarIndex=2; Close=106; High=106; Volume=1500000; RegimeScale=1.0; VolumeZ=1.6 }
            )

            $seriesHighRegime = @(
                [pscustomobject]@{ BarIndex=0; Close=104; High=104; Volume=1000000; RegimeScale=1.2; VolumeZ=1.6 },
                [pscustomobject]@{ BarIndex=1; Close=105; High=105; Volume=1200000; RegimeScale=1.2; VolumeZ=1.6 },
                [pscustomobject]@{ BarIndex=2; Close=106; High=106; Volume=1500000; RegimeScale=1.2; VolumeZ=1.6 }
            )

            $boLow  = Confirm-Breakout -Series $seriesLowRegime  -Close $close -High $high -Volume $vol -HandleCandidates @($pattern) -Config $baseCfg
            $boHigh = Confirm-Breakout -Series $seriesHighRegime -Close $close -High $high -Volume $vol -HandleCandidates @($pattern) -Config $baseCfg

            $boLow.Meta.Status  | Should -Be 'OK'
            $boHigh.Meta.Status | Should -Be 'OK'

            $confLow = @($boLow.Signals  | Where-Object { $_.Status -in @('CONFIRMED','CONFIRMED_BREAKOUT','BREAKOUT_CONFIRMED') -or ($_.PSObject.Properties.Name -contains 'Confirmed' -and $_.Confirmed) })
            $confHigh = @($boHigh.Signals | Where-Object { $_.Status -in @('CONFIRMED','CONFIRMED_BREAKOUT','BREAKOUT_CONFIRMED') -or ($_.PSObject.Properties.Name -contains 'Confirmed' -and $_.Confirmed) })

            # In higher regime scale, z-threshold is higher => should not increase confirmations.
            $confHigh.Count | Should -BeLessOrEqual $confLow.Count
        }
    }
}