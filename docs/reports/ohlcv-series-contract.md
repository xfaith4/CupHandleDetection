# OHLCV Bar Object Format, Parsing Rules, and Resampling Strategy
_Target file: `src/CupHandleDetector/Public/ConvertTo-OhlcvSeries.ps1`_

This artifact defines the **in-memory bar contract**, **input parsing rules**, and **resampling strategy** used to convert raw rows into a validated, regularized OHLCV series suitable for indicators and detection.

---

## 1) In-memory OHLCV bar contract (`Bar`)

### 1.1 Shape (PowerShell object)
Each bar MUST be a `[pscustomobject]` with exactly these canonical property names:

```powershell
[pscustomobject]@{
  Timestamp = [datetime]  # recommended Kind=Utc
  Open      = [double]
  High      = [double]
  Low       = [double]
  Close     = [double]
  Volume    = [double]    # accept Int64 input but normalize to double for math
}
```

### 1.2 Invariants / validation rules
A bar is considered valid if:

- `Timestamp` is non-null and parseable as a `DateTime`.
- `Open, High, Low, Close` are numeric and finite (no NaN/Infinity).
- `Volume` is numeric and finite; must be `>= 0`.
- Price bounds: `High >= Low`.
- Each OHLC value must lie within `[Low, High]` (allow tiny floating tolerance):
  - `Open  ∈ [Low - eps, High + eps]`
  - `Close ∈ [Low - eps, High + eps]`
  - (Optionally enforce same for `Open/Close` strictly; tolerance recommended: `eps = 1e-10`)

### 1.3 Series-level invariants
For a bar series (array of `Bar`):

- Sorted strictly ascending by `Timestamp`.
- No duplicate timestamps after consolidation.
- For a *regularized* series (post-resample): bars lie on expected bucket boundaries for the target timeframe.

---

## 2) Accepted inputs and parsing rules

`ConvertTo-OhlcvSeries.ps1` MUST accept objects from:
- `Import-Csv` rows, or
- JSON objects (`ConvertFrom-Json`), or
- already-constructed `Bar` objects (pass-through with validation).

### 2.1 Canonical column/property names
Primary (preferred) names:
- `Timestamp, Open, High, Low, Close, Volume`

Allow the following aliases (case-insensitive) and normalize to canonical:
- Timestamp: `Date`, `Datetime`, `Time`, `t`
- Open: `O`
- High: `H`
- Low: `L`
- Close: `C`, `AdjClose` (NOTE: if `AdjClose` used as Close, that implies adjusted series; treat as Close)
- Volume: `V`, `Vol`

If required fields cannot be resolved, throw a terminating error:
- `Missing required OHLCV columns: ...`

### 2.2 Timestamp parsing
Rules:
- Parse using PowerShell/NET parsing with invariant culture where possible.
- Accept:
  - ISO-8601 strings (`2026-01-02T00:00:00Z`, `2026-01-02`)
  - RFC3339-like timestamps with offset
  - Unix epoch seconds/milliseconds **only if explicitly enabled** (optional param; default off to avoid ambiguity)

Timezone policy:
- If input has `Z` or explicit offset: preserve moment, convert to UTC (`.ToUniversalTime()`).
- If input is “date-only” (no time): treat as midnight UTC **by default**.
- If input is naive datetime with time component but no offset:
  - default: treat as UTC (do not assume local), unless `-AssumeLocalTime` is specified.
- Output timestamps should be `Kind=Utc` whenever feasible.

### 2.3 Numeric parsing
- Use invariant culture to parse decimals (dot as decimal separator).
- Coerce to `[double]` for `Open/High/Low/Close/Volume`.
- Empty strings or nulls:
  - default policy: drop row with a warning record (non-terminating) unless `-Strict` is set.
- Negative prices: invalid → drop or error (see `-Strict`).

### 2.4 Sorting and deduplication
After parsing all rows:

1. Sort ascending by `Timestamp`.
2. Deduplicate by `Timestamp` using a configurable policy:
   - Default: `Last` (keep last row for a given timestamp).
   - Alternatives: `First`, `Error`, `Aggregate`.

Dedup policies:
- `Last`: keep the last row encountered for that timestamp after sorting stable by original order.
- `First`: keep first row.
- `Error`: throw terminating error on any duplicate timestamp.
- `Aggregate`: combine duplicates:
  - `Open = first.Open`
  - `High = max(High)`
  - `Low = min(Low)`
  - `Close = last.Close`
  - `Volume = sum(Volume)`

### 2.5 Validation behavior
Expose `-Strict` switch:
- If `-Strict`: any invalid row causes terminating error describing the row index and reason.
- Else: invalid rows are skipped, and a warning is emitted.

---

## 3) Resampling strategy (regularizing to target timeframe)

### 3.1 Supported timeframes
Target timeframes are strings:
- `1d` (daily)
- `1w` (weekly)

(Implementation can be extended later, but these must be supported now.)

Resampling occurs when:
- User requests `-Timeframe 1w` but input is daily/irregular.
- User requests `-Timeframe 1d` and input is intraday/irregular.
- User requests resampling explicitly (`-Resample` / `-ForceResample`), depending on CLI design.

### 3.2 Bucket alignment (how to compute bar “bucket start”)
All bucketing should operate in UTC to avoid DST issues.

**Daily (1d) bucket:**
- BucketStart = `Timestamp.Date` at `00:00:00Z` (UTC midnight)

**Weekly (1w) bucket:**
- Use ISO-like week anchored to **Monday 00:00:00Z** by default.
- BucketStart = date of Monday of the week containing `Timestamp` in UTC.
- WeekStartDay should be parameterizable (`-WeekStart Monday` default).

### 3.3 Aggregation rules (OHLCV within a bucket)
Given all source bars within a bucket, sorted by time:

- `Open`  = first bar’s `Open`
- `High`  = max of `High`
- `Low`   = min of `Low`
- `Close` = last bar’s `Close`
- `Volume`= sum of `Volume`

The resampled bar’s `Timestamp` MUST be `BucketStart` (not the last tick time).

### 3.4 Handling missing periods (gaps)
Two gap concepts:

1) **No bars in a bucket** (e.g., missing trading days in source):
- Default: do not synthesize bars; output only buckets that exist in the input.
- Rationale: avoids inventing OHLC and distorting indicators.

2) **Calendar non-trading days**:
- Daily series from equities typically omits weekends/holidays. That is acceptable.
- Weekly resampling naturally bridges these gaps.

If later indicator logic requires fixed-length spacing, it should rely on **bar count**, not calendar days, unless explicitly modeled.

Optional future switch (not required but allowed to design):
- `-FillGaps None|ForwardClose` where `ForwardClose` synthesizes OHLC=previous Close, Volume=0. Default `None`.

### 3.5 Partial last bucket
If the latest bucket is incomplete (e.g., current week mid-week):
- Default: include it if any data exists in bucket (it’s still a legitimate “so far” bar).
- Optional switch: `-DropLastPartial` for backtesting strictness.

### 3.6 Input frequency detection (when to resample)
Implementation guidance (simple + robust):
- Compute median delta between consecutive timestamps (in minutes/hours/days).
- Heuristics:
  - median delta <= 8 hours → treat as intraday → resample to 1d/1w as requested
  - median delta between ~0.75d and 2d → treat as daily-like
  - median delta between ~5d and 9d → treat as weekly-like
- If detection is ambiguous, default to “already in target timeframe” only when timestamps align with bucket boundaries; otherwise resample.

### 3.7 Output constraints post-resample
After resampling:
- Bars are sorted ascending by `Timestamp` (bucket start).
- Unique timestamps (one per bucket).
- Validity invariants enforced.

---

## 4) `ConvertTo-OhlcvSeries.ps1` expected behavior (public function contract)

### 4.1 Purpose
Convert arbitrary row objects into a validated OHLCV bar array and optionally resample to a target timeframe.

### 4.2 Suggested function signature
(Exact naming can vary, but behavior should match.)

```powershell
function ConvertTo-OhlcvSeries {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [object[]] $InputObject,

    [Parameter()]
    [ValidateSet('1d','1w')]
    [string] $Timeframe = '1d',

    [Parameter()]
    [ValidateSet('Last','First','Error','Aggregate')]
    [string] $DuplicatePolicy = 'Last',

    [Parameter()]
    [switch] $Strict,

    [Parameter()]
    [switch] $AssumeLocalTime,

    [Parameter()]
    [ValidateSet('Monday','Sunday','Saturday')]
    [string] $WeekStart = 'Monday',

    [Parameter()]
    [switch] $DropLastPartial
  )
  process { ... }
}
```

### 4.3 Output
Return value:
- `[Bar[]]` (PowerShell array of PSCustomObjects following the Bar contract)

No side effects:
- No file I/O; no global state.

Errors:
- Use terminating errors for schema-level failures (missing columns).
- Use `-Strict` to choose between terminating vs skipping invalid rows.

---

## 5) Examples (canonical)

### 5.1 CSV row → Bar
Input CSV headers:
`Timestamp,Open,High,Low,Close,Volume`

Row:
`2026-01-02,100.12,102.40,99.80,101.90,123456789`

Output Bar:
- `Timestamp = 2026-01-02T00:00:00Z`
- `Open=100.12 High=102.4 Low=99.8 Close=101.9 Volume=123456789`

### 5.2 Daily → Weekly resample
Given daily bars for a week:
- Weekly bucket start Monday 00:00Z
- Weekly OHLC computed with the rules in §3.3
- Volume summed

---

## 6) Non-goals / explicit exclusions
- No corporate action adjustment logic (splits/dividends) here.
- No trading calendar enforcement (NYSE holidays etc.) beyond UTC bucketing.
- No symbol metadata; this function only converts/resamples a single series.