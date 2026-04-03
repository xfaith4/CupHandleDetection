# CupHandleDetector — Usage

This repository provides a PowerShell-based pipeline that ingests OHLCV bars from CSV, optionally resamples them, computes indicators, detects Cup-with-Handle patterns, emits alerts, and persists append-only event/history logs.

> Primary entrypoint: `scripts/Invoke-CupHandleDetection.ps1`  
> Default configuration: `config/defaults.json`

---

## Requirements

- PowerShell 7+ (`pwsh`)
- A CSV file containing OHLCV bars (daily recommended by default config)
- No external data provider is required (you bring the CSV)

---

## Quickstart

### 1) Run detection on a CSV (daily bars)

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL
```

### 2) Resample to weekly bars (1w)

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -Resample 1w
```

### 3) Override config in-line (deep-merged JSON)

Disable breakout confirmation logic:

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -ConfigOverrideJson '{"detection":{"breakout":{"enabled":false}}}'
```

### 4) Write outputs to a custom directory

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -OutDir ./out
```

---

## CLI: `Invoke-CupHandleDetection.ps1`

### Syntax

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 -InputCsv <path> [-Symbol <sym>] [-Resample <tf>]
  [-AsOf <datetime>] [-ConfigFile <path>] [-UserConfigFile <path>] [-ConfigOverrideJson <json>]
  [-OutDir <path>] [-EventLogFormat Json|Csv] [-Quiet] [-NoColor]
```

### Parameters

| Parameter | Type | Required | Default | Notes |
|---|---:|:---:|---|---|
| `-InputCsv` | string | Yes | — | Path to OHLCV CSV. |
| `-Symbol` | string | No | (from config or `UNKNOWN` downstream) | Used for labeling outputs/logging. Recommended to set. |
| `-Resample` | string | No | — | Timeframe like `1d`, `1w`, `4h`, `15m`. Pattern: `^\d+[mhdw]$`. |
| `-AsOf` | datetime | No | — | Only keep bars with `Timestamp <= AsOf`. Treated as UTC if unspecified. |
| `-ConfigFile` | string | No | `config/defaults.json` | Base config. |
| `-UserConfigFile` | string | No | — | Optional second config file merged on top of `-ConfigFile`. |
| `-ConfigOverrideJson` | string | No | — | JSON string deep-merged last (highest priority). |
| `-OutDir` | string | No | from config (`defaults.persistence.output_dir`) | Output directory root. |
| `-EventLogFormat` | enum | No | `Json` | `Json` writes JSONL; `Csv` writes CSV (when applicable). |
| `-Quiet` | switch | No | `false` | Reduce console logging. |
| `-NoColor` | switch | No | `false` | Disable console colors for alerts/logs. |

### Exit codes

- `0` success
- `2` bad input/config (missing columns, invalid config, etc.)
- `3` runtime failure (unexpected error during pipeline)

---

## Input CSV format

### Required columns (case-insensitive; flexible names)

The script searches headers for these fields:

- Timestamp: `Timestamp` / `Date` / `Time` / `Datetime`
- Open: `Open` / `O`
- High: `High` / `H`
- Low: `Low` / `L`
- Close: `Close` / `C` / `AdjClose` / `Adj_Close` / `AdjustedClose`
- Volume: `Volume` / `Vol` / `V`

Timestamps can be ISO-8601 or anything `.NET [datetime]::Parse()` can read.

### Minimal example

```csv
Timestamp,Open,High,Low,Close,Volume
2024-01-02,184.10,185.30,182.90,185.10,81234567
2024-01-03,185.10,186.40,184.20,184.90,70123456
```

### Row validation behavior

Controlled by config:

- `defaults.data.nan_policy.on_invalid_ohlcv_row`
  - `drop` (default): bad rows are skipped
  - `throw`: aborts on the first bad row

The importer also:
- Sorts by timestamp
- De-duplicates identical timestamps
- Optionally drops a likely “incomplete” last bar (`defaults.data.requirements.drop_last_incomplete_bar`)

---

## Configuration

### Config layering (priority order)

1. `-ConfigFile` (base; default `config/defaults.json`)
2. `-UserConfigFile` (optional; overrides base)
3. `-ConfigOverrideJson` (optional; overrides everything)

All merges are **deep merges** (nested objects merge recursively).

### Common overrides

#### Enable resample via config instead of CLI

```json
{
  "data": {
    "timeframe": {
      "resample": {
        "enabled": true,
        "target_minutes": 10080
      }
    }
  }
}
```

> `target_minutes=10080` is 1 week.

#### Require stricter breakout volume confirmation

```json
{
  "detection": {
    "breakout": {
      "volume": {
        "require_confirmation": true,
        "logic": "or",
        "z_threshold": 2.0,
        "pctl_threshold": 0.90,
        "use_zscore": true,
        "use_percentile": true,
        "use_surge_ratio": false
      }
    }
  }
}
```

#### Disable handle requirement (cup-only scans)

```json
{
  "detection": {
    "handle": { "enabled": false }
  }
}
```

#### Adjust allowed cup/handle durations (in weeks)

```json
{
  "detection": {
    "durations": {
      "cup": { "min_weeks": 10, "max_weeks": 52 },
      "handle": { "min_weeks": 1, "max_weeks": 4 }
    }
  }
}
```

---

## Outputs

Outputs are written under `-OutDir` or `defaults.persistence.output_dir` (default: `out`).

Typical outputs:

- `bars.normalized.csv` (normalized/cleaned bars used by the pipeline)
- `detections.json` (summary results from scan/analyze)
- `stage_history.csv` (append-only stage transitions; if enabled)
- `events.jsonl` (append-only alerts/events; if enabled)

> Exact filenames are controlled by `defaults.persistence.*` in `config/defaults.json`.

---

## Output schemas

### 1) Events log (JSONL): `events.jsonl`

**Format:** newline-delimited JSON (one event per line).  
**Append-only:** never truncates; safe for tailing.

Canonical fields (as persisted by the append-only writer):

```json
{
  "Timestamp": "2026-04-02T12:34:56.789Z",
  "EventId": "AAPL-2026-04-02T12:34:56.789Z-acde... (string)",
  "Symbol": "AAPL",
  "Type": "breakout_confirmed",
  "Severity": "INFO",
  "Stage": "BREAKOUT",
  "CandidateId": "cand-1",
  "Reason": "volume_confirmed",
  "Message": "Breakout confirmed above pivot",
  "Confidence": 0.82,
  "PayloadJson": "{\"BarIndex\":123,\"Pivot\":198.5,...}"
}
```

Notes:
- `PayloadJson` is a JSON-encoded string containing any non-canonical fields (evidence, bar metrics, etc.).
- Timestamps are normalized to UTC ISO-8601 (`.ToString("o")`).

#### If you choose CSV logging for events

If events are persisted as CSV, the record is projected into stable columns similar to the canonical fields above, with complex values encoded as JSON strings when needed.

---

### 2) Stage history (CSV): `stage_history.csv`

**Format:** CSV append-only history of stage transitions or per-bar stage states (implementation-dependent).  
You can rely on these *typical* columns existing when stage history is enabled:

- `Timestamp` (UTC)
- `Symbol`
- `Stage`
- `CandidateId`
- `Confidence` (0..1 when available)
- Additional columns may be present depending on pipeline version (evidence, bar index, etc.)

---

### 3) Detections summary (JSON): `detections.json`

A JSON document containing scan/analyze outputs. The exact shape may evolve, but typically includes:

- `Symbol`
- `Timeframe` / resample info
- `AsOf` (if used)
- `Candidates` (0..N up to `defaults.detection.scan.max_candidates`)
- Per-candidate:
  - key timestamps/indices (cup start/bottom/right rim/handle)
  - pivot level
  - stage / status (watch/alert/signal/buy/etc.)
  - confidence / component scores
  - evidence / reason codes

Example (illustrative):

```json
{
  "Symbol": "AAPL",
  "AsOf": "2026-04-02T00:00:00Z",
  "Candidates": [
    {
      "CandidateId": "cand-1",
      "Stage": "BREAKOUT",
      "Pivot": 198.5,
      "Confidence": 0.82,
      "Scores": {
        "price": 0.76,
        "volume": 0.88,
        "duration": 0.70,
        "geometry": 0.80
      },
      "KeyTimes": {
        "CupStart": "2025-08-01T00:00:00Z",
        "CupBottom": "2025-10-15T00:00:00Z",
        "RightRim": "2026-02-20T00:00:00Z",
        "HandleLow": "2026-03-10T00:00:00Z"
      },
      "Reasons": ["rim_reclaimed", "handle_valid", "volume_confirmed"]
    }
  ]
}
```

---

## Alerts

Console alerts are controlled by config:

- `defaults.alerts.enabled`
- `defaults.alerts.console.enabled`
- `defaults.alerts.console.include_evidence`
- `defaults.alerts.rate_limit.enabled`
- `defaults.alerts.rate_limit.min_minutes_between_same_event`
- `defaults.alerts.min_confidence.*`

When enabled, alerts are also persisted (append-only) to `events.jsonl` / `events.csv` depending on your configuration and CLI options.

---

## Practical examples

### A) “As-of” run to reproduce historical state

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -AsOf '2026-03-01'
```

### B) Quiet batch run across many symbols (example loop)

```powershell
$symbols = @('AAPL','MSFT','NVDA')
foreach ($s in $symbols) {
  pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
    -InputCsv "./data/$s.csv" `
    -Symbol $s `
    -OutDir "./out/$s" `
    -Quiet
}
```

### C) Tighten cup depth constraints

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -ConfigOverrideJson '{
    "detection": {
      "geometry": {
        "cup_depth": { "min_pct": 0.15, "max_pct": 0.40 }
      }
    }
  }'
```

### D) Disable persistence (no files written)

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -ConfigOverrideJson '{
    "persistence": { "enabled": false }
  }'
```

---

## Troubleshooting

### “CSV missing required columns”
- Confirm your header names include a timestamp/date/time field and OHLCV.
- Ensure Volume is numeric (no commas, no “N/A”).

### “Not enough bars”
Defaults expect enough history to compute indicators and detect patterns:

- `defaults.data.requirements.min_bars_total` (default 260)
- `defaults.data.requirements.min_bars_for_indicators` (default 60)

Provide more history or lower these thresholds via override.

### Unexpected timestamps / timezones
- The importer converts timestamps to UTC.
- If your timestamps are “local time” without offset, they may be treated as UTC (depending on parsing). Prefer ISO-8601 with offset if possible, e.g. `2026-04-01T16:00:00-04:00`.

---

## Reference: Key config areas (high level)

All defaults live in `config/defaults.json` under `defaults.*`:

- `app.*`: timezone, log level
- `data.*`: timeframe, resample behavior, minimum bars, NaN policies
- `indicators.*`: volume metrics, ATR, regime, sideways detection
- `detection.*`: durations, geometry constraints, handle rules, breakout confirmation, failure rules
- `scoring.*`: component weights, confidence, timing/urgency thresholds
- `entry_zones.*`: pivot/entry/stop/risk modeling
- `persistence.*`: output directory and append-only logs
- `alerts.*`: console alerts, rate limiting, thresholds

For most tuning, prefer `-ConfigOverrideJson` for quick experiments and a `-UserConfigFile` for repeatable setups.

---