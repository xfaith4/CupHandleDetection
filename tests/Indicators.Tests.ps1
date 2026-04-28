# tests/Indicators.Tests.ps1
# Pester tests for core indicators:
# - Volume z-score clipping
# - Volume percentile correctness
# - ATR (TR + Wilder/simple behavior)
# - Regime R bounds
#
# These tests aim to validate math invariants and edge behavior without
# depending on large datasets.

Set-StrictMode -Version Latest

Describe 'Indicators - unit and integration checks' {

    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $privateDir = Join-Path $repoRoot 'src/CupHandleDetector/Private'
        $publicDir  = Join-Path $repoRoot 'src/CupHandleDetector/Public'

        $atrPath     = Join-Path $privateDir 'Atr.ps1'
        $volPath     = Join-Path $privateDir 'VolumeFeatures.ps1'
        $regimePath  = Join-Path $privateDir 'Regime.ps1'
        $computePath = Join-Path $publicDir  'Compute-Indicators.ps1'

        if (Test-Path -LiteralPath $atrPath)     { . $atrPath }
        if (Test-Path -LiteralPath $volPath)     { . $volPath }
        if (Test-Path -LiteralPath $regimePath)  { . $regimePath }
        if (Test-Path -LiteralPath $computePath) { . $computePath }
    }

    Context 'Volume z-score clipping' {

        It 'Clips z-scores to +/- Clip when extreme outlier present' {
            # Prefer calling the private function if available; otherwise use Compute-Indicators.
            $vol = @(100,100,100,100,100,100,100,100,100, 100000) # last is huge outlier
            $lookback = 9
            $clip = 2.0

            $z = $null

            if (Get-Command -Name Get-VolumeZScore -ErrorAction SilentlyContinue) {
                $z = Get-VolumeZScore -Volume $vol -Lookback $lookback -Clip $clip
            } elseif (Get-Command -Name Compute-Indicators -ErrorAction SilentlyContinue) {
                # Minimal OHLC arrays to satisfy API
                $n = $vol.Count
                $close = 1..$n | ForEach-Object { 100.0 }
                $high  = 1..$n | ForEach-Object { 101.0 }
                $low   = 1..$n | ForEach-Object {  99.0 }
                $open  = $close

                $cfg = @{
                    data = @{
                        requirements = @{
                            min_bars_total = 0
                            min_bars_for_indicators = 0
                        }
                    }
                    indicators = @{
                        atr = @{ enabled = $false }
                        regime = @{ enabled = $false }
                        sideways = @{ enabled = $false }
                        volume = @{
                            lookback = $lookback
                            zscore = @{ enabled = $true; clip = $clip }
                            percentile = @{ enabled = $false }
                            surge_ratio = @{ enabled = $false }
                        }
                    }
                }

                $res = Compute-Indicators -Open $open -High $high -Low $low -Close $close -Volume $vol -Config $cfg -AllowInsufficientHistory
                $z = @($res.Series | ForEach-Object { $_.Volume.Z })
            } else {
                throw "Neither Get-VolumeZScore nor Compute-Indicators is available to test z-score clipping."
            }

            # Find last non-null value and ensure it is clipped.
            $last = $z[-1]
            $last | Should -Not -BeNullOrEmpty
            ([double]$last) | Should -BeLessOrEqual $clip
            ([double]$last) | Should -BeGreaterOrEqual (-1.0 * $clip)

            # With an extreme outlier, the clipped z is expected to hit the boundary (or very near).
            ([math]::Abs([double]$last)) | Should -Be $clip
        }

        It 'Returns nulls until enough lookback history is available (no premature z-score)' {
            $vol = @(10,11,12,13,14)
            $lookback = 5
            $clip = 6.0

            if (-not (Get-Command -Name Get-VolumeZScore -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because "Get-VolumeZScore not available; skipping strict null-history unit test."
                return
            }

            $z = Get-VolumeZScore -Volume $vol -Lookback $lookback -Clip $clip

            # With lookback=5, typically first computable is index 4 (depending on implementation);
            # ensure prior are null.
            for ($i=0; $i -lt 4; $i++) {
                $z[$i] | Should -Be $null
            }
        }
    }

    Context 'Volume percentile correctness' {

        It 'Percentile is within [0,1] and increases with higher rank in a strictly increasing window' {
            $vol = @(1,2,3,4,5,6,7,8,9,10)
            $lookback = 5

            $pct = $null
            if (Get-Command -Name Get-VolumePercentile -ErrorAction SilentlyContinue) {
                $pct = Get-VolumePercentile -Volume $vol -Lookback $lookback
            } elseif (Get-Command -Name Compute-Indicators -ErrorAction SilentlyContinue) {
                $n = $vol.Count
                $close = 1..$n | ForEach-Object { 100.0 }
                $high  = 1..$n | ForEach-Object { 101.0 }
                $low   = 1..$n | ForEach-Object {  99.0 }
                $open  = $close

                $cfg = @{
                    data = @{
                        requirements = @{
                            min_bars_total = 0
                            min_bars_for_indicators = 0
                        }
                    }
                    indicators = @{
                        atr = @{ enabled = $false }
                        regime = @{ enabled = $false }
                        sideways = @{ enabled = $false }
                        volume = @{
                            lookback = $lookback
                            zscore = @{ enabled = $false }
                            percentile = @{ enabled = $true; lookback = $lookback }
                            surge_ratio = @{ enabled = $false }
                        }
                    }
                }

                $res = Compute-Indicators -Open $open -High $high -Low $low -Close $close -Volume $vol -Config $cfg -AllowInsufficientHistory
                $pct = @($res.Series | ForEach-Object { $_.Volume.Percentile })
            } else {
                throw "Neither Get-VolumePercentile nor Compute-Indicators is available to test percentile."
            }

            # Bounds check for all non-null entries
            foreach ($p in $pct) {
                if ($null -eq $p) { continue }
                ([double]$p) | Should -BeGreaterOrEqual 0.0
                ([double]$p) | Should -BeLessOrEqual 1.0
            }

            # In a strictly increasing series, once the rolling window is "active",
            # percentile at the end should be at/near the top of the window.
            $last = $pct[-1]
            $last | Should -Not -BeNullOrEmpty
            ([double]$last) | Should -BeGreaterOrEqual 0.8
        }

        It 'Constant volumes produce a stable percentile (no NaN/Infinity)' {
            $vol = @(100,100,100,100,100,100,100,100,100,100)
            $lookback = 5

            if (-not (Get-Command -Name Get-VolumePercentile -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because "Get-VolumePercentile not available; skipping NaN/Infinity percentile unit test."
                return
            }

            $pct = Get-VolumePercentile -Volume $vol -Lookback $lookback
            foreach ($p in $pct) {
                if ($null -eq $p) { continue }
                $d = [double]$p
                ([double]::IsNaN($d) -or [double]::IsInfinity($d)) | Should -BeFalse
                $d | Should -BeGreaterOrEqual 0.0
                $d | Should -BeLessOrEqual 1.0
            }
        }
    }

    Context 'ATR and TR correctness' {

        It 'True Range matches hand-computed values for a small OHLC set' {
            if (-not (Get-Command -Name Get-TrueRange -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because "Get-TrueRange not available; skipping TR unit test."
                return
            }

            # Construct 4 bars with known previous close effects:
            # Bar0: TR = High-Low = 10-8 = 2
            # Bar1: prevClose=9, high-low=2, |high-prev|=|11-9|=2, |low-prev|=|9-9|=0 => TR=2
            # Bar2: prevClose=10, high-low=1, |high-prev|=|12-10|=2, |low-prev|=|11-10|=1 => TR=2
            # Bar3: prevClose=11.5, high-low=4, |high-prev|=|13-11.5|=1.5, |low-prev|=|9-11.5|=2.5 => TR=4
            $high  = @(10.0, 11.0, 12.0, 13.0)
            $low   = @( 8.0,  9.0, 11.0,  9.0)
            $close = @( 9.0, 10.0, 11.5, 12.0)

            $tr = Get-TrueRange -High $high -Low $low -Close $close

            $tr.Count | Should -Be 4
            [double]$tr[0] | Should -Be 2.0
            [double]$tr[1] | Should -Be 2.0
            [double]$tr[2] | Should -Be 2.0
            [double]$tr[3] | Should -Be 4.0
        }

        It 'ATR(simple) equals SMA of TR over the lookback window (when available)' {
            if (-not (Get-Command -Name Get-Atr -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because "Get-Atr not available; skipping ATR unit test."
                return
            }

            $high  = @(10.0, 11.0, 12.0, 13.0, 14.0)
            $low   = @( 8.0,  9.0, 11.0,  9.0, 12.0)
            $close = @( 9.0, 10.0, 11.5, 12.0, 13.0)

            $period = 3
            $atrS = Get-Atr -High $high -Low $low -Close $close -Period $period -Simple

            # compute TR manually using the library if present, else skip
            if (-not (Get-Command -Name Get-TrueRange -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because "Get-TrueRange not available; can't validate ATR(simple) vs SMA(TR)."
                return
            }
            $tr = Get-TrueRange -High $high -Low $low -Close $close

            # first defined ATR(simple) likely at index period-1
            $i = $period - 1
            $expected = ([double]$tr[$i] + [double]$tr[$i-1] + [double]$tr[$i-2]) / 3.0

            $atrS[$i] | Should -Not -BeNullOrEmpty
            ([double]$atrS[$i]) | Should -BeExactly $expected
        }

        It 'ATR(wilder) is finite and non-negative for all computed points' {
            if (-not (Get-Command -Name Get-Atr -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because "Get-Atr not available; skipping ATR Wilder unit test."
                return
            }

            $n = 60
            $close = 1..$n | ForEach-Object { [double](100 + $_ * 0.1) }
            $high  = 0..($n-1) | ForEach-Object { $close[$_] + 1.0 }
            $low   = 0..($n-1) | ForEach-Object { $close[$_] - 1.0 }

            $atrW = Get-Atr -High $high -Low $low -Close $close -Period 14

            foreach ($a in $atrW) {
                if ($null -eq $a) { continue }
                $d = [double]$a
                ([double]::IsNaN($d) -or [double]::IsInfinity($d)) | Should -BeFalse
                $d | Should -BeGreaterOrEqual 0.0
            }
        }
    }

    Context 'Regime R bounds' {

        It 'Regime R stays within [0,1] when computed (percentile-like output)' {
            # We try direct private function first; otherwise test via Compute-Indicators.
            $n = 220
            $close = 1..$n | ForEach-Object { [double](100 + [math]::Sin($_/10.0)) }
            $high  = 0..($n-1) | ForEach-Object { $close[$_] + 1.0 }
            $low   = 0..($n-1) | ForEach-Object { $close[$_] - 1.0 }
            $open  = $close
            $vol   = 1..$n | ForEach-Object { 1000000 }

            $R = $null
            if (Get-Command -Name Get-Regime -ErrorAction SilentlyContinue) {
                # Get-Regime expected to use ATR and rolling percentile window internally.
                $reg = Get-Regime -High $high -Low $low -Close $close -Window 100
                if ($reg -is [hashtable] -or $reg -is [System.Collections.IDictionary]) {
                    $R = $reg.R
                } else {
                    # If it returns a custom object, attempt property.
                    $R = $reg.R
                }
            } elseif (Get-Command -Name Compute-Indicators -ErrorAction SilentlyContinue) {
                $cfg = @{
                    data = @{
                        requirements = @{
                            min_bars_total = 0
                            min_bars_for_indicators = 0
                        }
                    }
                    indicators = @{
                        atr = @{ enabled = $true; lookback = 14; method = 'wilder' }
                        regime = @{ enabled = $true; atr_percentile_lookback = 100; percentile_method = 'rank' }
                        sideways = @{ enabled = $false }
                        volume = @{
                            lookback = 50
                            zscore = @{ enabled = $false }
                            percentile = @{ enabled = $false }
                            surge_ratio = @{ enabled = $false }
                        }
                    }
                }
                $res = Compute-Indicators -Open $open -High $high -Low $low -Close $close -Volume $vol -Config $cfg -AllowInsufficientHistory
                $R = @($res.Series | ForEach-Object { $_.Regime.R })
            } else {
                throw "Neither Get-Regime nor Compute-Indicators is available to test Regime R."
            }

            $R | Should -Not -BeNullOrEmpty

            foreach ($r in $R) {
                if ($null -eq $r) { continue }
                $d = [double]$r
                ([double]::IsNaN($d) -or [double]::IsInfinity($d)) | Should -BeFalse
                $d | Should -BeGreaterOrEqual 0.0
                $d | Should -BeLessOrEqual 1.0
            }
        }
    }
}
