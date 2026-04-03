# src/CupHandleDetector/Private/Atr.ps1
# True Range + ATR utilities
# Conventions:
# - Inputs: arrays (or array-like) of values castable to double
# - Missing data: $null/NaN/Infinity treated as missing
# - Output: [object[]] aligned to input length; emits [double] or $null
# - First bar guard: TR uses (High-Low) when PrevClose not available/invalid
# - ATR: Wilder's smoothing by default, seeded by SMA(TR, Period) at first eligible index

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

function Get-TrueRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$High,

        [Parameter(Mandatory)]
        [object[]]$Low,

        [Parameter(Mandatory)]
        [object[]]$Close
    )

    if ($High.Count -ne $Low.Count -or $High.Count -ne $Close.Count) {
        throw "High/Low/Close must have the same length."
    }

    $n = $High.Count
    $out = New-Object object[] $n

    $prevCloseValid = $false
    $prevClose = 0.0

    for ($i = 0; $i -lt $n; $i++) {
        $hOk = _IsValidNumber $High[$i]
        $lOk = _IsValidNumber $Low[$i]
        $cOk = _IsValidNumber $Close[$i]

        if (-not ($hOk -and $lOk -and $cOk)) {
            $out[$i] = $null
            # PrevClose update: only update if current close is valid
            if ($cOk) {
                $prevClose = [double]$Close[$i]
                $prevCloseValid = $true
            } else {
                $prevCloseValid = $false
            }
            continue
        }

        $h = [double]$High[$i]
        $l = [double]$Low[$i]
        $c = [double]$Close[$i]

        # Base range
        $rangeHL = [math]::Abs($h - $l)

        if ($i -eq 0 -or -not $prevCloseValid) {
            # First bar (or no prev close): TR = high-low
            $tr = $rangeHL
        } else {
            $rangeHC = [math]::Abs($h - $prevClose)
            $rangeLC = [math]::Abs($l - $prevClose)
            $tr = [math]::Max($rangeHL, [math]::Max($rangeHC, $rangeLC))
        }

        $out[$i] = $tr

        # Update prev close
        $prevClose = $c
        $prevCloseValid = $true
    }

    return $out
}

function Get-Atr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$High,

        [Parameter(Mandatory)]
        [object[]]$Low,

        [Parameter(Mandatory)]
        [object[]]$Close,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Period = 14,

        # If set, uses simple moving average of TR over the last Period each bar (not Wilder).
        [switch]$Simple
    )

    if ($High.Count -ne $Low.Count -or $High.Count -ne $Close.Count) {
        throw "High/Low/Close must have the same length."
    }

    $n = $High.Count
    $tr = Get-TrueRange -High $High -Low $Low -Close $Close
    $out = New-Object object[] $n

    if ($n -eq 0) { return $out }

    if ($Simple) {
        # Rolling SMA of TR with missing values breaking accumulation (emit null unless full Period of valid TR)
        $sum = 0.0
        $validCount = 0
        $buf = New-Object double[] $Period
        $bufValid = New-Object bool[] $Period

        for ($i = 0; $i -lt $n; $i++) {
            $idx = $i % $Period

            # remove outgoing
            if ($i -ge $Period -and $bufValid[$idx]) {
                $sum -= $buf[$idx]
                $validCount--
                $bufValid[$idx] = $false
            }

            # add incoming
            if (_IsValidNumber $tr[$i]) {
                $dv = [double]$tr[$i]
                $buf[$idx] = $dv
                $bufValid[$idx] = $true
                $sum += $dv
                $validCount++
            } else {
                $bufValid[$idx] = $false
            }

            if ($validCount -ge $Period) {
                $out[$i] = $sum / $Period
            } else {
                $out[$i] = $null
            }
        }

        return $out
    }

    # Wilder ATR:
    # - First ATR at first index where we have Period valid TRs: ATR = SMA(TR, Period)
    # - Thereafter: ATR = (prevATR*(Period-1) + TR) / Period
    $sumTR = 0.0
    $validCount = 0
    $seeded = $false
    $prevAtr = 0.0

    for ($i = 0; $i -lt $n; $i++) {
        $trOk = _IsValidNumber $tr[$i]

        if (-not $seeded) {
            if ($trOk) {
                $sumTR += [double]$tr[$i]
                $validCount++
            }

            if ($validCount -lt $Period) {
                $out[$i] = $null
            } else {
                $prevAtr = $sumTR / $Period
                $out[$i] = $prevAtr
                $seeded = $true
            }
        } else {
            if (-not $trOk) {
                # If TR missing, cannot update; emit null and invalidate smoothing until re-seeded.
                $out[$i] = $null
                $seeded = $false
                $sumTR = 0.0
                $validCount = 0
            } else {
                $prevAtr = (($prevAtr * ($Period - 1.0)) + ([double]$tr[$i])) / $Period
                $out[$i] = $prevAtr
            }
        }
    }

    return $out
}