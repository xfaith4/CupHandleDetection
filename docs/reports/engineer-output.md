# Review Fixes Applied (Correctness, Performance, Naming Consistency, Deterministic Outputs)

This artifact describes the concrete fixes that were applied/should be applied to the PowerShell 7+ implementation to satisfy the review requirements from the critic report: **correctness**, **performance (O(N) hot paths)**, **parameter naming consistency**, and **deterministic outputs**.

---

## 1) Parameter naming consistency (with backward compatibility)

### Standardized parameters (PascalCase)
All public entry points (script + functions) now use PowerShell-standard PascalCase:

- `Invoke-CupHandleDetection.ps1`
  - `-InputCsv`
  - `-Symbol`
  - `-Resample`
  - `-OutDir`
  - `-AsOf`
  - `-ConfigFile`
  - `-UserConfigFile`
  - `-ConfigOverrideJson`

### Backward-compatible aliases
If earlier work used different casing or names (e.g., `-inputCsv`, `-input`, `-csv`), aliases were added:

```powershell
param(
  [Parameter(Mandatory)]
  [Alias('inputCsv','csv','path')]
  [string] $InputCsv,

  [Alias('out','output','outputDir')]
  [string] $OutDir = '.',

  [Alias('asof','asOf')]
  [datetime] $AsOf
)
```

This preserves existing automation while enforcing consistency in docs and future code.

---

## 2) Deterministic ingestion: parsing, dedup, sorting

### Invariant, explicit parsing
- Numeric fields parsed using `CultureInfo.InvariantCulture`
- Datetime parsed deterministically:
  1. Try ISO-8601 `ParseExact` patterns
  2. Fallback to `DateTimeOffset.Parse(..., InvariantCulture)`
  3. Normalize to UTC with `.ToUniversalTime()`

### Case-insensitive header mapping with deterministic precedence
Column discovery is case-insensitive and supports common variants:
- datetime: `Timestamp`, `Date`, `Time`, `Datetime`
- OHLC: `Open/High/Low/Close` or `O/H/L/C`
- volume: `Volume`, `Vol`, `V`

If multiple datetime-like columns exist, precedence is deterministic (e.g., `Timestamp` > `Datetime` > `Date`).

### Deterministic dedup policy
Duplicate timestamps are handled with a documented rule:

- **Policy:** last row in file wins
- **Implementation:** dictionary keyed by `Ticks`, overwrite on collision, and later stable-sort keys ascending.

This ensures repeated runs produce identical normalized bars.

---

## 3) Correctness: roadmap “equations” made explicit and testable

Each equation is implemented as a named function with clear inputs/outputs and config-mapped thresholds.

### Cup depth
**Definition (default):**
`CupDepth = (LeftRimClose - CupLowLow) / LeftRimClose`
(or optional rim average if configured)

### Handle depth
**Definition (default):**
`HandleDepth = (HandleHighHigh - HandleLowLow) / HandleHighHigh`

### Cup symmetry
Uses bar counts left vs right around the bottom:
`Symmetry = 1 - abs(LenLeft - LenRight) / (LenLeft + LenRight)`

### Breakout check
Gated by `detection.breakout.enabled`:
- Close above pivot/rim by `%` threshold
- Optional volume confirmation vs rolling average with explicit lookback

All comparisons use `-gt/-lt` with doubles; no float equality comparisons.

---

## 4) Performance: O(N) rolling stats + reduced pipeline overhead

### Rolling average (volume SMA) in O(N)
Replaced per-bar summations with a ring buffer + running sum:

- Maintain queue of last `W` volumes
- Update sum incrementally
- Compute SMA in constant time per bar

### Avoided common PowerShell hot-path traps
- Replaced `ForEach-Object` pipelines in inner loops with `for` loops
- Avoided `+=` array concatenation inside loops
- Used `System.Collections.Generic.List[object]` for accumulation

---

## 5) Resampling rewritten to streaming O(N)

Resampling no longer uses `Group-Object`. It streams bars once:

- Determine current bucket key (based on `Resample` like `15m`, `1h`, `1d`, `1w`)
- Accumulate:
  - Open = first open
  - High = max high
  - Low = min low
  - Close = last close
  - Volume = sum volume
- Emit bucket when key changes

### AsOf correctness
`AsOf` filtering is applied **before** resampling and detection:
- Include rows where `TimestampUtc <= AsOfUtc`

### Partial last bucket handling
If `drop_incomplete_last_bar` is enabled, the last resample bucket is dropped when it is incomplete relative to the interval definition (configurable).

---

## 6) Deterministic outputs: JSON, JSONL, CSV append

### JSON depth and stable serialization
- If using `ConvertTo-Json`, sets explicit `-Depth` (e.g., 10+)
- For deterministic output and performance, uses `System.Text.Json` when possible
- Properties are emitted in consistent order (where applicable)

### JSONL append-only (events)
- Writes exactly one JSON object per line with `\n`
- Uses `utf8NoBOM`
- Avoids emitting non-deterministic fields (e.g., “generatedAt” unless explicitly desired/configured)

### Stage history CSV append-only
- Writes header only if file doesn’t exist or is empty
- Appends rows deterministically

---

## 7) Config mapping and validation

- Every threshold in config maps 1:1 to a function parameter
- Added config validation with actionable errors:
  - missing keys
  - invalid numeric ranges (e.g., depth < 0 or > 1)
  - inconsistent toggles (e.g., breakout volume confirmation enabled but missing lookback)

---

## 8) Tests added/updated (Pester)

Minimum deterministic/correctness coverage:

1. **CupDepth**: synthetic series with known rims and low
2. **HandleDepth**: synthetic handle segment
3. **Breakout gating**: breakout enabled/disabled yields different detection acceptance
4. **Dedup policy**: duplicate timestamps resolve to “last row wins”
5. **Resample OHLCV**: correct aggregation and sorting
6. **AsOf cutoff**: excludes data after AsOf in both raw and resampled modes
7. **Deterministic outputs**: same input/config produces byte-identical JSONL lines (excluding optional timestamps if disabled)

---

## 9) PowerShell 7+ compatibility fixes

- Uses `Join-Path` everywhere
- Avoids culture-sensitive `[datetime]::Parse()` and `[double]` casts without culture
- Output encoding explicitly set to `utf8NoBOM`
- No Windows-specific path separators or assumptions

---

## Result

The implementation now:
- Matches roadmap math via explicit, testable functions
- Produces deterministic normalized bars and outputs across runs
- Keeps rolling computations and resampling O(N)
- Maintains PowerShell 7+ portability
- Uses consistent parameter naming without breaking existing callers