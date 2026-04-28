"""data_fetcher.py — Auto-populate StockInput from live market data via yfinance."""

from __future__ import annotations

import time
from typing import Any

import numpy as np
import pandas as pd
import yfinance as yf

from cup_handle_model_v2 import (
    DeclineReason,
    DeclineShape,
    SectorType,
    StockInput,
)


# ---------------------------------------------------------------------------
# 1. fetch_ohlcv
# ---------------------------------------------------------------------------

def fetch_ohlcv(ticker: str, period: str = "2y") -> pd.DataFrame:
    """
    Fetch OHLCV daily bars using yfinance.
    Columns: open, high, low, close, volume (lowercase).
    Raises ValueError if fewer than 50 rows returned.
    Retries once on failure before raising.
    """
    last_exc: Exception | None = None

    for attempt in range(2):  # try at most twice
        try:
            tk = yf.Ticker(ticker)
            df: pd.DataFrame = tk.history(period=period, auto_adjust=True)

            if df.empty:
                raise ValueError(f"yfinance returned an empty DataFrame for {ticker!r}")

            # Normalise column names to lowercase
            df.columns = [c.lower().replace(" ", "_") for c in df.columns]

            # Keep only the five canonical OHLCV columns
            required = ["open", "high", "low", "close", "volume"]
            missing = [c for c in required if c not in df.columns]
            if missing:
                raise ValueError(
                    f"Missing columns {missing} in data for {ticker!r}. "
                    f"Available: {list(df.columns)}"
                )
            df = df[required].copy()

            if len(df) < 50:
                raise ValueError(
                    f"Only {len(df)} rows returned for {ticker!r}; need ≥ 50."
                )

            return df

        except Exception as exc:
            last_exc = exc
            if attempt == 0:
                time.sleep(1)  # brief pause before retry

    # Both attempts failed
    raise last_exc  # type: ignore[misc]


# ---------------------------------------------------------------------------
# 2. compute_peak_price
# ---------------------------------------------------------------------------

def compute_peak_price(df: pd.DataFrame) -> float:
    """Return the maximum close price in the DataFrame."""
    return float(df["close"].max())


# ---------------------------------------------------------------------------
# 3. compute_volume_stats
# ---------------------------------------------------------------------------

def compute_volume_stats(df: pd.DataFrame, lookback: int = 20) -> dict[str, float]:
    """
    Returns dict with keys:
      avg_volume_50d  — mean volume over the last 50 bars (or all bars if < 50)
      z_v_latest      — z-score of latest volume vs lookback window, clipped to [-5, +5]
      surge_ratio     — latest_volume / avg_volume_50d
    """
    volumes: pd.Series = df["volume"]
    latest_volume: float = float(volumes.iloc[-1])

    # avg_volume_50d
    tail_50 = volumes.iloc[-50:] if len(volumes) >= 50 else volumes
    avg_volume_50d: float = float(tail_50.mean())

    # z-score over the lookback window
    lb_window = volumes.iloc[-lookback:] if len(volumes) >= lookback else volumes
    lb_mean: float = float(lb_window.mean())
    lb_std: float = float(lb_window.std(ddof=1))

    if lb_std == 0 or np.isnan(lb_std):
        z_v_latest: float = 0.0
    else:
        z_v_latest = (latest_volume - lb_mean) / lb_std

    z_v_latest = float(np.clip(z_v_latest, -5.0, 5.0))

    # surge ratio
    surge_ratio: float = (
        latest_volume / avg_volume_50d if avg_volume_50d > 0 else 0.0
    )

    return {
        "avg_volume_50d": avg_volume_50d,
        "z_v_latest": z_v_latest,
        "surge_ratio": surge_ratio,
    }


# ---------------------------------------------------------------------------
# 4. compute_weeks_sideways
# ---------------------------------------------------------------------------

def compute_weeks_sideways(
    df: pd.DataFrame,
    window: int = 5,
    threshold: float = 0.05,
) -> int:
    """
    Slide BACKWARDS from the end of the series.
    A bar is 'sideways' if normalised price range < threshold:
        (high - low) / close < threshold
    Count consecutive sideways bars until a non-sideways bar is found.
    Convert bars to weeks: bars // window.
    """
    highs: np.ndarray = df["high"].values
    lows: np.ndarray = df["low"].values
    closes: np.ndarray = df["close"].values

    consecutive: int = 0
    for i in range(len(df) - 1, -1, -1):
        close_val = closes[i]
        if close_val == 0:
            break
        norm_range = (highs[i] - lows[i]) / close_val
        if norm_range < threshold:
            consecutive += 1
        else:
            break

    return consecutive // window


# ---------------------------------------------------------------------------
# 5. classify_decline_shape
# ---------------------------------------------------------------------------

def classify_decline_shape(df: pd.DataFrame, peak_idx: int) -> DeclineShape:
    """
    Classify how the stock declined from *peak_idx* to the most recent bar.

    Uses 10-bar sliding windows of the close price from peak_idx onward:
    - Any window whose (max − min) / max > 0.25 → VERTICAL_CLIFF
    - Decline spread over ≥ 8 weeks (40 bars) with no window drop > 0.15
      → GRADUAL_ROUNDED
    - Otherwise → MIXED
    """
    closes: np.ndarray = df["close"].values[peak_idx:]
    n = len(closes)
    win = 10

    if n < win:
        # Not enough data after peak to classify — fall back to MIXED
        return DeclineShape.MIXED

    max_window_drop: float = 0.0
    has_cliff: bool = False

    for start in range(n - win + 1):
        segment = closes[start : start + win]
        seg_max = segment.max()
        seg_min = segment.min()
        if seg_max == 0:
            continue
        drop = (seg_max - seg_min) / seg_max
        if drop > max_window_drop:
            max_window_drop = drop
        if drop > 0.25:
            has_cliff = True
            break  # no need to keep scanning

    if has_cliff:
        return DeclineShape.VERTICAL_CLIFF

    total_bars = n
    spread_over_8_weeks = total_bars >= 40

    if spread_over_8_weeks and max_window_drop <= 0.15:
        return DeclineShape.GRADUAL_ROUNDED

    return DeclineShape.MIXED


# ---------------------------------------------------------------------------
# 6. SMA crossover detection (helper for stock_input_from_ticker)
# ---------------------------------------------------------------------------

def _detect_prior_uptrend(df: pd.DataFrame) -> bool:
    """
    Detect whether a clear prior uptrend was in place using SMA crossover
    signals rather than a single static price-vs-SMA comparison.

    Returns ``True`` if **any** of the following crossover / trend
    conditions are met:

    1. **Golden cross (recent)** — the 50-day SMA crossed above the
       200-day SMA within the last 60 trading bars.
    2. **Price crossover (recent)** — the daily close crossed from below
       to above the 200-day SMA within the last 20 bars.
    3. **Sustained uptrend before peak** — the close was above the
       200-day SMA for ≥ 80 % of the 100 bars that precede the
       all-time-high close in the series, confirming an established
       uptrend before the cup began forming.
    """
    closes: pd.Series = df["close"]
    n = len(closes)

    # Minimum bars needed for a 200-day SMA; fall back gracefully
    sma_len = min(200, n)
    sma200: pd.Series = closes.rolling(window=sma_len, min_periods=sma_len).mean()

    # ------------------------------------------------------------------
    # 1. Golden cross: 50-day SMA crosses above 200-day SMA (last 60 bars)
    # ------------------------------------------------------------------
    sma50_len = min(50, n)
    sma50: pd.Series = closes.rolling(window=sma50_len, min_periods=sma50_len).mean()

    # We need at least 2 valid SMA values to check a crossover
    valid_mask = sma200.notna() & sma50.notna()
    if valid_mask.sum() >= 2:
        sma50_arr = sma50[valid_mask].values
        sma200_arr = sma200[valid_mask].values

        scan_len = min(60, len(sma50_arr) - 1)
        for i in range(len(sma50_arr) - scan_len, len(sma50_arr)):
            if i < 1:
                continue
            # Crossover: previous bar 50 <= 200, current bar 50 > 200
            if sma50_arr[i - 1] <= sma200_arr[i - 1] and sma50_arr[i] > sma200_arr[i]:
                return True

    # ------------------------------------------------------------------
    # 2. Price crossover above 200-day SMA (last 20 bars)
    # ------------------------------------------------------------------
    if sma200.notna().sum() >= 2:
        close_arr = closes.values
        sma200_arr_full = sma200.values

        scan_start = max(0, n - 20)
        for i in range(scan_start, n):
            if i < 1 or np.isnan(sma200_arr_full[i]) or np.isnan(sma200_arr_full[i - 1]):
                continue
            if close_arr[i - 1] < sma200_arr_full[i - 1] and close_arr[i] > sma200_arr_full[i]:
                return True

    # ------------------------------------------------------------------
    # 3. Sustained uptrend before the peak (≥ 80 % of 100 bars above SMA)
    # ------------------------------------------------------------------
    peak_pos: int = int(closes.values.argmax())
    lookback = min(100, peak_pos)  # bars available before peak
    if lookback >= 20 and sma200.notna().sum() > 0:
        region_close = closes.values[peak_pos - lookback : peak_pos]
        region_sma = sma200.values[peak_pos - lookback : peak_pos]

        # Only consider bars where the SMA was actually calculable
        valid = ~np.isnan(region_sma)
        if valid.sum() >= 20:
            above = (region_close[valid] > region_sma[valid]).sum()
            ratio = above / valid.sum()
            if ratio >= 0.80:
                return True

    return False


# ---------------------------------------------------------------------------
# 7. stock_input_from_ticker
# ---------------------------------------------------------------------------

def stock_input_from_ticker(ticker: str) -> StockInput:
    """
    Orchestrate all helper functions to produce a fully-populated StockInput.

    Fields that cannot be determined from price history alone are given
    sensible defaults (documented below).
    """
    df: pd.DataFrame = fetch_ohlcv(ticker)

    # Peak / current prices
    peak_price: float = compute_peak_price(df)
    current_price: float = float(df["close"].iloc[-1])

    # Prior uptrend via SMA crossover detection
    had_clear_prior_uptrend: bool = _detect_prior_uptrend(df)

    # Volume statistics
    vol_stats: dict[str, float] = compute_volume_stats(df)
    volume_drying_up_at_bottom: bool = vol_stats["surge_ratio"] < 0.7

    # Decline shape — use argmax of close as peak_idx
    peak_idx: int = int(df["close"].values.argmax())
    decline_shape: DeclineShape = classify_decline_shape(df, peak_idx)

    # Weeks sideways at the bottom
    weeks_sideways: int = compute_weeks_sideways(df)

    return StockInput(
        ticker=ticker,
        peak_price=peak_price,
        current_price=current_price,
        had_clear_prior_uptrend=had_clear_prior_uptrend,
        volume_drying_up_at_bottom=volume_drying_up_at_bottom,
        volume_picking_up_on_right_side=None,  # cannot determine from price alone
        decline_shape=decline_shape,
        weeks_sideways_at_bottom=weeks_sideways,
        decline_reason=DeclineReason.UNKNOWN,  # cannot auto-detect
        fundamentals_score=3,  # neutral default; override manually
        sector_type=SectorType.CYCLICAL,  # default; override manually
    )


# ---------------------------------------------------------------------------
# CLI quick-test
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    ticker_symbol: str = "MSFT"
    print(f"Fetching data for {ticker_symbol} …")
    si: StockInput = stock_input_from_ticker(ticker_symbol)
    print()
    print(si)