# src/CupHandleDetector/Public/Resample-Ohlcv.ps1
# Regular-interval OHLCV resampler with bucket aggregation rules.
# Contract: input bars are PSCustomObjects with properties:
# Timestamp (datetime), Open/High/Low/Close/Volume (numeric).
# Output: resampled bars (same shape) sorted by Timestamp, no duplicates.

Set-StrictMode -Version Latest

function Resample-Ohlcv {
  [CmdletBinding()]
  param(
    # Source OHLCV bars (pipeline). Must already be normalized to UTC by upstream converter,
    # but we defensively normalize to UTC again.
    [Parameter(Mandatory, ValueFromPipeline)]
    [object] $InputObject,

    # Target timeframe string: 1m, 5m, 15m, 30m, 1h, 4h, 1d, 1w
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Timeframe,

    # Optional: drop bars with Timestamp > AsOf (UTC-normalized)
    [datetime] $AsOf,

    # Default: skip empty buckets. If set, emits buckets even if empty (OHLCV nulls),
    # primarily for diagnostics/tests; downstream typically should keep default.
    [switch] $IncludeEmptyBuckets,

    # Optional quality/metrics object (passed by ref); if omitted, metrics are not returned.
    [ref] $Quality
  )

  begin {
    $rows = New-Object System.Collections.Generic.List[object]

    function _Parse-Timeframe {
      param([string] $Tf)

      $m = [regex]::Match($Tf.Trim(), '^(?<n>\d+)(?<u>[mhdw])$')
      if (-not $m.Success) {
        throw "Unsupported timeframe '$Tf'. Expected like 1m,5m,15m,30m,1h,4h,1d,1w."
      }

      $n = [int]$m.Groups['n'].Value
      $u = $m.Groups['u'].Value

      if ($n -le 0) { throw "Timeframe must be positive: '$Tf'." }

      $isFixed = $false
      $span = [TimeSpan]::Zero

      switch ($u) {
        'm' { $isFixed = $true;  $span = [TimeSpan]::FromMinutes($n) }
        'h' { $isFixed = $true;  $span = [TimeSpan]::FromHours($n) }
        'd' {
          if ($n -ne 1) { throw "Only 1d is supported for daily buckets. Got '$Tf'." }
          $isFixed = $false
        }
        'w' {
          if ($n -ne 1) { throw "Only 1w is supported for weekly buckets. Got '$Tf'." }
          $isFixed = $false
        }
        default { throw "Unsupported timeframe unit '$u' in '$Tf'." }
      }

      [pscustomobject]@{
        N       = $n
        Unit    = $u
        IsFixed = $isFixed
        Span    = $span
      }
    }

    function _To-Utc {
      param([datetime] $Dt)
      if ($Dt.Kind -eq [DateTimeKind]::Utc) { return $Dt }
      if ($Dt.Kind -eq [DateTimeKind]::Unspecified) {
        # Per spec: treat Unspecified as UTC (do not assume local)
        return [datetime]::SpecifyKind($Dt, [DateTimeKind]::Utc)
      }
      return $Dt.ToUniversalTime()
    }

    function _Get-BucketStart {
      param(
        [datetime] $TimestampUtc,
        [pscustomobject] $TfInfo
      )

      $t = _To-Utc $TimestampUtc

      if ($TfInfo.IsFixed) {
        $ticks = $TfInfo.Span.Ticks
        if ($ticks -le 0) { throw "Invalid bucket ticks for timeframe '$Timeframe'." }
        $floorTicks = [int64](($t.Ticks / $ticks) * $ticks)
        return [datetime]::new($floorTicks, [DateTimeKind]::Utc)
      }

      switch ($TfInfo.Unit) {
        'd' {
          return [datetime]::new($t.Year, $t.Month, $t.Day, 0, 0, 0, [DateTimeKind]::Utc)
        }
        'w' {
          # Monday 00:00:00Z week start
          $dayStart = [datetime]::new($t.Year, $t.Month, $t.Day, 0, 0, 0, [DateTimeKind]::Utc)
          $dow = [int]$dayStart.DayOfWeek  # Sunday=0 ... Saturday=6
          $delta = ($dow - 1 + 7) % 7      # Monday=1
          return $dayStart.AddDays(-1 * $delta)
        }
        default {
          throw "Unsupported non-fixed timeframe unit '$($TfInfo.Unit)'."
        }
      }
    }

    function _New-AggState {
      param(
        [datetime] $BucketStart,
        [object] $FirstBar
      )

      [pscustomobject]@{
        BucketStart = $BucketStart

        # Track first/last timestamps to define open/close selection.
        FirstTs = _To-Utc ([datetime]$FirstBar.Timestamp)
        LastTs  = _To-Utc ([datetime]$FirstBar.Timestamp)

        Open   = [double]$FirstBar.Open
        High   = [double]$FirstBar.High
        Low    = [double]$FirstBar.Low
        Close  = [double]$FirstBar.Close
        Volume = [double]$FirstBar.Volume
      }
    }

    function _Update-AggState {
      param(
        [pscustomobject] $State,
        [object] $Bar
      )

      $ts = _To-Utc ([datetime]$Bar.Timestamp)

      # Open from first bar in time (stable because we process sorted input)
      # but still guard if out-of-order within bucket.
      if ($ts -lt $State.FirstTs) {
        $State.FirstTs = $ts
        $State.Open = [double]$Bar.Open
      }

      # Close from last bar in time
      if ($ts -ge $State.LastTs) {
        $State.LastTs = $ts
        $State.Close = [double]$Bar.Close
      }

      $h = [double]$Bar.High
      $l = [double]$Bar.Low
      if ($h -gt $State.High) { $State.High = $h }
      if ($l -lt $State.Low)  { $State.Low  = $l }

      $State.Volume += [double]$Bar.Volume
    }

    function _Emit-Bar {
      param([pscustomobject] $State)

      [pscustomobject]@{
        Timestamp = $State.BucketStart
        Open      = [double]$State.Open
        High      = [double]$State.High
        Low       = [double]$State.Low
        Close     = [double]$State.Close
        Volume    = [double]$State.Volume
      }
    }

    $tfInfo = _Parse-Timeframe $Timeframe

    $asOfUtc = $null
    if ($PSBoundParameters.ContainsKey('AsOf')) { $asOfUtc = _To-Utc $AsOf }

    $metrics = [pscustomobject]@{
      InputCount          = 0
      OutputCount         = 0
      EmptyBucketsSkipped = 0
      GapsDetected        = 0
      Timeframe           = $Timeframe
    }
  }

  process {
    if ($null -eq $InputObject) { return }
    $metrics.InputCount++

    # Defensive shape check (avoid hard failure on stray objects in pipeline)
    if (-not ($InputObject.PSObject.Properties.Name -contains 'Timestamp')) { return }
    if ($asOfUtc) {
      $ts = _To-Utc ([datetime]$InputObject.Timestamp)
      if ($ts -gt $asOfUtc) { return }
    }

    $rows.Add($InputObject)
  }

  end {
    if ($Quality) { $Quality.Value = $metrics }

    if ($rows.Count -eq 0) { return }

    # Sort ascending by timestamp (stable enough for our purposes)
    $sorted = $rows.ToArray() | Sort-Object -Property @{ Expression = { _To-Utc ([datetime]$_.Timestamp) } }, @{ Expression = { 0 } }

    $out = New-Object System.Collections.Generic.List[object]

    $current = $null
    $currentBucket = $null

    # For gap detection: track last emitted bucket start and expected next.
    $lastBucketStart = $null

    foreach ($bar in $sorted) {
      $tsUtc = _To-Utc ([datetime]$bar.Timestamp)
      $bucketStart = _Get-BucketStart -TimestampUtc $tsUtc -TfInfo $tfInfo

      if ($null -eq $current) {
        # Optional gap accounting does not start until we have a first bucket
        $current = _New-AggState -BucketStart $bucketStart -FirstBar $bar
        $currentBucket = $bucketStart
        continue
      }

      if ($bucketStart -eq $currentBucket) {
        _Update-AggState -State $current -Bar $bar
        continue
      }

      # Before moving to new bucket, emit current aggregated bar.
      $emitted = _Emit-Bar -State $current
      $out.Add($emitted)

      # Gap detection / empty buckets
      if ($tfInfo.IsFixed) {
        $expected = $currentBucket.Add($tfInfo.Span)
        if ($bucketStart -gt $expected) {
          $gapBuckets = [math]::Floor((($bucketStart.Ticks - $expected.Ticks) / $tfInfo.Span.Ticks))
          if ($gapBuckets -gt 0) {
            $metrics.GapsDetected += 1
            if (-not $IncludeEmptyBuckets) {
              $metrics.EmptyBucketsSkipped += $gapBuckets
            } else {
              for ($i = 0; $i -lt $gapBuckets; $i++) {
                $b = $expected.AddTicks($tfInfo.Span.Ticks * $i)
                $out.Add([pscustomobject]@{
                  Timestamp = $b
                  Open      = $null
                  High      = $null
                  Low       = $null
                  Close     = $null
                  Volume    = $null
                })
              }
            }
          }
        }
      } elseif ($tfInfo.Unit -eq 'd') {
        $expected = $currentBucket.AddDays(1)
        if ($bucketStart -gt $expected) {
          $gapDays = [int](($bucketStart - $expected).TotalDays)
          if ($gapDays -gt 0) {
            $metrics.GapsDetected += 1
            if (-not $IncludeEmptyBuckets) {
              $metrics.EmptyBucketsSkipped += $gapDays
            } else {
              for ($i = 0; $i -lt $gapDays; $i++) {
                $b = $expected.AddDays($i)
                $out.Add([pscustomobject]@{
                  Timestamp = $b
                  Open      = $null
                  High      = $null
                  Low       = $null
                  Close     = $null
                  Volume    = $null
                })
              }
            }
          }
        }
      } elseif ($tfInfo.Unit -eq 'w') {
        $expected = $currentBucket.AddDays(7)
        if ($bucketStart -gt $expected) {
          $gapWeeks = [int](($bucketStart - $expected).TotalDays / 7)
          if ($gapWeeks -gt 0) {
            $metrics.GapsDetected += 1
            if (-not $IncludeEmptyBuckets) {
              $metrics.EmptyBucketsSkipped += $gapWeeks
            } else {
              for ($i = 0; $i -lt $gapWeeks; $i++) {
                $b = $expected.AddDays(7 * $i)
                $out.Add([pscustomobject]@{
                  Timestamp = $b
                  Open      = $null
                  High      = $null
                  Low       = $null
                  Close     = $null
                  Volume    = $null
                })
              }
            }
          }
        }
      }

      # Start new bucket aggregation
      $current = _New-AggState -BucketStart $bucketStart -FirstBar $bar
      $currentBucket = $bucketStart
      $lastBucketStart = $bucketStart
    }

    # Emit final bucket
    if ($null -ne $current) {
      $out.Add((_Emit-Bar -State $current))
    }

    # Ensure output is sorted and unique by Timestamp (defensive)
    $final = $out.ToArray() |
      Sort-Object -Property Timestamp |
      Group-Object -Property Timestamp | ForEach-Object {
        # If any duplicates occur due to diagnostics fill + real bar collision (should not),
        # prefer the non-null bar; otherwise take first.
        $g = $_.Group
        $nonNull = $g | Where-Object { $null -ne $_.Open -and $null -ne $_.Close } | Select-Object -First 1
        if ($nonNull) { $nonNull } else { $g | Select-Object -First 1 }
      }

    $metrics.OutputCount = @($final).Count
    if ($Quality) { $Quality.Value = $metrics }

    $final
  }
}
