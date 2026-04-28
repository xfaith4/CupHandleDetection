# src/CupHandleDetector/Public/ConvertTo-OhlcvSeries.ps1
# Converts arbitrary CSV/imported rows into canonical OHLCV bar objects.

Set-StrictMode -Version Latest

function _GetPropertyValueOhlcv {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string[]] $Names
    )

    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($null -ne $prop) { return $prop.Value }
    }

    return $null
}

function _ToDoubleOhlcv {
    param([object] $Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        $d = [double]$Value
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
        return $d
    } catch {
        return $null
    }
}

function ConvertTo-OhlcvSeries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $InputObject,

        [Parameter()]
        [ValidateSet('1d','1w')]
        [string] $Timeframe = '1d',

        [Parameter()]
        [ValidateSet('Last','First','Error')]
        [string] $DuplicatePolicy = 'Last',

        [Parameter()]
        [switch] $Strict
    )

    begin {
        $bars = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($row in $InputObject) {
            $timestampRaw = _GetPropertyValueOhlcv -Object $row -Names @('Timestamp','Date','Time','Datetime')
            $open = _ToDoubleOhlcv (_GetPropertyValueOhlcv -Object $row -Names @('Open','O'))
            $high = _ToDoubleOhlcv (_GetPropertyValueOhlcv -Object $row -Names @('High','H'))
            $low = _ToDoubleOhlcv (_GetPropertyValueOhlcv -Object $row -Names @('Low','L'))
            $close = _ToDoubleOhlcv (_GetPropertyValueOhlcv -Object $row -Names @('Close','C','AdjClose','Adj_Close','AdjustedClose'))
            $volume = _ToDoubleOhlcv (_GetPropertyValueOhlcv -Object $row -Names @('Volume','Vol','V'))

            try {
                if ($null -eq $timestampRaw) { throw 'Missing timestamp.' }
                $timestamp = [datetime]::Parse([string]$timestampRaw, [System.Globalization.CultureInfo]::InvariantCulture)
                if ($timestamp.Kind -eq [DateTimeKind]::Unspecified) {
                    $timestamp = [datetime]::SpecifyKind($timestamp, [DateTimeKind]::Utc)
                } else {
                    $timestamp = $timestamp.ToUniversalTime()
                }

                if ($null -eq $open -or $null -eq $high -or $null -eq $low -or $null -eq $close -or $null -eq $volume) {
                    throw 'Missing or invalid OHLCV value.'
                }
                if ($high -lt $low) { throw 'High cannot be less than Low.' }

                $bars.Add([pscustomobject]@{
                    Timestamp = $timestamp
                    Time      = $timestamp
                    Open      = $open
                    High      = $high
                    Low       = $low
                    Close     = $close
                    Volume    = $volume
                })
            } catch {
                if ($Strict) { throw }
            }
        }
    }

    end {
        $grouped = $bars.ToArray() |
            Sort-Object Timestamp |
            Group-Object { $_.Timestamp.ToUniversalTime().Ticks }

        $deduped = foreach ($group in $grouped) {
            if ($group.Count -gt 1 -and $DuplicatePolicy -eq 'Error') {
                throw "Duplicate timestamp found: $($group.Group[0].Timestamp)"
            }
            if ($DuplicatePolicy -eq 'First') { $group.Group[0] } else { $group.Group[-1] }
        }

        if ($Timeframe -eq '1w') {
            return ($deduped | Resample-Ohlcv -Timeframe '1w')
        }

        return @($deduped)
    }
}
