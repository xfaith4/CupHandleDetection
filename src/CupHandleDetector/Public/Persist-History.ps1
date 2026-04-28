# src/CupHandleDetector/Public/Persist-History.ps1
<#
.SYNOPSIS
Append-only persistence for CupHandleDetector events/history in CSV and JSON formats.

.DESCRIPTION
Persists events in an append-only manner. Supported formats:
- CSV (single file with header written once)
- JSONL (newline-delimited JSON; one object per line)

This function is intended for observability/event history (stage transitions, alerts, evidence).
It never truncates existing files.

Concurrency note:
- Uses an exclusive file open during each append to reduce interleaving when multiple writers exist.

.PARAMETER InputObject
Event object(s) to persist. Accepts pipeline input.

.PARAMETER Path
Output file path. If omitted, derived from -OutDir/-Symbol/-Kind/-Format.

.PARAMETER OutDir
Base output directory used when -Path is not provided.

.PARAMETER Symbol
Symbol used for derived path when -Path is not provided.

.PARAMETER Kind
Logical stream name (e.g. "events", "history", "alerts"). Used for derived path.

.PARAMETER Format
csv or json. json uses JSONL (newline delimited).

.PARAMETER DeduplicateByEventId
If set, attempts best-effort deduplication by EventId by scanning the tail of the file.
This is bounded and intended to avoid duplicate writes in tight watch loops.

.PARAMETER DedupTailLines
How many trailing lines to scan for deduplication (JSONL) or trailing records (CSV best-effort).
Default 500.

.EXAMPLE
$evt | Persist-CHDHistory -OutDir .\data\output -Symbol AAPL -Kind events -Format csv

.EXAMPLE
Persist-CHDHistory -InputObject $events -Path .\data\output\AAPL.events.jsonl -Format json
#>

Set-StrictMode -Version Latest

function Persist-CHDHistory {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [object] $InputObject,

    [Parameter()]
    [string] $Path,

    [Parameter()]
    [string] $OutDir = ".\data\output",

    [Parameter()]
    [string] $Symbol,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $Kind = "events",

    [Parameter()]
    [ValidateSet("csv","json")]
    [string] $Format = "csv",

    [Parameter()]
    [switch] $DeduplicateByEventId,

    [Parameter()]
    [ValidateRange(10, 20000)]
    [int] $DedupTailLines = 500
  )

  begin {
    # Buffer so we can do one append batch per invocation (reduces opens/locks)
    $buffer = New-Object System.Collections.Generic.List[object]

    function _Ensure-Directory([string]$filePath) {
      $dir = Split-Path -Parent -Path $filePath
      if ([string]::IsNullOrWhiteSpace($dir)) { return }
      if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
      }
    }

    function _Derive-Path {
      param([string]$OutDir, [string]$Symbol, [string]$Kind, [string]$Format)
      if ([string]::IsNullOrWhiteSpace($Symbol)) { $Symbol = "UNKNOWN" }
      $ext = if ($Format -eq "csv") { "csv" } else { "jsonl" }
      return (Join-Path -Path $OutDir -ChildPath ("{0}.{1}.{2}" -f $Symbol, $Kind, $ext))
    }

    function _To-EventRecord {
      param([object]$e)

      # Project to a stable, append-friendly record.
      # We keep common fields at top-level; anything extra goes into PayloadJson.
      $props = @{}
      if ($e -is [hashtable]) {
        $props = $e
      } else {
        foreach ($p in ($e | Get-Member -MemberType NoteProperty,Property | Select-Object -ExpandProperty Name)) {
          try { $props[$p] = $e.$p } catch {}
        }
      }

      $timestamp =
        if ($props.ContainsKey("Timestamp") -and $props["Timestamp"]) { $props["Timestamp"] }
        elseif ($props.ContainsKey("Time") -and $props["Time"]) { $props["Time"] }
        elseif ($props.ContainsKey("OccurredAt") -and $props["OccurredAt"]) { $props["OccurredAt"] }
        else { (Get-Date).ToUniversalTime() }

      try {
        $ts = [DateTimeOffset]::Parse($timestamp.ToString()).ToUniversalTime().ToString("o")
      } catch {
        $ts = (Get-Date).ToUniversalTime().ToString("o")
      }

      $eventId =
        if ($props.ContainsKey("EventId") -and $props["EventId"]) { [string]$props["EventId"] }
        elseif ($props.ContainsKey("Id") -and $props["Id"]) { [string]$props["Id"] }
        else { "" }

      $symbol =
        if ($props.ContainsKey("Symbol") -and $props["Symbol"]) { [string]$props["Symbol"] }
        else { $Symbol }

      $type =
        if ($props.ContainsKey("Type") -and $props["Type"]) { [string]$props["Type"] }
        elseif ($props.ContainsKey("EventType") -and $props["EventType"]) { [string]$props["EventType"] }
        else { "" }

      $severity =
        if ($props.ContainsKey("Severity") -and $props["Severity"]) { [string]$props["Severity"] }
        else { "" }

      $stage =
        if ($props.ContainsKey("Stage") -and $props["Stage"]) { [string]$props["Stage"] }
        else { "" }

      $candidateId =
        if ($props.ContainsKey("CandidateId") -and $props["CandidateId"]) { [string]$props["CandidateId"] }
        else { "" }

      $reason =
        if ($props.ContainsKey("Reason") -and $props["Reason"]) { [string]$props["Reason"] }
        elseif ($props.ContainsKey("ReasonCode") -and $props["ReasonCode"]) { [string]$props["ReasonCode"] }
        else { "" }

      $message =
        if ($props.ContainsKey("Message") -and $props["Message"]) { [string]$props["Message"] }
        else { "" }

      $confidence =
        if ($props.ContainsKey("Confidence") -and $props["Confidence"] -ne $null) { $props["Confidence"] }
        elseif ($props.ContainsKey("Score") -and $props["Score"] -ne $null) { $props["Score"] }
        else { $null }

      # Build payload: include all original props except the canonical ones we’ve promoted.
      $canonical = @("Timestamp","Time","OccurredAt","EventId","Id","Symbol","Type","EventType","Severity","Stage","CandidateId","Reason","ReasonCode","Message","Confidence","Score")
      $payload = [ordered]@{}
      foreach ($k in $props.Keys) {
        if ($canonical -contains $k) { continue }
        $payload[$k] = $props[$k]
      }
      $payloadJson = if ($payload.Count -gt 0) { ($payload | ConvertTo-Json -Depth 12 -Compress) } else { "" }

      [pscustomobject]@{
        Timestamp   = $ts
        EventId     = $eventId
        Symbol      = $symbol
        Type        = $type
        Severity    = $severity
        Stage       = $stage
        CandidateId = $candidateId
        Reason      = $reason
        Message     = $message
        Confidence  = $confidence
        PayloadJson = $payloadJson
      }
    }

    function _Read-TailLines {
      param(
        [Parameter(Mandatory)][string]$filePath,
        [Parameter(Mandatory)][int]$lineCount
      )

      if (-not (Test-Path -LiteralPath $filePath)) { return @() }

      # Efficient tail read without loading entire file (best-effort).
      # For simplicity and portability, fall back to Get-Content -Tail.
      try {
        return Get-Content -LiteralPath $filePath -Tail $lineCount -ErrorAction Stop
      } catch {
        return @()
      }
    }

    function _Append-TextLinesExclusive {
      param(
        [Parameter(Mandatory)][string]$filePath,
        [Parameter(Mandatory)][string[]]$lines,
        [switch] $AddNewLineAfter
      )

      _Ensure-Directory $filePath

      $fs = $null
      $sw = $null
      try {
        $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
        $sw = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
        foreach ($l in $lines) { $sw.WriteLine($l) }
        if ($AddNewLineAfter) { $sw.WriteLine() }
        $sw.Flush()
      } finally {
        if ($sw) { $sw.Dispose() }
        if ($fs) { $fs.Dispose() }
      }
    }
  }

  process {
    if ($null -ne $InputObject) { [void]$buffer.Add($InputObject) }
  }

  end {
    if ($buffer.Count -eq 0) { return }

    if ([string]::IsNullOrWhiteSpace($Path)) {
      $Path = _Derive-Path -OutDir $OutDir -Symbol $Symbol -Kind $Kind -Format $Format
    }

    # Normalize to event records first (stable schema)
    $records = foreach ($e in $buffer) { _To-EventRecord $e }

    if ($DeduplicateByEventId) {
      $existingIds = New-Object 'System.Collections.Generic.HashSet[string]'
      if (Test-Path -LiteralPath $Path) {
        if ($Format -eq "json") {
          $tail = _Read-TailLines -filePath $Path -lineCount $DedupTailLines
          foreach ($line in $tail) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
              $obj = $line | ConvertFrom-Json -ErrorAction Stop
              if ($obj.EventId) { [void]$existingIds.Add([string]$obj.EventId) }
            } catch { }
          }
        } else {
          # CSV: best-effort parse tail by Import-Csv (requires header, so read more)
          try {
            $tail = _Read-TailLines -filePath $Path -lineCount ($DedupTailLines + 5)
            if ($tail.Count -gt 1) {
              $csvText = ($tail -join "`n")
              $tmp = $csvText | ConvertFrom-Csv
              foreach ($row in $tmp) {
                if ($row.EventId) { [void]$existingIds.Add([string]$row.EventId) }
              }
            }
          } catch { }
        }
      }

      $records = foreach ($r in $records) {
        if ([string]::IsNullOrWhiteSpace($r.EventId)) { $r; continue }
        if (-not $existingIds.Contains($r.EventId)) { $r }
      }
      if (-not $records -or $records.Count -eq 0) { return }
    }

    if ($Format -eq "json") {
      # JSONL append
      $lines = foreach ($r in $records) {
        $r | ConvertTo-Json -Depth 12 -Compress
      }
      _Append-TextLinesExclusive -filePath $Path -lines $lines
      return
    }

    # CSV append
    _Ensure-Directory $Path

    $header = "Timestamp,EventId,Symbol,Type,Severity,Stage,CandidateId,Reason,Message,Confidence,PayloadJson"

    $needHeader = -not (Test-Path -LiteralPath $Path) -or ((Get-Item -LiteralPath $Path).Length -eq 0)
    if ($needHeader) {
      _Append-TextLinesExclusive -filePath $Path -lines @($header)
    }

    # ConvertTo-Csv includes header; we want rows only.
    $csvLines = $records | ConvertTo-Csv -NoTypeInformation
    if ($csvLines.Count -ge 2) {
      $dataLines = $csvLines[1..($csvLines.Count-1)]
    } else {
      $dataLines = @()
    }

    if ($dataLines.Count -gt 0) {
      _Append-TextLinesExclusive -filePath $Path -lines $dataLines
    }
  }
}
