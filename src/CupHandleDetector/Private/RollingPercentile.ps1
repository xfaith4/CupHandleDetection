# src/CupHandleDetector/Private/RollingPercentile.ps1
# Rolling Percentile utility
# - Rolling percentile: O(N log W) using sorted multiset (sorted list) with binary insert/evict
# Conventions:
# - Input: [object[]] (or anything castable to double); $null/NaN/Infinity treated as missing (not counted)
# - Output: [object[]] aligned to input length; values are [double] or $null when insufficient lookback
# - MinPeriods: minimum valid observations required to emit a value (default = Window)
# - Percentile: 0..100
# - Interpolation:
#   - Linear  : default; like Excel PERCENTILE.INC / numpy percentile linear-ish
#   - Lower   : floor index
#   - Higher  : ceil index
#   - Nearest : round index

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

function _BinarySearchLeft {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[double]]$List,
        [Parameter(Mandatory)]
        [double]$Value
    )
    # First index i where List[i] >= Value
    $lo = 0
    $hi = $List.Count
    while ($lo -lt $hi) {
        $mid = $lo + [int](($hi - $lo) / 2)
        if ($List[$mid] -lt $Value) { $lo = $mid + 1 } else { $hi = $mid }
    }
    return $lo
}

function _BinarySearchRight {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[double]]$List,
        [Parameter(Mandatory)]
        [double]$Value
    )
    # First index i where List[i] > Value
    $lo = 0
    $hi = $List.Count
    while ($lo -lt $hi) {
        $mid = $lo + [int](($hi - $lo) / 2)
        if ($List[$mid] -le $Value) { $lo = $mid + 1 } else { $hi = $mid }
    }
    return $lo
}

function _SortedInsert {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[double]]$List,
        [Parameter(Mandatory)]
        [double]$Value
    )
    $idx = _BinarySearchRight -List $List -Value $Value
    $List.Insert($idx, $Value)
}

function _SortedRemoveOne {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[double]]$List,
        [Parameter(Mandatory)]
        [double]$Value
    )

    if ($List.Count -eq 0) { return $false }

    $idx = _BinarySearchLeft -List $List -Value $Value
    if ($idx -lt $List.Count -and $List[$idx] -eq $Value) {
        $List.RemoveAt($idx)
        return $true
    }

    # Fallback: if floating comparison fails due to tiny rounding differences,
    # attempt to locate within the equal-run range using a tolerant scan.
    # (Should rarely trigger since we remove values we inserted.)
    $right = _BinarySearchRight -List $List -Value $Value
    if ($idx -lt $right) {
        for ($j = $idx; $j -lt $right; $j++) {
            if ($List[$j] -eq $Value) {
                $List.RemoveAt($j)
                return $true
            }
        }
    }

    return $false
}

function _GetPercentileFromSorted {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[double]]$Sorted,
        [Parameter(Mandatory)]
        [ValidateRange(0.0, 100.0)]
        [double]$Percentile,
        [Parameter(Mandatory)]
        [ValidateSet('Linear','Lower','Higher','Nearest')]
        [string]$Interpolation
    )

    $n = $Sorted.Count
    if ($n -le 0) { return $null }
    if ($n -eq 1) { return [double]$Sorted[0] }

    $p = $Percentile / 100.0

    # Inclusive definition: position in [0, n-1]
    $pos = $p * ($n - 1)
    $lo = [int][math]::Floor($pos)
    $hi = [int][math]::Ceiling($pos)

    switch ($Interpolation) {
        'Lower'   { return [double]$Sorted[$lo] }
        'Higher'  { return [double]$Sorted[$hi] }
        'Nearest' {
            $k = [int][math]::Round($pos, [System.MidpointRounding]::AwayFromZero)
            if ($k -lt 0) { $k = 0 }
            elseif ($k -gt ($n - 1)) { $k = $n - 1 }
            return [double]$Sorted[$k]
        }
        default { # Linear
            if ($hi -eq $lo) { return [double]$Sorted[$lo] }
            $w = $pos - $lo
            $a = $Sorted[$lo]
            $b = $Sorted[$hi]
            return [double]($a + $w * ($b - $a))
        }
    }
}

function Get-RollingPercentile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Values,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Window,

        [Parameter(Mandatory)]
        [ValidateRange(0.0, 100.0)]
        [double]$Percentile,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MinPeriods = $Window,

        [ValidateSet('Linear','Lower','Higher','Nearest')]
        [string]$Interpolation = 'Linear'
    )

    $n = $Values.Count
    $out = New-Object object[] $n

    # Sorted multiset for current window valid values
    $sorted = [System.Collections.Generic.List[double]]::new()

    # Circular buffer to know what to evict
    $bufVal = New-Object double[] $Window
    $bufValid = New-Object bool[] $Window
    $validCount = 0

    for ($i = 0; $i -lt $n; $i++) {
        $idx = $i % $Window

        # Evict outgoing element (if any)
        if ($i -ge $Window -and $bufValid[$idx]) {
            $old = $bufVal[$idx]
            [void](_SortedRemoveOne -List $sorted -Value $old)
            $bufValid[$idx] = $false
            $validCount--
        }

        # Insert incoming element (if valid)
        $v = $Values[$i]
        if (_IsValidNumber $v) {
            $dv = [double]$v
            $bufVal[$idx] = $dv
            $bufValid[$idx] = $true
            _SortedInsert -List $sorted -Value $dv
            $validCount++
        } else {
            $bufValid[$idx] = $false
        }

        if ($validCount -ge $MinPeriods -and $validCount -gt 0) {
            $out[$i] = _GetPercentileFromSorted -Sorted $sorted -Percentile $Percentile -Interpolation $Interpolation
        } else {
            $out[$i] = $null
        }
    }

    return $out
}