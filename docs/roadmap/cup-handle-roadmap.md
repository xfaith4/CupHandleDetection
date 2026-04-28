# Cup & Handle Model — Roadmap to Actionable Trading Intel

> Status as of 2026-04-28

## What This Is

A personal trading aid that scores stocks against the O'Neil cup-and-handle setup, identifies entry zones, and tells you when to act. Today it ranks tickers by pattern probability; the goal of this roadmap is to turn it into a tool that tells you **what to buy, when, at what price, with what stop, and how much** — and proves its signals work before you trust real money to them.

---

## Where We Are (April 2026)

**Shipped this sprint** (in `generated/`):

- `cup_handle_model_v2.py` — 7-component weighted scoring + stage detection + `entry_zones` + `timing_score` (C(t)) + `urgency` (WATCH / ALERT / SIGNAL / BUY / SKIP) + `stage_history` stub.
- `data_fetcher.py` — yfinance auto-population: peak/current price, volume z-scores and surge ratio, weeks-sideways (sliding-window from end), decline-shape classification (10-bar windows), prior-uptrend via SMA crossover.
- `pipeline.py` — fetch → score → ranked, color-coded report for any ticker list.
- `orchestrator.py` — multi-agent code generator with quality-gated refinement.

**What this gets us:** push-button screening of any watchlist with full price/volume context. Manual data entry is gone.

**What it does NOT yet get us:**

1. Confidence the signals actually work — no backtest.
2. Notification when SIGNAL/BUY fires — pipeline must be run by hand.
3. Position-size guidance — entry/stop exist but no risk-per-trade math.
4. Any record of past signals or outcomes — no learning loop.
5. Any portfolio-level filter — correlated signals look like five bets but are one.

These five gaps are the difference between "interesting demo" and "tool I trust real money to."

---

## The Roadmap

Sequenced for value delivered, not difficulty. Each step makes the previous step trustworthy or actionable. **Do them in order.**

### Step 1 — Validate the Model on History (BLOCKING)

> _If I had used this model on every cup-and-handle setup from 2018-2024, would I have made money?_

**Build:** `backtest.py`

- For each ticker × date in a historical window, run `evaluate()` against the OHLCV available _as of that date_ (no look-ahead).
- Record every transition into SIGNAL or BUY.
- For each signal, look forward 60 trading days and record max favorable excursion (MFE), max adverse excursion (MAE), and net return at +30 / +60 days.
- Output per-stage stats: hit rate, average return, average drawdown, expectancy.
- Run on the QQQ 100 from 2018-01-01 through 2024-12-31.

**Decision gate:**

- If BUY-stage expectancy is positive **and** `timing_score` correlates with realized return → continue to Step 2.
- If not → stop. Tune the model (probably the volume booleans or the cup-bottom thresholds) before adding more features.

**Why this is first:** every later feature compounds either trust or noise. This is the only step that tells you which.

---

### Step 2 — Position Sizing & Risk Math

> _SIGNAL fires for AMZN at $210 with a $193.20 stop. How many shares do I buy?_

**Add to `ModelResult`:**

- `risk_per_share` — `entry - stop_loss`
- `reward_per_share` — `peak_price - entry`
- `risk_reward_ratio` — `reward / risk`
- `suggested_shares(account_size, risk_pct)` — `floor((account_size * risk_pct) / risk_per_share)`

**Add to `pipeline.py`:** an optional `--account 100000 --risk 0.005` flag that prints share counts in the report and skips signals where R:R < 2.

**Why second:** without this, "BUY" is just a label. With it, every signal becomes a complete trade plan you can act on without thinking.

---

### Step 3 — Daily Scan + Notifications

> _How do I find out about SIGNAL/BUY events without running pipeline.py manually?_

**Build:**

- `scan_daily.py` — reads watchlist from `watchlist.json`, runs the pipeline, diffs stage/urgency against the prior run's snapshot in `state.json`, dispatches notifications on any transition into ALERT / SIGNAL / BUY.
- `notifier.py` — pluggable: SMTP email and a generic webhook (works with Slack, Discord, ntfy.sh).
- Schedule via Windows Task Scheduler 30 minutes after market close.

**Why third:** the model isn't useful if you forget to look at it. Push beats pull.

---

### Step 4 — Outcome Journal

> _Of the signals the model fired this year, which ones actually played out?_

**Build:**

- `signals.csv` (append-only on every scan): timestamp, ticker, stage, urgency, entry, stop, suggested_shares, model_version.
- `outcomes.csv` (back-filled weekly): for each signal older than 30 days, fetch price action since signal date and record MFE, MAE, current return, days-to-stop-hit (if any).
- `journal_report.py` — weekly summary: hit rate by stage, by sector, by month; rolling expectancy trend; flag if expectancy drops below the Step 1 baseline (model drift detection).

**Why fourth:** this is the feedback loop. Without it the model can't improve and you can't tell if it's drifting.

---

### Step 5 — Portfolio-Aware Filtering

> _The pipeline just gave me 4 BUYs in the same week — should I take all 4?_

**Add to `run_pipeline`:**

- After ranking, apply a sector-cap filter: skip a signal if it would put more than 30% of `account × max_total_risk` into one sector (use `yfinance.Ticker(t).info["sector"]`).
- Apply a correlation filter: skip if the signal's 60-day return correlates > 0.85 with an already-open position in `signals.csv`.
- Re-rank by `timing_score × (1 - sector_concentration_penalty)`.

**Why fifth:** uncorrelated signals are gold; correlated signals are one bet pretending to be five. Without this, the screen will overweight whatever sector is currently in the news.

---

### Step 6 — UI Surface (Optional)

The React UI in `Cup-handle-model-ui.js` is for manual exploration. If Steps 1-5 deliver, the UI's job shrinks to rendering what the daily scan already produces:

- Today's signals (color-coded by urgency)
- Open positions with current MAE / MFE vs. stop
- 30-day rolling expectancy chart from the journal CSVs

Do this last because a CLI plus email/webhook covers the actual user need; the UI is a "nice to browse" layer over the trustworthy pipeline.

---

## What's Off the Roadmap (and Why)

| Cut item | Reason |
|---|---|
| Statistical regime signal `R(t)` from ATR percentile | Premature — we don't yet know if it improves on the existing fundamentals proxy. Revisit if Step 1 backtest shows volatility-adjusted thresholds matter. |
| Real-time intraday detection / WebSocket | Daily bars are the right resolution for this pattern (O'Neil setups play out over weeks). Adds infra cost for no edge. |
| Pattern-failure ML classifier | Over-engineering. Step 1 will reveal whether failure prediction is even a real problem worth modeling. |
| Sector enum granularity expansion | Cosmetic. Step 5's sector filter uses live `yfinance.info["sector"]`, not the static enum. |
| FastAPI service + WebSocket alerts | Not needed for a single-user tool. CLI + scheduled task + webhook is simpler and equally effective. |
| `stage_history` populated from live transitions | Stub left in `ModelResult`. Becomes free once Step 3's diff against `state.json` runs daily — no extra work. |

---

## How to Read the Spec Below

The remainder of this document is the **Engineering Spec Appendix**: equations, parameter tables, algorithmic pseudocode, test cases, and observability rules. It is reference material for whoever implements the deeper detection modules described above (in particular, the regime signal and stage-confidence math become relevant only if Step 1's backtest justifies them).

It is **not the roadmap.** Don't pick work from below; pick from above.

---

## Appendix: Engineering Spec Reference

This section defines the algorithmic requirements for converting the model into a statistically-grounded pipeline. It is intended for implementation by an engineer working in Python.

### Design Standards

- Replace manual/boolean inputs with continuous, measurable quantities (z-scores, percentiles, normalized scores in [0..1]).
- Make all stage definitions time-aware (explicit duration minima/maxima for base, cup, handle, consolidation).
- Replace binary volume checks with continuous, statistically-tested volume confirmation (rolling z-scores, percentiles, surge ratios).
- Provide numeric stage-change confidence scores in [0..1] and alerting thresholds.
- Persist detection history and stage transitions (append-only CSV/JSON) for post-hoc analysis.
- Require price + volume confirmation for breakouts; thresholds must be adjustable by a derived regime signal R(t).
- Compute `weeks_sideways_at_bottom` automatically from price action (volatility/width + time windows).
- All algorithms must be implementable in plain Python using pandas and numpy.

### Inputs and Environment

- **Input:** Timestamped OHLCV series (Open, High, Low, Close, Volume) at a regular bar interval (e.g., 1h, 1d). If timestamps are irregular, resample using time-bucket aggregation: `open=first`, `high=max`, `low=min`, `close=last`, `volume=sum`.
- **Target environment:** Python 3.10+. Use `logging` for console/file logs; append to CSV/JSON via `pandas.to_csv` or `json`. Use `pd.DataFrame`, `np.ndarray`, and dataclasses in pseudocode.
- **Data requirements:**
  - Minimum bars required = largest lookback window; if not met, defer detection and emit a clear warning.
  - If volume is missing: fall back to volume-naive thresholds with explicitly degraded confidence, or fail with a logged error.
  - If volume is flat or zero: report degraded volume-signal reliability; avoid hard confirmations.
- **Performance:** Core indicator passes must be O(N) or O(N log N). Quadratic algorithms are not acceptable unless explicitly justified.

---

### Spec Section 1 — Variable and Symbol Table

Define all variables and notation used in equations.

| Symbol | Type | Units | Description |
|---|---|---|---|
| `p(t)` | Series | Price | Close price at bar `t` |
| `v(t)` | Series | Shares | Volume at bar `t` |
| `t` | Integer | Bars | Bar index (0-based) |
| `Δt` | Scalar | Bars or time | Bar interval (e.g., 1d) |
| `L` | Integer | Bars | Lookback window length |
| `μ_v,L(t)` | Scalar | Shares | Rolling mean of volume over L bars ending at t |
| `σ_v,L(t)` | Scalar | Shares | Rolling std dev of volume over L bars ending at t |
| `z_v(t;L)` | Scalar | Dimensionless | Volume z-score at bar t with window L |
| `pctl_v(t;L)` | Scalar | [0..100] | Rolling volume percentile at bar t with window L |
| `ATR(t;L)` | Scalar | Price | Average True Range over L bars ending at t |
| `R(t)` | Scalar | [0..1] | Market regime signal at bar t (0 = calm, 1 = high-vol) |
| `C(t)` | Scalar | [0..1] | Stage-change confidence score at bar t |
| `W` | Integer | Bars/weeks | Sliding window for `weeks_sideways_at_bottom` computation |
| `width_threshold` | Scalar | Ratio | Max normalized price range for a bar to count as "sideways" |

---

### Spec Section 2 — Equations and Statistical Criteria

#### 2.1 Volume Normalization

**Rolling z-score:**

```text
z_v(t;L) = (v(t) - μ_v,L(t)) / σ_v,L(t)
```

- If `σ_v,L(t) = 0` or volume is flat: set `z_v = 0` and flag `volume_signal_degraded = true`.
- Clip z-score to `[-5, +5]` to prevent outlier distortion.

**Rolling percentile:**

```text
pctl_v(t;L) = rank_of(v(t)) / L * 100
```

- Computed over the sliding window of the last L bars.
- O(N log K) with a sorted ring buffer; use binary insert/evict for PowerShell compatibility.

**Surge ratio:**

```text
surge_ratio(t;L) = v(t) / median_v,L(t)
```

- `surge_ratio > 1.5` → volume surge (confirmation signal)
- `surge_ratio < 0.6` → volume drying (accumulation signal)

**Divide-by-zero guard:** if `median_v,L = 0`, set `surge_ratio = 1.0` and flag degraded.

#### 2.2 Stage Detection Criteria

**Base (sideways consolidation):** Rolling width per window W:

```text
width(t;W) = (max(close[t-W..t]) - min(close[t-W..t])) / median(close[t-W..t])
```

- Duration: ≥ 4 weeks, ≤ 65 weeks
- Count consecutive windows where `width < width_threshold` (default: 0.05, i.e., ±5%).
- `weeks_sideways_at_bottom` = count of qualifying consecutive W-bar windows converted to weeks.

**Cup formation:**

- Left arc: monotone decline (or near-monotone) from peak to trough. Max single-bar reversal ≤ 3%.
- Right arc: recovery from trough back toward left rim, depth decreasing monotonically.
- Allowable cup depth: 10%–50% from left rim to trough.
- Symmetry check: right arc recovery ≥ 50% of cup depth within the same duration as the left arc ± 30%.
- Curvature proxy: slope of first half of arc < 0, slope of second half > 0.

**Handle consolidation:**
- Duration: ≥ 1 week, ≤ 3 weeks (daily bars: 5–15 bars)
- Depth: ≤ 12% below right rim (left rim level); must not undercut cup midpoint.
- Volume: contracting — `surge_ratio` trend decreasing over handle duration.

**Breakout confirmation** (both conditions required):
```
price_confirmed  = close(t) > reference_level + k * ATR(t; L_atr)
volume_confirmed = z_v(t; L_vol) > z_v_confirm  OR  pctl_v(t; L_vol) > pctl_v_confirm
```
Where `reference_level` = handle high (or left rim if no handle), `k` = ATR multiplier (default 0.5), and thresholds are regime-scaled (see §2.3).

#### 2.3 Regime-Aware Threshold Scaling

**Regime signal:**
```
R(t) = min(1.0, volatility_percentile_30d(t) / 75)
```
Where `volatility_percentile_30d` = percentile of current 14-day ATR relative to its 30-day rolling distribution.

**Threshold scaling:**

```text
threshold_scaled(t) = base_threshold * (1 + α * (R(t) - 0.5))
```

- `α = 0.4` (default): thresholds expand 20% in high-vol regimes, contract 20% in calm regimes.
- Apply to: `z_v_confirm`, `pctl_v_confirm`, ATR multiplier `k`.

#### 2.4 Stage-Change Confidence Score

```
C(t) = w_price * price_score(t)
     + w_vol   * volume_score(t)
     + w_dur   * duration_score(t)
     + w_reg   * (1 - R(t))
```

| Component | Weight | Derivation |
|---|---|---|
| `price_score` | 0.35 | Normalized depth within ideal range (0 = out of range, 1 = ideal) |
| `volume_score` | 0.35 | `min(1, z_v / z_v_confirm)` or `pctl_v / 100` |
| `duration_score` | 0.20 | `min(1, days_in_stage / min_stage_duration)` |
| `regime_modifier` | 0.10 | Inverse of regime (lower confidence in high-vol markets) |

Weights sum to 1.0. All components normalized to [0..1] before multiplication.

**Edge cases:**

- NaN in any component: exclude that component and renormalize remaining weights.
- Insufficient lookback: `C(t) = 0`; emit warning.
- Flat price series: `price_score = 0`; `duration_score` still computable.

---

### Spec Section 3 — Algorithmic Flow and Python Pseudocode

**End-to-end pipeline:**

```text
Ingest OHLCV
  └─ validate / resample to regular interval
      └─ compute_indicators  (rolling μ, σ, ATR, z_v, pctl_v, R(t), width, weeks_sideways)
          └─ detect_stages   (stage labels per bar + candidate cup/handle objects)
              └─ confirm_breakout  (price + volume + regime check per candidate)
                  └─ emit_alert    (console + file)
                      └─ persist_history  (append-only CSV/JSON)
```

#### `compute_indicators`

```python
import numpy as np
import pandas as pd
from dataclasses import dataclass
from typing import Optional

@dataclass
class IndicatorRow:
    mu_v:    float
    sigma_v: float
    z_v:     float
    ATR:     float
    R:       float
    width:   float

def compute_indicators(
    ohlcv: pd.DataFrame,   # columns: timestamp, open, high, low, close, volume
    params: dict,          # {L_vol, L_price, L_atr, W_sideways, width_threshold}
) -> Optional[dict[int, IndicatorRow]]:
    """Returns dict keyed by bar index, or None if insufficient bars."""
    N = len(ohlcv)
    L_price = params["L_price"]
    if N < L_price:
        import logging
        logging.warning(f"Insufficient bars ({N} < {L_price}); detection deferred.")
        return None

    L_vol  = params["L_vol"]
    L_atr  = params["L_atr"]
    W      = params["W_sideways"]
    wt     = params["width_threshold"]

    closes  = ohlcv["close"].to_numpy()
    volumes = ohlcv["volume"].to_numpy()
    highs   = ohlcv["high"].to_numpy()
    lows    = ohlcv["low"].to_numpy()

    results: dict[int, IndicatorRow] = {}

    for t in range(N):
        # --- Rolling mean and std ---
        w_start = max(0, t - L_vol + 1)
        vol_win = volumes[w_start : t + 1]
        mu_v    = vol_win.mean()
        sigma_v = max(vol_win.std(ddof=0), 1e-9)

        # --- z-score clipped to [-5, +5] ---
        z_v = float(np.clip((volumes[t] - mu_v) / sigma_v, -5.0, 5.0))

        # --- ATR (simplified: H-L only; full TR requires prev close) ---
        a_start  = max(0, t - L_atr + 1)
        tr_vals  = highs[a_start : t + 1] - lows[a_start : t + 1]
        ATR      = float(tr_vals.mean()) if len(tr_vals) > 0 else 0.0

        # --- Regime R(t): linear map of z_v into [0..1] ---
        R = float(np.clip((z_v + 2) / 4, 0.0, 1.0))  # replace with ATR percentile for production

        # --- Rolling width for sideways detection ---
        pw_start = max(0, t - W + 1)
        price_win = closes[pw_start : t + 1]
        w_med = float(np.median(price_win))
        width = float((price_win.max() - price_win.min()) / w_med) if w_med > 0 else 1.0

        results[t] = IndicatorRow(mu_v=mu_v, sigma_v=sigma_v, z_v=z_v, ATR=ATR, R=R, width=width)

    # --- Trailing pass: count consecutive sideways bars from end ---
    weeks_count = 0
    for t in range(N - 1, -1, -1):
        if results[t].width < wt:
            weeks_count += 1
        else:
            break
    results["weeks_sideways_at_bottom"] = int(weeks_count * W / 5)  # bars → weeks (5 bars/week)

    return results
```

#### `detect_stages`

```python
from dataclasses import dataclass, field

@dataclass
class CupCandidate:
    cup_low_bar:     int
    cup_low_price:   float
    peak_bar:        int
    peak_price:      float
    recovery_bar:    int
    depth_pct:       float
    duration_bars:   int
    weeks_sideways:  int

@dataclass
class StageResult:
    stage_labels: list[str]
    candidates:   list[CupCandidate] = field(default_factory=list)

def detect_stages(
    ohlcv: pd.DataFrame,
    indicators: dict,
    params: dict,   # {min_cup_weeks, max_cup_weeks, max_depth_pct}
) -> StageResult:
    N      = len(ohlcv)
    closes = ohlcv["close"].to_numpy()
    labels = ["UNKNOWN"] * N
    candidates: list[CupCandidate] = []

    min_bars = params["min_cup_weeks"] * 5
    max_bars = params["max_cup_weeks"] * 5

    for t in range(10, N - 5):
        close    = closes[t]
        lb_start = max(0, t - min_bars)
        peak_idx = int(np.argmax(closes[lb_start : t + 1])) + lb_start
        peak_p   = closes[peak_idx]
        depth_pct = (peak_p - close) / peak_p * 100

        if 10 <= depth_pct <= params["max_depth_pct"]:
            # Search for right-side recovery to near peak
            rb_end   = min(N, t + max_bars)
            right    = closes[t + 1 : rb_end]
            recovery = next((i for i, c in enumerate(right) if c >= peak_p * 0.98), None)

            if recovery is not None:
                recovery_bar = t + 1 + recovery
                candidates.append(CupCandidate(
                    cup_low_bar    = t,
                    cup_low_price  = close,
                    peak_bar       = peak_idx,
                    peak_price     = peak_p,
                    recovery_bar   = recovery_bar,
                    depth_pct      = round(depth_pct, 2),
                    duration_bars  = recovery_bar - peak_idx,
                    weeks_sideways = indicators.get("weeks_sideways_at_bottom", 0),
                ))
                labels[t] = "CUP_BOTTOM"

    return StageResult(stage_labels=labels, candidates=candidates)
```

#### `confirm_breakout`

```python
from dataclasses import dataclass

@dataclass
class BreakoutResult:
    confirmed:    bool
    confidence:   float
    reason_codes: list[str]
    evidence:     dict

def confirm_breakout(
    candidate:   CupCandidate,
    recent_bars: pd.DataFrame,   # last N bars ending at current bar
    indicators:  dict,
    params:      dict,           # {z_v_confirm, atr_multiplier, alpha_regime}
) -> BreakoutResult:
    t   = len(recent_bars) - 1
    ind = indicators[t]

    # --- Regime-scaled thresholds ---
    R           = ind.R
    scale       = 1 + params["alpha_regime"] * (R - 0.5)
    z_threshold = params["z_v_confirm"] * scale
    atr_k       = params["atr_multiplier"] * scale

    # --- Price confirmation ---
    latest_close    = float(recent_bars["close"].iloc[-1])
    reference_level = candidate.peak_price
    price_confirmed = latest_close > (reference_level + atr_k * ind.ATR)

    # --- Volume confirmation ---
    vol_confirmed = ind.z_v > z_threshold

    reason_codes: list[str] = []
    if not price_confirmed:
        reason_codes.append("price_below_pivot")
    if not vol_confirmed:
        reason_codes.append("volume_low")

    # --- Confidence [0..1] ---
    price_score = min(1.0, (latest_close - reference_level) / (atr_k * ind.ATR + 1e-9)) if price_confirmed else 0.0
    vol_score   = min(1.0, ind.z_v / (z_threshold + 1e-9))
    confidence  = round(0.5 * price_score + 0.5 * vol_score, 3)

    return BreakoutResult(
        confirmed    = price_confirmed and vol_confirmed,
        confidence   = confidence,
        reason_codes = reason_codes,
        evidence     = {
            "close":       latest_close,
            "reference":   reference_level,
            "ATR":         ind.ATR,
            "z_v":         ind.z_v,
            "z_threshold": z_threshold,
            "regime_R":    R,
        },
    )
```

#### `emit_alert`

```python
import logging
import pandas as pd
from pathlib import Path

def emit_alert(event: dict, out_path: Path, params: dict) -> None:
    """Console log + CSV append for a single alert event."""
    reason_str = ",".join(event.get("reason_codes", []))
    ev = event.get("evidence", {})
    line = (
        f"[{event['timestamp']}] [{event['symbol']}] {event['event_type']} "
        f"stage={event['stage']} confidence={event['confidence']:.2f} "
        f"price={ev.get('close')} vol_z={ev.get('z_v', 0.0):.2f} reason=[{reason_str}]"
    )
    logging.info(line)

    record = {
        "timestamp":      event["timestamp"],
        "symbol":         event["symbol"],
        "event_type":     event["event_type"],
        "stage":          event["stage"],
        "confidence":     event["confidence"],
        "price_at_event": ev.get("close"),
        "z_v":            ev.get("z_v"),
        "ATR":            ev.get("ATR"),
        "regime_R":       ev.get("regime_R"),
        "reason_codes":   "|".join(event.get("reason_codes", [])),
    }
    row = pd.DataFrame([record])
    row.to_csv(out_path, mode="a", header=not out_path.exists(), index=False)
```

#### `persist_history`

```python
import json
import pandas as pd
from pathlib import Path

def persist_history(events: list[dict], out_path: Path, fmt: str = "csv") -> None:
    """Append-only write — never overwrites existing records.

    CSV columns: timestamp, symbol, event_type, stage, stage_start, stage_end,
                 duration_bars, confidence, price_at_event, volume_at_event,
                 z_v, pctl_v, ATR, regime_R, reason_codes, notes
    JSON schema: same fields + nested 'evidence' object with raw indicator snapshot.
    """
    if fmt == "csv":
        df = pd.DataFrame(events)
        df.to_csv(out_path, mode="a", header=not out_path.exists(), index=False)

    elif fmt == "json":
        existing: list[dict] = []
        if out_path.exists():
            existing = json.loads(out_path.read_text(encoding="utf-8"))
        existing.extend(events)
        out_path.write_text(json.dumps(existing, indent=2, default=str), encoding="utf-8")
```

---

### Spec Section 4 — Parameter Defaults and Tuning

| Parameter | Default | Range | Notes |
|---|---|---|---|
| `L_vol` | 20 bars | 10–50 | Volume rolling window |
| `L_price` | 50 bars | 30–100 | Price rolling window |
| `L_atr` | 14 bars | 10–21 | ATR lookback |
| `W_sideways` | 5 bars | 3–10 | Width-check window (1 week = 5 bars for daily) |
| `width_threshold` | 0.05 | 0.03–0.08 | Max normalized price range for "sideways" bar |
| `z_v_confirm` | 2.0 | 1.5–3.0 | Volume z-score required for breakout confirmation |
| `pctl_v_confirm` | 90 | 80–95 | Volume percentile alternative threshold |
| `atr_multiplier` (k) | 0.5 | 0.3–1.5 | ATR above pivot required for price confirmation |
| `alpha_regime` | 0.4 | 0.2–0.6 | Regime sensitivity; higher = more threshold expansion in high-vol |
| `min_handle_bars` | 5 | 3–7 | ~1 week |
| `max_handle_bars` | 15 | 10–25 | ~3 weeks |
| `min_cup_weeks` | 7 | 5–10 | O'Neil minimum |
| `max_cup_weeks` | 65 | 50–80 | O'Neil maximum |
| `max_depth_pct` | 50 | 35–60 | Cup depth disqualification threshold |

**Regime scaling example:**
```
# High-vol market (R=0.8): thresholds expand 12%
z_v_scaled = 2.0 * (1 + 0.4 * (0.8 - 0.5)) = 2.24

# Calm market (R=0.2): thresholds contract 12%
z_v_scaled = 2.0 * (1 + 0.4 * (0.2 - 0.5)) = 1.76
```

**Tuning priority order:**

1. `z_v_confirm` and `pctl_v_confirm` — most sensitive to false breakouts
2. `width_threshold` — most sensitive to `weeks_sideways_at_bottom` accuracy
3. `atr_multiplier` — balance between early and late breakout detection
4. `alpha_regime` — only tune after regime signal is validated

---

### Spec Section 5 — Synthetic Test Cases

#### Example A: Valid breakout with price + volume confirmation

```
Bars (daily): 20 bars of recovery, close[19] = 102.0, referenceLevel = 100.0
ATR = 1.5, k = 0.5 → price threshold = 100.75
close[19] = 102.0 > 100.75  → price_confirmed = true
z_v[19]   = 2.4   > 2.0     → volume_confirmed = true

Expected: Confirmed=true, Confidence≈0.87, ReasonCodes=[]
Console:  [2026-04-02] [MSFT] BREAKOUT stage=breakout confidence=0.87 price=102.0 vol_z=2.40 reason=[]
CSV row:  2026-04-02,MSFT,BREAKOUT,breakout,...,0.87,102.0,...,2.40,...,[]
```

#### Example B: Price breakout without volume confirmation

```
close[19] = 101.5 > 100.75  → price_confirmed = true
z_v[19]   = 1.2   < 2.0     → volume_confirmed = false

Expected: Confirmed=false, Confidence≈0.41, ReasonCodes=['volume_low']
Console:  [2026-04-02] [AMZN] BREAKOUT_TENTATIVE stage=breakout confidence=0.41 ... reason=[volume_low]
```

#### Example C: Handle too short (below minimum duration)

```
Handle detected: 3 bars (< min_handle_bars=5)
DurationScore = 3/5 = 0.60 → penalizes confidence
ReasonCodes=['handle_too_short']

Expected: Confirmed=false, Confidence≈0.30, ReasonCodes=['handle_too_short']
```

#### Example D: `weeks_sideways_at_bottom` computation

```
Input: 25 bars of sideways price action, width per 5-bar window consistently ≈ 0.03 (< threshold 0.05)
Consecutive qualifying windows: 5 (= 5 weeks)

Expected: weeks_sideways_at_bottom = 5
Stage detection: CUP_BOTTOM (≥ 4 weeks satisfied)
```

---

### Spec Section 6 — Observability and Persistence

**Console log format:**
```
[2026-04-02T16:00:00] [MSFT] BREAKOUT stage=breakout confidence=0.87 price=102.0 vol_z=2.40 pctl_v=93 ATR=1.50 regime_R=0.42 reason=[]
```

**CSV schema:**
```
timestamp, symbol, event_type, stage, stage_start, stage_end, duration_bars,
confidence, price_at_event, volume_at_event, z_v, pctl_v, ATR, regime_R, reason_codes, notes
```

**JSON evidence object:**

```json
{
  "timestamp": "2026-04-02T16:00:00",
  "symbol": "MSFT",
  "event_type": "BREAKOUT",
  "stage": "breakout",
  "confidence": 0.87,
  "evidence": {
    "close": 102.0,
    "reference_level": 100.0,
    "ATR": 1.5,
    "z_v": 2.4,
    "pctl_v": 93,
    "regime_R": 0.42,
    "reason_codes": []
  }
}
```

**Recommended telemetry aggregations (daily):**
- Count of BREAKOUT events by symbol
- Mean confidence across all signals
- False-positive rate (breakouts followed by price reversal within 5 days)
- Mean `weeks_sideways_at_bottom` for confirmed breakouts vs. false breakouts
- Distribution of `z_v` at breakout bars

---

### Spec Section 7 — Complexity and Safety

| Algorithm | Complexity | Notes |
|---|---|---|
| Rolling mean/std | O(N) amortized | Incremental update: μ_{t} = μ_{t-1} + (x_t - x_{t-L}) / L |
| ATR per bar | O(N) | Single pass |
| Sliding percentile | O(N log K) | Sorted ring buffer of size K=L; binary insert/evict |
| Stage detection | O(N²) worst | Acceptable for daily bars ≤ 2 years; add index pruning for larger series |
| Full pipeline | O(N log N) | Dominated by percentile pass |

**Numeric safety rules:**

- All division operations require a non-zero denominator check with a minimum floor (e.g., `max(σ, 1e-9)`).
- ATR = 0: treat as calm market, set `R(t) = 0`, volume thresholds at base level.
- Price flat for > L bars: flag `price_signal_degraded`; do not emit BREAKOUT alerts.
- NaN propagation: replace with rolling median of last 5 valid values; log each replacement.

**Insufficient history behavior:**

- If `N < L_price`: return `{status: 'deferred', reason: 'insufficient_bars', bars_available: N, bars_required: L_price}`.
- Partial indicators (N ≥ L_vol but < L_price): compute volume indicators only; mark price-dependent outputs as `null`.
