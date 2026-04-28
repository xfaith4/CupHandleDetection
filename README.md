# CupHandleDetector (PowerShell)

A PowerShell-based pipeline to ingest OHLCV bars from CSV, optionally resample them, compute indicator features, detect **Cup-with-Handle** patterns, emit alerts/events, and persist append-only logs and detection summaries.

- Primary entrypoint: `scripts/Invoke-CupHandleDetection.ps1`
- UI entrypoint: `npm run ui` or `scripts/Start-CupHandleWorkbench.ps1`
- Default configuration: `config/defaults.json`
- Architecture notes: **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**
- Full CLI & schema docs: **[`docs/USAGE.md`](docs/USAGE.md)**

> Disclaimer: This is research tooling, not financial advice.

---

## Features

- **CSV ingestion** (flexible headers; case-insensitive) for Timestamp/Open/High/Low/Close/Volume
- **Data normalization**: sorting, de-duplication, configurable invalid-row policy, optional “drop likely incomplete last bar”
- **Optional resampling** to a target timeframe (e.g., `1w`)
- **Cup-with-Handle detection pipeline** producing:
  - detection summaries (`detections.json`)
  - append-only event log (`events.jsonl`) when enabled
  - optional stage history (`stage_history.csv`) when enabled
- **Config layering** with deep-merge overrides (base config + user config + inline JSON override)
- **CI**: Pester tests run on push/PR via GitHub Actions

---

## Requirements

- PowerShell **7+** (`pwsh`)
- Node.js **20+** and npm for the workbench UI
- Your own OHLCV CSV file (no data provider built-in)

---

## Quickstart

### Launch the workbench UI

From the repository root:

```bash
npm run ui:install
npm run ui
```

PowerShell users can use the wrapper script instead:

```powershell
pwsh ./scripts/Start-CupHandleWorkbench.ps1
```

The UI starts Vite plus its local API server. Set `ALPHA_VANTAGE_API_KEY` in `ui/workbench/.env` or your shell to enable live market sync.

### 1) Run detection on a daily-bar CSV

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL
```

Outputs are written under `out/` by default (or whatever `defaults.persistence.output_dir` is set to).

### 2) Resample to weekly bars

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -Resample 1w
```

### 3) Write outputs to a custom directory

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -OutDir ./out/AAPL-weekly
```

---

## CLI Examples

### Use an “as-of” cutoff (reproducible backtests / point-in-time scans)

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -AsOf "2026-04-01T00:00:00Z"
```

### Layer configs (base + user) and override one field inline

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 `
  -InputCsv ./data/AAPL.csv `
  -Symbol AAPL `
  -ConfigFile ./config/defaults.json `
  -UserConfigFile ./config/my-overrides.json `
  -ConfigOverrideJson '{"detection":{"breakout":{"enabled":false}}}'
```

### Minimal help (see full parameter table in docs)

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 -?
```

For complete parameter documentation, examples, and output schemas, see **[`docs/USAGE.md`](docs/USAGE.md)**.

---

## Input Data (CSV)

Your CSV must contain OHLCV with a timestamp column. Headers are flexible; the importer searches common names (case-insensitive), including:

- Timestamp: `Timestamp` / `Date` / `Time` / `Datetime`
- OHLC: `Open`/`High`/`Low`/`Close` (also `O/H/L/C`)
- Volume: `Volume` / `Vol` / `V`

Timestamps can be ISO-8601 or anything `.NET [datetime]::Parse()` can read.

---

## Outputs

By default, the pipeline writes files under `out/` (configurable):

- `bars.normalized.csv` — cleaned, normalized bars used by the pipeline
- `detections.json` — detection summary (candidates, key levels/times, confidence, evidence)
- `events.jsonl` — append-only event stream (when enabled)
- `stage_history.csv` — append-only stage history (when enabled)

Filenames/paths are controlled via `config/defaults.json` (`defaults.persistence.*`).

---

## Repository Layout

- `src/CupHandleDetector/` — PowerShell module implementation
- `scripts/` — launch and operational entrypoints
- `ui/workbench/` — React/Vite workbench UI and local Express API
- `config/` — default pipeline configuration
- `data/` — small sample OHLCV inputs
- `tests/` — Pester tests
- `docs/` — usage, architecture, roadmap, research notes, and generated reports
- `prototypes/` — historical Python/React prototypes kept out of the runtime path

The roadmap now lives at **[`docs/roadmap/cup-handle-roadmap.md`](docs/roadmap/cup-handle-roadmap.md)**. Research notes live under **[`docs/research/`](docs/research/)**.

---

## Design Notes (mapped to the roadmap)

This section explains how the implementation is intended to align with typical roadmap milestones for this project.

### 1) Data ingestion & normalization
**Goal:** reliably consume OHLCV data from “bring your own CSV”.

- Flexible CSV header matching (timestamp + OHLCV)
- Validation policy is configurable (drop bad rows vs throw)
- Normalizes time to UTC, sorts rows, de-dups timestamps
- Optional heuristic to drop a likely incomplete final bar

**Roadmap mapping:** “robust ingestion”, “deterministic preprocessing”, “reproducible as-of runs”.

### 2) Timeframe resampling
**Goal:** run the same detector across daily/weekly/intraday datasets.

- CLI `-Resample` supports `^\d+[mhdw]$` (e.g., `15m`, `4h`, `1d`, `1w`)
- Can be driven via config as well (resample enabled/target minutes)

**Roadmap mapping:** “multi-timeframe support”, “weekly cup/handle scans”.

### 3) Feature computation & indicator layer
**Goal:** compute consistent indicator inputs for scoring and validation.

- Pipeline is designed to compute and use derived fields (price/volume stats, rolling measures, etc.)
- Configuration controls which checks are enabled and thresholds used

**Roadmap mapping:** “indicator/feature layer”, “configurable scoring components”.

### 4) Detection pipeline stages (scan → validate → alert)
**Goal:** separate candidate generation from confirmation logic and alerting.

- Detection produces a summary JSON (`detections.json`)
- Optional append-only event log for alert/event streaming (`events.jsonl`)
- Optional stage history persistence for debugging/analysis (`stage_history.csv`)

**Roadmap mapping:** “candidate lifecycle”, “stages and alerts”, “auditability”.

### 5) Persistence & audit logs
**Goal:** make runs debuggable and outputs consumable by other tools.

- Append-only events (JSONL) are friendly to `tail -f`, ingestion into ELK/Splunk, etc.
- Deterministic outputs for backtests (especially with `-AsOf`)

**Roadmap mapping:** “observability”, “append-only logs”, “integration-ready outputs”.

### 6) Configuration strategy
**Goal:** enable experimentation without editing code.

- Deep-merge config layering:
  1) `-ConfigFile` (base; defaults to `config/defaults.json`)
  2) `-UserConfigFile` (optional)
  3) `-ConfigOverrideJson` (optional; highest priority)

**Roadmap mapping:** “parameterize all thresholds/behaviors”, “easy tuning”.

### 7) Testing & CI
**Goal:** keep the pipeline stable as heuristics evolve.

- Pester tests in `tests/`
- GitHub Actions workflow runs tests on push/PR and uploads NUnit XML results

**Roadmap mapping:** “quality gates”, “automated regression tests”.

---

## Running Tests (locally)

```powershell
pwsh -Command "Install-Module Pester -Force -Scope CurrentUser -MinimumVersion 5.0.0"
pwsh -Command "Invoke-Pester -Path ./tests -Output Detailed"
```

---

## Contributing

Issues and PRs are welcome. If you add or change detection logic:
- update/extend Pester tests in `tests/`
- document new config fields and outputs in `docs/USAGE.md`

---

## License

Add your license of choice (e.g., MIT) in `LICENSE`. If this repository already includes a license file, that license governs.
