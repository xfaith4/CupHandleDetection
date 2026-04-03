## What this document is
A developer-facing roadmap/spec to replace the current **brittle, manual, boolean-driven** Cup & Handle logic (`cup_handle_model.py`, `Cup-handle-model-ui.js`) with a **time-aware, volume-aware, regime-aware** detection pipeline that is **statistically grounded**, **observable**, **testable**, and **PowerShell-friendly**.

Primary outcome: move from “manual heuristics” → **continuous signals + staged pipeline + confidence scoring + alerting + persistence**.

---

## Key entities (data model / concepts)

### Inputs
- **OHLCV time series**: `{Timestamp, Open, High, Low, Close, Volume}` at regular interval (daily/1h, etc.)
- Resampling rules if irregular: `open=first, high=max, low=min, close=last, volume=sum`

### Core computed indicators (per bar `t`)
- Price: `p(t)=Close`
- Volume: `v(t)=Volume`
- Rolling volume stats: `μ_v,L(t)`, `σ_v,L(t)`
- **Volume z-score**: `z_v(t;L) = (v(t)-μ)/σ` (clipped, safe on σ=0)
- **Volume percentile**: `pctl_v(t;L)` (sliding window rank)
- **Surge ratio**: `v(t) / median_v,L(t)` (surge >1.5; drying <0.6)
- **ATR(t;L)** for price-confirm thresholds
- **Regime signal `R(t)` in [0..1]**: volatility percentile-based (higher = more volatile / less reliable)
- **Width(t;W)** for sideways/base detection and auto `weeks_sideways_at_bottom`

### Higher-level outputs / artifacts
- **Stage labels per bar** (e.g., UNKNOWN, CUP_BOTTOM, etc.)
- **Candidate objects** representing detected cup/handle geometry (peak, trough, recovery, etc.)
- **Breakout events** with:
  - `Confirmed: bool`
  - `Confidence: [0..1]`
  - `ReasonCodes: []`
  - `Evidence: {close, reference_level, ATR, z_v, thresholds, regime_R, ...}`
- **Stage history**: append-only log of stage transitions with timestamps/durations
- **ModelResult additions** (roadmap): `entry_zones`, `urgency`, separate quality vs timing scores

---

## Purpose (implementation direction)
- Replace manual UI inputs (prices, boolean volume flags, manual sideways weeks) with:
  - **computed metrics** (z-scores/percentiles/ratios)
  - **explicit time constraints** (min/max durations for base/cup/handle)
  - **regime-scaled thresholds**
  - **confidence scoring** and **alerting**
  - **persistent history** for audit/backtesting

---

## Current gaps to fix (why)
- Manual values → stale/missed transitions
- Binary volume flags → can’t detect early accumulation/drying or graded confirmation
- No time dimension → false cups/handles (too short/too long) slip through
- Breakout = `close >= peak` → no ATR buffer, no volume confirmation
- No regime input → pattern reliability changes in high volatility
- No persistence/alerts → user re-checks manually each session

---

## Target pipeline structure (modules)
End-to-end flow is explicitly defined:

1. **Ingest OHLCV**
2. **Validate + resample to regular interval**
3. **Compute-Indicators** (rolling μ/σ, z_v, pctl_v, surge ratio, ATR, regime R, width, sideways weeks)
4. **Detect-Stages** (stage labels + cup/handle candidates)
5. **Confirm-Breakout** (price + volume + regime)
6. **Emit-Alert** (console + structured append-only file)
7. **Persist-History** (CSV/JSON; stage transitions + event evidence)

Constraints:
- Indicator passes should be **O(N)** or **O(N log K)**; avoid quadratic except explicitly bounded.

---

## Key detection rules (algorithmic spec highlights)

### Sideways base / `weeks_sideways_at_bottom` (auto-derived)
- `width(t;W) = (max - min) / median` over window W
- sideways if `width < width_threshold` (default 0.05)
- count consecutive qualifying windows → convert to weeks

### Cup geometry constraints
- Depth: **10%–50%** from left rim to trough
- Time: full cup **7–65 weeks**
- Symmetry: right side recovers ≥50% of depth within ~left-side duration ±30%
- Curvature proxy: slope first half negative, second half positive
- Left arc “near monotone” decline; limit sharp single-bar reversals

### Handle constraints
- Duration: **1–3 weeks** (5–15 daily bars)
- Depth: ≤12% below right rim; must not undercut cup midpoint
- Volume should **contract** during handle (surge ratio trending down)

### Breakout confirmation (must satisfy both)
- **Price**: `close(t) > pivot + k * ATR(t)` (default k=0.5)
- **Volume**: `z_v > z_confirm` OR `pctl_v > pctl_confirm` (defaults 2.0 / 90)

### Regime-aware threshold scaling
- `R(t)` derived from ATR percentile (higher volatility → stricter thresholds)
- Scale: `threshold_scaled = base * (1 + α * (R - 0.5))`, α default 0.4
- Applies to: volume thresholds and ATR multiplier `k`

---

## Confidence scoring (stage-change / timing reliability)
Defines a normalized confidence score `C(t) ∈ [0..1]`:

`C(t) = w_price*price_score + w_vol*volume_score + w_dur*duration_score + w_reg*(1-R)`

Default weights:
- price 0.35
- volume 0.35
- duration 0.20
- regime modifier 0.10

Edge handling:
- Missing components → drop + renormalize weights
- Insufficient history → `C=0` with explicit “deferred” reason
- Degraded volume (σ=0/median=0) → set safe defaults + flag degraded

---

## Observability + persistence (required)
- Console log lines include: timestamp, symbol, event_type, stage, confidence, close, volume metrics, ATR, regime, reason codes
- Append-only **CSV schema** and optional JSON with nested `evidence`
- Suggested telemetry: breakout counts, mean confidence, false-positive rate (e.g., reversal within 5 days), distributions of z_v, etc.

---

## PowerShell-first implementation guidance
- Pseudocode provided for:
  - `Compute-Indicators`
  - `Detect-Stages`
  - `Confirm-Breakout`
  - `Emit-Alert`
  - `Persist-History`
- Uses: arrays, loops, `PSCustomObject`, hashtables; avoids “exotic dependencies”
- Notes performance approaches (incremental rolling stats; sorted ring buffer for percentiles)

---

## Roadmap (phased delivery)
### Phase 1: Accuracy improvements without new data
- Enforce stage durations
- Replace volume booleans with ratios/z-scores
- Add breakout volume confirmation (+ “TENTATIVE” state)
- Handle quality scoring (duration + volume contraction + midpoint rule)
- Expand sector granularity scoring (optional)

### Phase 2: Timing precision (when to act)
- Stage transition timestamps + stage history
- **Entry zone calculator** (explicit pivot/stop levels)
- Split output into:
  - Pattern Quality Score
  - Timing Readiness Score (based on `C(t)`)
- Alert urgency levels (WATCH/ALERT/SIGNAL/BUY)
- Pattern failure detection + risk enum

### Phase 3: Live data integration (remove manual input)
- Fetch OHLCV automatically (yfinance/AV/etc.)
- Auto-compute sideways weeks
- Decline-shape classification
- Scheduled monitor + persistence + API/WebSocket UI updates
- Persistent watchlist store

### Phase 4: UI visibility
- Stage timeline visualization
- Entry/stop panel
- Dual score display
- Alert feed
- Data freshness indicator

---

## “Minimum viable next step” (explicit)
Implement **`entry_zones`** and **`timing_score` (`C(t)`)** inside `ModelResult` using existing inputs (no new data sources). This shifts the product from *pattern labeling* to *actionable timing + price levels*.