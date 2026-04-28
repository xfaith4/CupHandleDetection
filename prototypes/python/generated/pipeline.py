"""pipeline.py — End-to-end cup-and-handle screening pipeline.

Fetches live market data via data_fetcher, scores each ticker with
cup_handle_model_v2, and produces a colour-coded terminal report.

Usage:
    cd generated
    python pipeline.py
"""

from __future__ import annotations

import logging
import sys

from cup_handle_model_v2 import ModelResult, evaluate
from data_fetcher import stock_input_from_ticker


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# ANSI colour helpers
# ---------------------------------------------------------------------------

_URGENCY_COLORS: dict[str, str] = {
    "BUY":    "\033[92m",   # bright green
    "SIGNAL": "\033[93m",   # bright yellow
    "ALERT":  "\033[33m",   # yellow
    "WATCH":  "",           # default
    "SKIP":   "",           # no colour
}
_RESET = "\033[0m"


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

def run_pipeline(tickers: list[str]) -> list[ModelResult]:
    """Fetch + score each ticker. Skips on error. Returns sorted by timing_score desc."""
    results: list[ModelResult] = []

    for ticker in tickers:
        try:
            logger.info("Processing %s ...", ticker)
            stock_input = stock_input_from_ticker(ticker)
            result = evaluate(stock_input)
            results.append(result)
            logger.info(
                "  %-6s  stage=%-18s  prob=%5.1f%%  timing=%5.1f  urgency=%s",
                ticker,
                result.stage.value,
                result.probability,
                result.timing_score,
                result.urgency,
            )
        except Exception:
            logger.warning("Skipping %s due to error:", ticker, exc_info=True)

    results.sort(key=lambda r: r.timing_score, reverse=True)
    return results


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def print_report(result: ModelResult) -> None:
    """Pretty-print a single result with ANSI urgency colours."""
    color = _URGENCY_COLORS.get(result.urgency, "")
    reset = _RESET if color else ""

    print(f"\n{color}{'='*62}")
    print(f"  Ticker:         {result.ticker}")
    print(f"  Stage:          {result.stage.value}")
    print(f"  Depth:          {result.depth_pct:.1f}%")
    print(f"  Probability:    {result.probability:.1f}%")
    print(f"  Timing Score:   {result.timing_score:.1f} / 100")
    print(f"  Urgency:        {result.urgency}")

    if result.entry_zones:
        ez = result.entry_zones
        lo, hi = ez["right_side_add"]
        print(f"  Entry Zones:")
        print(f"    Cup Bottom:       ${ez['cup_bottom']:>10.2f}")
        print(f"    Right-Side Add:   ${lo:>10.2f} - ${hi:.2f}")
        print(f"    Handle Pivot:     ${ez['handle_pivot']:>10.2f}")
        print(f"    Stop Loss:        ${ez['stop_loss']:>10.2f}")
    else:
        print(f"  Entry Zones:    N/A (disqualified)")

    if result.disqualified:
        print(f"  DQ Reason:      {result.disqualify_reason}")

    print(f"{'='*62}{reset}")


def _print_summary(results: list[ModelResult]) -> None:
    col_w  = 78
    header = (
        f"{'Rank':<5} {'Ticker':<8} {'Stage':<20} "
        f"{'Depth%':>7} {'Prob%':>7} {'Timing':>8} {'Urgency':<8}"
    )
    sep = "-" * col_w

    print(f"\n{'  SUMMARY RANKING  ':^{col_w}}")
    print(header)
    print(sep)

    for rank, r in enumerate(results, start=1):
        color = _URGENCY_COLORS.get(r.urgency, "")
        reset = _RESET if color else ""
        print(
            f"{color}"
            f"{rank:<5} {r.ticker:<8} {r.stage.value:<20} "
            f"{r.depth_pct:>7.1f} {r.probability:>7.1f} "
            f"{r.timing_score:>8.1f} {r.urgency:<8}"
            f"{reset}"
        )

    print(sep)
    print(f"Total evaluated: {len(results)}")
    if results:
        best = results[0]
        print(f"Top candidate:   {best.ticker}  (timing={best.timing_score:.1f}, urgency={best.urgency})")
    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    TICKERS: list[str] = ["MSFT", "AMZN", "JPM", "GOOGL", "WMT"]

    logger.info("Starting pipeline for: %s", ", ".join(TICKERS))

    results = run_pipeline(TICKERS)

    if not results:
        logger.warning("No results produced.")
        sys.exit(1)

    print("\n" + "=" * 62)
    print("  DETAILED REPORTS  (sorted by Timing Score)")
    print("=" * 62)
    for result in results:
        print_report(result)

    _print_summary(results)
