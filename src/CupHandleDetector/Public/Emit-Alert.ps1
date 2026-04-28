# src/CupHandleDetector/Public/Emit-Alert.ps1
# Console alert emitter + structured log writer for CupHandleDetector.
#
# Responsibilities:
#  1) Emit a readable alert line to console (optionally colored by severity)
#  2) Optionally append a structured event record to a log file (CSV or NDJSON)
#
# Expected/min recommended fields on the event object:
#   EventId, Timestamp, Symbol, Timeframe, EventType, Stage, Severity, Message,
#   CandidateId, BarIndex, Price, Volume, Confidence, ReasonCodes, Evidence
#
# The structured writer prefers to delegate to Persist-CHDEventHistory (if present),
# falling back to simple append-only CSV/NDJSON logic if not.

Set-StrictMode -Version Latest

function Emit-CHDAlert {
    [CmdletBinding()]
    param(
        # Event object(s). Accepts PSCustomObject/hashtable/etc.
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $Event,

        # If provided, appends the event to this log file (append-only).
        [Parameter()]
        [string] $LogPath,

        # Structured log format when -LogPath is used.
        [Parameter()]
        [ValidateSet('Json','Csv')]
        [string] $LogFormat = 'Json',

        # If set, also writes the raw structured JSON to console.
        [Parameter()]
        [switch] $IncludeRaw,

        # If set, does not write to console (still logs if -LogPath provided).
        [Parameter()]
        [switch] $NoConsole,

        # If set, will not use console colors.
        [Parameter()]
        [switch] $NoColor,

        # Optional console prefix tag.
        [Parameter()]
        [string] $Tag = 'CHD'
    )

    begin {
        function _Get-SeverityRank {
            param([string] $Severity)
            switch (($Severity ?? '').ToString().Trim().ToUpperInvariant()) {
                'CRITICAL' { 50 }
                'ERROR'    { 40 }
                'WARN'     { 30 }
                'WARNING'  { 30 }
                'INFO'     { 20 }
                'DEBUG'    { 10 }
                default    { 20 }
            }
        }

        function _Get-SeverityColor {
            param([string] $Severity)
            switch (($Severity ?? '').ToString().Trim().ToUpperInvariant()) {
                'CRITICAL' { 'Magenta' }
                'ERROR'    { 'Red' }
                'WARN'     { 'Yellow' }
                'WARNING'  { 'Yellow' }
                'INFO'     { 'Cyan' }
                'DEBUG'    { 'DarkGray' }
                default    { 'White' }
            }
        }

        function _Ensure-EventDefaults {
            param([pscustomobject] $Evt)

            # Timestamp
            if (-not ($Evt.PSObject.Properties.Name -contains 'Timestamp') -or -not $Evt.Timestamp) {
                $Evt | Add-Member -NotePropertyName Timestamp -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
            } else {
                try {
                    $dto = [DateTimeOffset]::Parse([string]$Evt.Timestamp, [System.Globalization.CultureInfo]::InvariantCulture)
                    $Evt.Timestamp = $dto.ToUniversalTime().ToString('o')
                } catch {
                    # keep original
                }
            }

            # Severity
            if (-not ($Evt.PSObject.Properties.Name -contains 'Severity') -or [string]::IsNullOrWhiteSpace([string]$Evt.Severity)) {
                $Evt | Add-Member -NotePropertyName Severity -NotePropertyValue 'INFO' -Force
            }

            # EventType
            if (-not ($Evt.PSObject.Properties.Name -contains 'EventType') -or [string]::IsNullOrWhiteSpace([string]$Evt.EventType)) {
                $Evt | Add-Member -NotePropertyName EventType -NotePropertyValue 'Alert' -Force
            }

            # Stage
            if (-not ($Evt.PSObject.Properties.Name -contains 'Stage')) {
                $Evt | Add-Member -NotePropertyName Stage -NotePropertyValue $null -Force
            }

            # EventId
            if (-not ($Evt.PSObject.Properties.Name -contains 'EventId') -or [string]::IsNullOrWhiteSpace([string]$Evt.EventId)) {
                $sym = if ($Evt.PSObject.Properties.Name -contains 'Symbol' -and $Evt.Symbol) { [string]$Evt.Symbol } else { 'NA' }
                $ts  = if ($Evt.PSObject.Properties.Name -contains 'Timestamp' -and $Evt.Timestamp) { [string]$Evt.Timestamp } else { [DateTimeOffset]::UtcNow.ToString('o') }
                $guid = [guid]::NewGuid().ToString('n')
                $Evt | Add-Member -NotePropertyName EventId -NotePropertyValue "$sym-$ts-$guid" -Force
            }

            # Message
            if (-not ($Evt.PSObject.Properties.Name -contains 'Message') -or [string]::IsNullOrWhiteSpace([string]$Evt.Message)) {
                # Compose a minimal message from available fields.
                $parts = @()
                if ($Evt.PSObject.Properties.Name -contains 'Symbol' -and $Evt.Symbol) { $parts += "Symbol=$($Evt.Symbol)" }
                if ($Evt.PSObject.Properties.Name -contains 'Timeframe' -and $Evt.Timeframe) { $parts += "TF=$($Evt.Timeframe)" }
                if ($Evt.PSObject.Properties.Name -contains 'Stage' -and $Evt.Stage) { $parts += "Stage=$($Evt.Stage)" }
                if ($Evt.PSObject.Properties.Name -contains 'CandidateId' -and $Evt.CandidateId) { $parts += "Candidate=$($Evt.CandidateId)" }
                $Evt | Add-Member -NotePropertyName Message -NotePropertyValue (($parts -join ' ') ?? '') -Force
            }

            return $Evt
        }

        function _Write-StructuredLog {
            param(
                [pscustomobject] $Evt,
                [string] $Path,
                [string] $Format
            )

            if ([string]::IsNullOrWhiteSpace($Path)) { return }

            # Ensure directory
            $parent = Split-Path -Parent $Path
            if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }

            # Prefer Persist-CHDEventHistory if available in session/module.
            $persistCmd = Get-Command -Name Persist-CHDEventHistory -ErrorAction SilentlyContinue
            if ($null -ne $persistCmd) {
                try {
                    Persist-CHDEventHistory -Events @($Evt) -Path $Path -Format $Format | Out-Null
                    return
                } catch {
                    # Fall through to local writer
                }
            }

            # Fallback writer (append-only)
            if ($Format -eq 'Json') {
                $line = $Evt | ConvertTo-Json -Depth 20 -Compress
                Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
                return
            }

            # CSV fallback: write header if missing/empty; serialize complex values as JSON
            $header = @(
                'EventId','Timestamp','Symbol','Timeframe','EventType','Stage','Severity','Message',
                'CandidateId','BarIndex','Price','Volume','Confidence','ReasonCodes','Evidence'
            )

            $needsHeader = $false
            if (-not (Test-Path -LiteralPath $Path)) {
                $needsHeader = $true
            } else {
                try {
                    if ((Get-Item -LiteralPath $Path).Length -eq 0) { $needsHeader = $true }
                } catch { }
            }

            if ($needsHeader) {
                ($header -join ',') | Out-File -LiteralPath $Path -Encoding UTF8 -Append:$false
            }

            $row = [ordered]@{}
            foreach ($h in $header) {
                if ($Evt.PSObject.Properties.Name -contains $h) {
                    $val = $Evt.$h
                    if ($null -eq $val) { $row[$h] = $null; continue }
                    if ($val -is [string] -or $val -is [ValueType]) { $row[$h] = $val; continue }
                    $row[$h] = ($val | ConvertTo-Json -Depth 20 -Compress)
                } else {
                    $row[$h] = $null
                }
            }

            # Export single row without header (header already present)
            [pscustomobject]$row | Export-Csv -LiteralPath $Path -NoTypeInformation -Append -Force
        }

        function _Format-ConsoleLine {
            param([pscustomobject] $Evt)

            $ts = [string]$Evt.Timestamp
            $sev = [string]$Evt.Severity
            $sym = if ($Evt.PSObject.Properties.Name -contains 'Symbol') { [string]$Evt.Symbol } else { '' }
            $tf  = if ($Evt.PSObject.Properties.Name -contains 'Timeframe') { [string]$Evt.Timeframe } else { '' }
            $etype = if ($Evt.PSObject.Properties.Name -contains 'EventType') { [string]$Evt.EventType } else { '' }
            $stage = if ($Evt.PSObject.Properties.Name -contains 'Stage' -and $Evt.Stage) { [string]$Evt.Stage } else { '' }
            $msg = [string]$Evt.Message

            $ctx = @()
            if ($sym) { $ctx += $sym }
            if ($tf)  { $ctx += $tf }
            if ($etype) { $ctx += $etype }
            if ($stage) { $ctx += "Stage=$stage" }

            $ctxText = if ($ctx.Count -gt 0) { " [" + ($ctx -join ' | ') + "]" } else { '' }
            return "$ts [$Tag] $sev$ctxText $msg"
        }
    }

    process {
        foreach ($e in $Event) {
            if ($null -eq $e) { continue }

            $evt = if ($e -is [pscustomobject]) { $e } else { [pscustomobject]$e }
            $evt = _Ensure-EventDefaults -Evt $evt

            # Console emit
            if (-not $NoConsole) {
                $line = _Format-ConsoleLine -Evt $evt
                $color = _Get-SeverityColor -Severity ([string]$evt.Severity)

                if ($NoColor) {
                    Write-Host $line
                } else {
                    Write-Host $line -ForegroundColor $color
                }

                if ($IncludeRaw) {
                    try {
                        $raw = $evt | ConvertTo-Json -Depth 20 -Compress
                        if ($NoColor) {
                            Write-Host $raw
                        } else {
                            Write-Host $raw -ForegroundColor DarkGray
                        }
                    } catch {
                        # ignore
                    }
                }
            }

            # Structured log append
            if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
                try {
                    _Write-StructuredLog -Evt $evt -Path $LogPath -Format $LogFormat
                } catch {
                    # Do not break detection pipeline if logging fails.
                    if (-not $NoConsole) {
                        $warn = "Logging failed for EventId=$($evt.EventId): $($_.Exception.Message)"
                        if ($NoColor) { Write-Host $warn }
                        else { Write-Host $warn -ForegroundColor Yellow }
                    }
                }
            }

            # Pass-through for pipelines
            $evt
        }
    }
}
