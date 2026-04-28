# Architecture

This repository has two supported runtime surfaces:

- `scripts/Invoke-CupHandleDetection.ps1` is the detector CLI. It loads CSV OHLCV data, normalizes/resamples bars, runs the PowerShell module, and writes detection outputs.
- `ui/workbench` is the React/Vite workbench UI. It includes an Express companion server for Alpha Vantage market snapshots and local workspace persistence.

The repository root is the only command surface. Use root scripts instead of changing into implementation directories.

## Standard Layout

| Path | Purpose |
|---|---|
| `src/CupHandleDetector/` | PowerShell module code. Public commands live in `Public/`; implementation helpers live in `Private/`. |
| `scripts/` | Human-facing launch scripts and operational commands. |
| `config/` | Default detector configuration. |
| `data/` | Small sample data that is safe to keep in source control. |
| `tests/` | Pester tests for the detector module and pipeline behavior. |
| `ui/workbench/` | Vite React workbench plus its local Express API server. |
| `docs/` | Stable documentation. Roadmaps, research notes, and generated reports are grouped under subfolders. |
| `prototypes/` | Historical or exploratory code that should not be treated as the production runtime. |

## Entrypoints

Run the UI from the repository root:

```powershell
pwsh ./scripts/Start-CupHandleWorkbench.ps1
```

or:

```bash
npm run ui
```

Run the detector from the repository root:

```powershell
pwsh ./scripts/Invoke-CupHandleDetection.ps1 -InputCsv ./data/sample_ohlcv.csv -Symbol SAMPLE
```

## Runtime Boundaries

The detector does not depend on the UI. It is a PowerShell pipeline that reads local CSV input and writes local output files.

The UI does not shell out to the detector today. It is a separate analysis/workbench surface with optional Alpha Vantage integration through `ALPHA_VANTAGE_API_KEY`.

The Python files under `prototypes/python` are retained for reference and future backtesting work, but they are not the canonical detector implementation.
