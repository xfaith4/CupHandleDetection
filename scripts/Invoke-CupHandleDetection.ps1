# scripts/Invoke-CupHandleDetection.ps1
# Runnable CLI script: ingest CSV OHLCV, run CupHandleDetector pipeline, write outputs.
#
# Examples:
#   pwsh ./scripts/Invoke-CupHandleDetection.ps1 -InputCsv data/AAPL.csv -Symbol AAPL
#   pwsh ./scripts/Invoke-CupHandleDetection.ps1 -InputCsv data/AAPL.csv -Symbol AAPL -Resample 1w
#   pwsh ./scripts/Invoke-CupHandleDetection.ps1 -InputCsv data/AAPL.csv -Symbol AAPL -ConfigFile config/defaults.json -OutDir out
#   pwsh ./scripts/Invoke-CupHandleDetection.ps1 -InputCsv data/AAPL.csv -Symbol AAPL -ConfigOverrideJson '{"detection":{"breakout":{"enabled":false}}}'
#
# CSV requirements (flexible headers; case-insensitive):
#   Timestamp/Date/Time, Open, High, Low, Close, Volume
# Timestamp can be ISO-8601, or anything [datetime]::Parse can read.
#
# Outputs (in -OutDir; filenames can be controlled via config/defaults.json persistence.*):
#   - bars.normalized.csv
#   - stage_history.csv (if enabled and produced)
#   - events.jsonl (alerts/events)
#   - detections.json (scan/analyze results)
#
# Exit codes:
#   0 success
#   2 bad input/config
#   3 runtime failure

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $InputCsv,

    [Parameter()]
    [string] $Symbol,

    # Convenience: resample to a timeframe like 1d,1w,4h,15m.
    # If omitted, uses config data.timeframe.resample.* when enabled.
    [Parameter()]
    [ValidatePattern('^\d+[mhdw]$')]
    [string] $Resample,

    # Optional: only keep bars with Timestamp <= AsOf (UTC assumed if unspecified)
    [Parameter()]
    [datetime] $AsOf,

    [Parameter()]
    [string] $ConfigFile = 'config/defaults.json',

    [Parameter()]
    [string] $UserConfigFile,

    # JSON string merged last into config (deep merge).
    [Parameter()]
    [string] $ConfigOverrideJson,

    [Parameter()]
    [string] $OutDir,

    [Parameter()]
    [ValidateSet('Json','Csv')]
    [string] $EventLogFormat = 'Json',

    [Parameter()]
    [switch] $Quiet,

    [Parameter()]
    [switch] $NoColor
)

function _Write-Log {
    param(
        [string] $Level,
        [string] $Message
    )
    if ($Quiet) { return }
    $ts = [DateTimeOffset]::UtcNow.ToString('u')
    Write-Host "[$ts][$Level] $Message"
}

function _Read-JsonFileOrNull {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -AsHashtable)
}

function _DeepMerge {
    param(
        [hashtable] $Base,
        [hashtable] $Override
    )
    if ($null -eq $Base) { $Base = @{} }
    if ($null -eq $Override) { return $Base }

    foreach ($k in $Override.Keys) {
        $ov = $Override[$k]
        if ($Base.ContainsKey($k)) {
            $bv = $Base[$k]
            if ($bv -is [hashtable] -and $ov -is [hashtable]) {
                $Base[$k] = _DeepMerge -Base $bv -Override $ov
            } else {
                $Base[$k] = $ov
            }
        } else {
            $Base[$k] = $ov
        }
    }
    return $Base
}

function _TryGet {
    param([hashtable]$Table, [string]$Path, $Fallback)
    $cur = $Table
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $cur) { return $Fallback }
        if ($cur -isnot [System.Collections.IDictionary]) { return $Fallback }
        if (-not $cur.Contains($p)) { return $Fallback }
        $cur = $cur[$p]
    }
    if ($null -eq $cur) { return $Fallback }
    return $cur
}

function _ToUtc {
    param([datetime] $Dt)
    if ($Dt.Kind -eq [DateTimeKind]::Utc) { return $Dt }
    if ($Dt.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Dt, [DateTimeKind]::Utc) }
    return $Dt.ToUniversalTime()
}

function _Coerce-DoubleOrNull {
    param([object] $x)
    if ($null -eq $x) { return $null }
    try {
        $d = [double]$x
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
        return $d
    } catch { return $null }
}

function _Resolve-Column {
    param(
        [string[]] $Headers,
        [string[]] $Candidates
    )
    foreach ($c in $Candidates) {
        $hit = $Headers | Where-Object { $_.Trim().ToLowerInvariant() -eq $c.Trim().ToLowerInvariant() } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function _Import-BarsFromCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [datetime] $AsOfUtc,
        [hashtable] $Config
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input CSV not found: $Path"
    }

    $invalidPolicy = [string](_TryGet $Config 'data.nan_policy.on_invalid_ohlcv_row' 'drop')
    $dropLastIncomplete = [bool](_TryGet $Config 'data.requirements.drop_last_incomplete_bar' $true)

    $rows = Import-Csv -LiteralPath $Path
    if ($null -eq $rows -or $rows.Count -eq 0) {
        return @()
    }

    $headers = @()
    foreach ($p in $rows[0].PSObject.Properties) { $headers += $p.Name }

    $colTime  = _Resolve-Column $headers @('timestamp','time','date','datetime')
    $colOpen  = _Resolve-Column $headers @('open','o')
    $colHigh  = _Resolve-Column $headers @('high','h')
    $colLow   = _Resolve-Column $headers @('low','l')
    $colClose = _Resolve-Column $headers @('close','c','adjclose','adj_close','adjustedclose')
    $colVol   = _Resolve-Column $headers @('volume','vol','v')

    if (-not $colTime -or -not $colOpen -or -not $colHigh -or -not $colLow -or -not $colClose -or -not $colVol) {
        throw ("CSV missing required columns. Found headers: {0}. Need at least timestamp/date/time + open/high/low/close/volume." -f ($headers -join ', '))
    }

    $bars = New-Object System.Collections.Generic.List[object]
    $dropped = 0
    $bad = 0

    foreach ($r in $rows) {
        try {
            $tsRaw = $r.$colTime
            if ([string]::IsNullOrWhiteSpace([string]$tsRaw)) { throw "Empty timestamp" }
            $ts = [datetime]::Parse([string]$tsRaw, [System.Globalization.CultureInfo]::InvariantCulture)
            $tsUtc = _ToUtc $ts
            if ($AsOfUtc -and $tsUtc -gt $AsOfUtc) { continue }

            $o = _Coerce-DoubleOrNull $r.$colOpen
            $h = _Coerce-DoubleOrNull $r.$colHigh
            $l = _Coerce-DoubleOrNull $r.$colLow
            $c = _Coerce-DoubleOrNull $r.$colClose
            $v = _Coerce-DoubleOrNull $r.$colVol

            if ($null -eq $o -or $null -eq $h -or $null -eq $l -or $null -eq $c -or $null -eq $v) {
                throw "Non-numeric OHLCV"
            }
            if ($h -lt $l) { throw "High < Low" }

            $bars.Add([pscustomobject]@{
                Time      = $tsUtc
                Timestamp = $tsUtc  # for Resample-Ohlcv compatibility
                Open      = $o
                High      = $h
                Low       = $l
                Close     = $c
                Volume    = $v
            })
        } catch {
            $bad++
            if ($invalidPolicy -eq 'throw') {
                throw "Invalid OHLCV row: $($_.Exception.Message). Raw=$($r | ConvertTo-Json -Compress)"
            } else {
                $dropped++
            }
        }
    }

    if ($bars.Count -eq 0) { return @() }

    # Sort and de-dup by timestamp
    $sorted = $bars.ToArray() | Sort-Object -Property Time
    $dedup = New-Object System.Collections.Generic.List[object]
    $last = $null
    foreach ($b in $sorted) {
        if ($null -ne $last -and $b.Time -eq $last.Time) { continue }
        $dedup.Add($b)
        $last = $b
    }

    # Drop last bar if "incomplete" (heuristic): last timestamp is in the future or equals today with not-yet-finished session.
    if ($dropLastIncomplete -and $dedup.Count -ge 2) {
        $lastBar = $dedup[$dedup.Count - 1]
        $nowUtc = [DateTime]::UtcNow
        if ($lastBar.Time -gt $nowUtc.AddMinutes(5)) {
            $dedup.RemoveAt($dedup.Count - 1)
        }
    }

    _Write-Log INFO "Imported $($dedup.Count) bars (dropped_invalid=$dropped, bad_rows=$bad) from CSV."
    return $dedup.ToArray()
}

function _Export-BarsCsv {
    param(
        [object[]] $Bars,
        [string] $Path
    )
    if ($null -eq $Bars -or $Bars.Count -eq 0) { return }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $Bars |
        Select-Object @{n='Timestamp';e={$_.Time.ToString('o')}}, Open, High, Low, Close, Volume |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

try {
    _Write-Log INFO "Starting CupHandleDetector CLI."

    # --- Load config ---
    $cfgA = _Read-JsonFileOrNull $ConfigFile
    if ($null -eq $cfgA) {
        throw "Config file not found or invalid JSON: $ConfigFile"
    }

    # defaults.json structure is { defaults: {...}, validation: {...} }
    $cfg = if ($cfgA.ContainsKey('defaults')) { $cfgA['defaults'] } else { $cfgA }

    $userCfg = _Read-JsonFileOrNull $UserConfigFile
    if ($userCfg) {
        $userCfgEffective = if ($userCfg.ContainsKey('defaults')) { $userCfg['defaults'] } else { $userCfg }
        $cfg = _DeepMerge -Base $cfg -Override $userCfgEffective
    }

    if (-not [string]::IsNullOrWhiteSpace($ConfigOverrideJson)) {
        $ov = ($ConfigOverrideJson | ConvertFrom-Json -AsHashtable)
        $cfg = _DeepMerge -Base $cfg -Override $ov
    }

    if (-not [string]::IsNullOrWhiteSpace($Symbol)) {
        if (-not $cfg.ContainsKey('data')) { $cfg['data'] = @{} }
        $cfg['data']['symbol'] = $Symbol
    } else {
        $Symbol = [string](_TryGet $cfg 'data.symbol' $null)
    }

    if ([string]::IsNullOrWhiteSpace($OutDir)) {
        $OutDir = [string](_TryGet $cfg 'persistence.output_dir' 'out')
    }

    $outDirFull = (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Path $OutDir -Force).FullName).Path

    $eventsFile = [string](_TryGet $cfg 'persistence.events.file_name' 'events.jsonl')
    $eventsEnabled = [bool](_TryGet $cfg 'persistence.events.enabled' $true)
    $eventsPath = Join-Path $outDirFull $eventsFile

    $stageHistEnabled = [bool](_TryGet $cfg 'persistence.stage_history.enabled' $true)
    $stageHistFile = [string](_TryGet $cfg 'persistence.stage_history.file_name' 'stage_history.csv')
    $stageHistPath = Join-Path $outDirFull $stageHistFile

    # --- Import module ---
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $modulePath = Join-Path $repoRoot 'src/CupHandleDetector/CupHandleDetector.psd1'
    if (-not (Test-Path -LiteralPath $modulePath)) {
        # fallback to psm1
        $modulePath = Join-Path $repoRoot 'src/CupHandleDetector/CupHandleDetector.psm1'
    }
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Cannot find module at src/CupHandleDetector. Expected psd1/psm1."
    }
    Import-Module -Name $modulePath -Force

    # --- Read bars ---
    $asOfUtc = $null
    if ($PSBoundParameters.ContainsKey('AsOf')) { $asOfUtc = _ToUtc $AsOf }

    $bars = _Import-BarsFromCsv -Path $InputCsv -AsOfUtc $asOfUtc -Config $cfg
    if ($bars.Count -eq 0) { throw "No bars after import/filtering." }

    # --- Optional resample ---
    $resampleEnabledCfg = [bool](_TryGet $cfg 'data.timeframe.resample.enabled' $false)
    $resampleTfCfg = [string](_TryGet $cfg 'data.timeframe.resample.target_minutes' 1440)
    # map target_minutes to timeframe token (simple mapping)
    $tfFromMinutes = @{
        1='1m'; 5='5m'; 15='15m'; 30='30m'; 60='1h'; 240='4h'; 1440='1d'
    }
    $tfCfgToken = if ($tfFromMinutes.ContainsKey([int]$resampleTfCfg)) { $tfFromMinutes[[int]$resampleTfCfg] } else { '1d' }

    $tf = $null
    if (-not [string]::IsNullOrWhiteSpace($Resample)) {
        $tf = $Resample
    } elseif ($resampleEnabledCfg) {
        $tf = $tfCfgToken
    }

    if ($tf) {
        _Write-Log INFO "Resampling to timeframe '$tf'..."
        $q = $null
        $resampled = @($bars | Resample-Ohlcv -Timeframe $tf -AsOf $asOfUtc -Quality ([ref]$q))
        # Normalize output back to expected "Time" property too
        $bars = $resampled | ForEach-Object {
            [pscustomobject]@{
                Time      = $_.Timestamp
                Timestamp = $_.Timestamp
                Open      = $_.Open
                High      = $_.High
                Low       = $_.Low
                Close     = $_.Close
                Volume    = $_.Volume
            }
        }
        _Write-Log INFO "Resample done. Bars=$($bars.Count). Quality=$($q | ConvertTo-Json -Compress)"
    } else {
        $tf = '1d'
    }

    # --- Persist normalized bars ---
    _Export-BarsCsv -Bars $bars -Path (Join-Path $outDirFull 'bars.normalized.csv')

    # --- Run indicators ---
    _Write-Log INFO "Computing indicators..."
    $ind = Compute-Indicators -Bars $bars -Config $cfg -Symbol $Symbol -AllowInsufficientHistory
    _Write-Log INFO "Indicators status: $($ind.Meta.Status)"

    $series = @()
    if ($ind -and $ind.PSObject.Properties.Name -contains 'Series') { $series = $ind.Series }

    # --- Scan/analyze pipeline (defensive: functions may vary by roadmap stage) ---
    $detections = [ordered]@{
        Meta = @{
            Symbol    = $Symbol
            Timeframe = $tf
            Bars      = $bars.Count
            GeneratedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Scan    = $null
        Analyze = $null
        Breakouts = $null
        Stages  = $null
    }

    if (Get-Command -Name Invoke-CHDScan -ErrorAction SilentlyContinue) {
        try {
            _Write-Log INFO "Running Invoke-CHDScan..."
            $detections.Scan = Invoke-CHDScan -Bars $bars -Indicators $ind -Config $cfg -Symbol $Symbol
        } catch {
            _Write-Log WARN "Invoke-CHDScan failed: $($_.Exception.Message)"
            $detections.Scan = @{ Error = "$($_.Exception.Message)" }
        }
    }

    if (Get-Command -Name Invoke-CHDAnalyze -ErrorAction SilentlyContinue) {
        try {
            _Write-Log INFO "Running Invoke-CHDAnalyze..."
            $detections.Analyze = Invoke-CHDAnalyze -Bars $bars -Indicators $ind -Config $cfg -Symbol $Symbol -ScanResult $detections.Scan
        } catch {
            _Write-Log WARN "Invoke-CHDAnalyze failed: $($_.Exception.Message)"
            $detections.Analyze = @{ Error = "$($_.Exception.Message)" }
        }
    }

    # Breakout confirmation may be produced by Analyze; if not, skip.

    # --- Stage labeling ---
    if (Get-Command -Name Detect-Stages -ErrorAction SilentlyContinue) {
        try {
            _Write-Log INFO "Detecting stages..."
            $st = Detect-Stages -Snapshots $series -Config $cfg -IncludeConfidence -EmitPatternOverlayEvents
            $detections.Stages = $st

            if ($stageHistEnabled -and $st -and $st.PSObject.Properties.Name -contains 'StageLabels') {
                $parent = Split-Path -Parent $stageHistPath
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

                $rows = for ($i=0; $i -lt $bars.Count; $i++) {
                    [pscustomobject]@{
                        Symbol    = $Symbol
                        Timeframe = $tf
                        BarIndex  = $i
                        Time      = $bars[$i].Time.ToString('o')
                        Close     = $bars[$i].Close
                        Stage     = $st.StageLabels[$i]
                    }
                }

                # Append-only behavior if configured
                $append = [bool](_TryGet $cfg 'persistence.stage_history.append_only' $true)
                if ($append -and (Test-Path -LiteralPath $stageHistPath)) {
                    $rows | Export-Csv -LiteralPath $stageHistPath -NoTypeInformation -Encoding UTF8 -Append
                } else {
                    $rows | Export-Csv -LiteralPath $stageHistPath -NoTypeInformation -Encoding UTF8
                }
            }

            # Emit transition events as alerts/events.jsonl
            if ($eventsEnabled -and $st -and $st.PSObject.Properties.Name -contains 'TransitionEvents') {
                foreach ($e in $st.TransitionEvents) {
                    $evt = [pscustomobject]@{
                        Symbol    = $Symbol
                        Timeframe = $tf
                        EventType = 'stage_change'
                        Severity  = 'INFO'
                        Stage     = $e.To
                        BarIndex  = $e.Index
                        Timestamp = $(if ($e.Time) { ([DateTimeOffset](_ToUtc ([datetime]$e.Time))).ToString('o') } else { [DateTimeOffset]::UtcNow.ToString('o') })
                        Message   = "Stage change: $($e.From) -> $($e.To) @ index=$($e.Index)"
                        Confidence = $(if ($e.PSObject.Properties.Name -contains 'Confidence') { $e.Confidence } else { $null })
                        ReasonCodes = $(if ($e.PSObject.Properties.Name -contains 'Reason') { @($e.Reason) } else { $null })
                        Evidence  = $e
                    }
                    Emit-CHDAlert -Event $evt -LogPath $eventsPath -LogFormat $EventLogFormat -NoConsole:$Quiet -NoColor:$NoColor | Out-Null
                }
            }
        } catch {
            _Write-Log WARN "Detect-Stages failed: $($_.Exception.Message)"
        }
    }

    # --- Persist detections summary ---
    $detectionsPath = Join-Path $outDirFull 'detections.json'
    ($detections | ConvertTo-Json -Depth 30) | Out-File -LiteralPath $detectionsPath -Encoding UTF8

    _Write-Log INFO "Wrote outputs to: $outDirFull"
    _Write-Log INFO "Done."
    exit 0
}
catch {
    Write-Error $_
    exit 3
}
