"""
Cup & Handle Predictability Model — v2
Based on observed characteristics from macro-driven market declines (Oct 2025–Apr 2026).

v2 adds Track-A extensions to ModelResult:
  entry_zones   — key price levels for trade planning
  timing_score  — C(t) composite timing readiness score (0–100)
  urgency       — WATCH / ALERT / SIGNAL / BUY / SKIP
  stage_history — list for live stage-transition timestamps (stubbed)

All original weights, StockInput fields, and scoring logic are unchanged.
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class DeclineReason(Enum):
    MACRO_SENTIMENT = "macro_sentiment"
    FUNDAMENTAL     = "fundamental"
    UNKNOWN         = "unknown"


class DeclineShape(Enum):
    GRADUAL_ROUNDED = "gradual_rounded"
    VERTICAL_CLIFF  = "vertical_cliff"
    MIXED           = "mixed"


class SectorType(Enum):
    CYCLICAL    = "cyclical"
    STRUCTURAL  = "structural"


class CupStage(Enum):
    LEFT_SIDE_EARLY   = "left_side_early"
    LEFT_SIDE_LATE    = "left_side_late"
    CUP_BOTTOM        = "cup_bottom"
    RIGHT_SIDE        = "right_side"
    HANDLE            = "handle"
    BREAKOUT          = "breakout"
    INDETERMINATE     = "indeterminate"


# ---------------------------------------------------------------------------
# Input dataclass  (unchanged from v1)
# ---------------------------------------------------------------------------

@dataclass
class StockInput:
    ticker: str

    decline_reason: DeclineReason = DeclineReason.UNKNOWN
    had_clear_prior_uptrend: bool = False

    peak_price: float = 0.0
    current_price: float = 0.0

    decline_shape: DeclineShape = DeclineShape.MIXED

    volume_drying_up_at_bottom: Optional[bool] = None
    volume_picking_up_on_right_side: Optional[bool] = None

    fundamentals_score: int = 3          # 1–5 scale
    sector_type: SectorType = SectorType.CYCLICAL
    weeks_sideways_at_bottom: int = 0


# ---------------------------------------------------------------------------
# Scoring weights  (unchanged from v1 — do NOT modify)
# ---------------------------------------------------------------------------

WEIGHTS = {
    "decline_reason": 30,
    "prior_uptrend":  15,
    "decline_depth":  20,
    "decline_shape":  10,
    "volume_profile": 10,
    "fundamentals":   10,
    "sector_type":    5,
}

assert sum(WEIGHTS.values()) == 100


# ---------------------------------------------------------------------------
# Original scoring helpers  (unchanged from v1)
# ---------------------------------------------------------------------------

def _score_decline_reason(reason: DeclineReason) -> float:
    return {
        DeclineReason.MACRO_SENTIMENT: 1.0,
        DeclineReason.UNKNOWN:         0.4,
        DeclineReason.FUNDAMENTAL:     0.0,
    }[reason]


def _score_prior_uptrend(had_uptrend: bool) -> float:
    return 1.0 if had_uptrend else 0.0


def _score_decline_depth(peak: float, current: float) -> tuple[float, float]:
    """Returns (score 0–1, depth_pct)."""
    if peak <= 0 or current <= 0 or current >= peak:
        return 0.5, 0.0
    depth_pct = (peak - current) / peak * 100
    if depth_pct <= 20:
        score = 1.0
    elif depth_pct <= 30:
        score = 0.9
    elif depth_pct <= 35:
        score = 0.75
    elif depth_pct <= 45:
        score = 0.5
    elif depth_pct <= 55:
        score = 0.25
    else:
        score = 0.0
    return score, depth_pct


def _score_decline_shape(shape: DeclineShape) -> float:
    return {
        DeclineShape.GRADUAL_ROUNDED: 1.0,
        DeclineShape.MIXED:           0.5,
        DeclineShape.VERTICAL_CLIFF:  0.0,
    }[shape]


def _score_volume_profile(drying: Optional[bool], picking_up: Optional[bool]) -> float:
    if drying is None and picking_up is None:
        return 0.5
    signals = []
    if drying is not None:
        signals.append(1.0 if drying else 0.0)
    if picking_up is not None:
        signals.append(1.0 if picking_up else 0.0)
    return sum(signals) / len(signals)


def _score_fundamentals(score: int) -> float:
    score = max(1, min(5, score))
    return (score - 1) / 4   # maps 1–5 → 0.0–1.0


def _score_sector(sector: SectorType) -> float:
    return {
        SectorType.CYCLICAL:   1.0,
        SectorType.STRUCTURAL: 0.0,
    }[sector]


# ---------------------------------------------------------------------------
# Stage detection  (unchanged from v1)
# ---------------------------------------------------------------------------

def _detect_stage(s: StockInput, depth_pct: float) -> CupStage:
    if s.current_price >= s.peak_price:
        return CupStage.BREAKOUT

    if depth_pct < 10 and s.volume_picking_up_on_right_side is True:
        return CupStage.HANDLE

    if s.volume_picking_up_on_right_side is True and depth_pct < 40:
        return CupStage.RIGHT_SIDE

    if s.volume_drying_up_at_bottom is True or s.weeks_sideways_at_bottom >= 3:
        return CupStage.CUP_BOTTOM

    if s.decline_shape != DeclineShape.VERTICAL_CLIFF and 20 <= depth_pct <= 45:
        return CupStage.LEFT_SIDE_LATE

    if depth_pct < 20 or s.decline_shape == DeclineShape.VERTICAL_CLIFF:
        return CupStage.LEFT_SIDE_EARLY

    return CupStage.INDETERMINATE


# ---------------------------------------------------------------------------
# Alert logic  (unchanged from v1)
# ---------------------------------------------------------------------------

def _generate_alert(stage: CupStage, probability: float, ticker: str) -> str:
    alerts = {
        CupStage.LEFT_SIDE_EARLY: (
            f"[WATCH]  {ticker}: Still in early decline. No action — wait for selling to slow."
        ),
        CupStage.LEFT_SIDE_LATE: (
            f"[WATCH]  {ticker}: Approaching potential bottom. Begin monitoring volume for drying."
        ),
        CupStage.CUP_BOTTOM: (
            f"[ALERT]  {ticker}: Volume drying up — possible cup bottom forming. "
            f"Watch for right-side reversal and volume pick-up. Primary entry zone."
        ),
        CupStage.RIGHT_SIDE: (
            f"[ALERT]  {ticker}: Right side building with increasing volume. "
            f"Confirm fundamentals hold. Consider position sizing."
        ),
        CupStage.HANDLE: (
            f"[ALERT]  {ticker}: Handle forming. Tight consolidation above prior base. "
            f"Watch for breakout above handle high on volume."
        ),
        CupStage.BREAKOUT: (
            f"[SIGNAL] {ticker}: Price reclaiming prior highs. "
            f"Breakout confirmation — monitor for follow-through volume."
        ),
        CupStage.INDETERMINATE: (
            f"[INFO]   {ticker}: Stage unclear — gather more price and volume data."
        ),
    }
    prob_str = f"  (Cup formation probability: {probability:.0f}%)"
    return alerts[stage] + prob_str


# ---------------------------------------------------------------------------
# Track-A extension helpers
# ---------------------------------------------------------------------------

def _compute_entry_zones(s: StockInput) -> dict:
    """Derive key price levels from pattern geometry.

    cup_bottom      – accumulation entry at current price
    right_side_add  – (lo, hi) range on the right-side climb
    handle_pivot    – O'Neil breakout pivot (peak + $0.10)
    stop_loss       – protective stop 8% below current price
    """
    return {
        "cup_bottom":     round(s.current_price, 4),
        "right_side_add": (round(s.peak_price * 0.95, 4), round(s.peak_price * 0.97, 4)),
        "handle_pivot":   round(s.peak_price + 0.10, 4),
        "stop_loss":      round(s.current_price * 0.92, 4),
    }


def _compute_timing_score(
    s: StockInput,
    stage: CupStage,
    depth_pct: float,
    probability: float,
) -> float:
    """Timing Readiness Score C(t) on a 0–100 scale.

    C(t) = (0.35 * price_score
          + 0.35 * volume_score
          + 0.20 * duration_score
          + 0.10 * regime_score) * 100
    """
    # price_score: depth thresholds
    if depth_pct <= 20:
        price_score = 1.0
    elif depth_pct <= 35:
        price_score = 0.75
    elif depth_pct <= 45:
        price_score = 0.5
    elif depth_pct <= 55:
        price_score = 0.25
    else:
        price_score = 0.0

    # volume_score: from the two volume booleans
    dry  = s.volume_drying_up_at_bottom
    pick = s.volume_picking_up_on_right_side
    if dry is None and pick is None:
        volume_score = 0.5
    elif dry is True and pick is True:
        volume_score = 1.0
    elif (dry is True) ^ (pick is True):   # exactly one
        volume_score = 0.5
    else:
        volume_score = 0.0

    # duration_score: weeks of sideways consolidation
    if s.weeks_sideways_at_bottom >= 4:
        duration_score = 1.0
    elif s.weeks_sideways_at_bottom >= 2:
        duration_score = 0.5
    else:
        duration_score = 0.0

    # regime_score: reuse fundamentals mapping (1–5 → 0–1)
    regime_score = _score_fundamentals(s.fundamentals_score)

    return round(
        (0.35 * price_score
         + 0.35 * volume_score
         + 0.20 * duration_score
         + 0.10 * regime_score) * 100.0,
        1,
    )


def _compute_urgency(stage: CupStage, disqualified: bool) -> str:
    if disqualified:
        return "SKIP"
    return {
        CupStage.LEFT_SIDE_EARLY: "WATCH",
        CupStage.LEFT_SIDE_LATE:  "WATCH",
        CupStage.INDETERMINATE:   "WATCH",
        CupStage.CUP_BOTTOM:      "ALERT",
        CupStage.RIGHT_SIDE:      "ALERT",
        CupStage.HANDLE:          "SIGNAL",
        CupStage.BREAKOUT:        "BUY",
    }.get(stage, "WATCH")


# ---------------------------------------------------------------------------
# Result dataclass
# ---------------------------------------------------------------------------

@dataclass
class ModelResult:
    ticker: str
    probability: float
    stage: CupStage
    alert: str
    depth_pct: float
    component_scores: dict = field(default_factory=dict)
    disqualified: bool = False
    disqualify_reason: str = ""
    # Track-A extensions
    entry_zones: Optional[dict] = None
    timing_score: float = 0.0
    urgency: str = "WATCH"
    stage_history: list = field(default_factory=list)  # TODO: populate from live stage-transition timestamps


# ---------------------------------------------------------------------------
# Main model function
# ---------------------------------------------------------------------------

def evaluate(s: StockInput) -> ModelResult:
    """Score a stock's likelihood of forming a cup and handle pattern."""

    # Hard disqualifiers
    if s.decline_reason == DeclineReason.FUNDAMENTAL:
        return ModelResult(
            ticker=s.ticker, probability=0.0, stage=CupStage.LEFT_SIDE_EARLY,
            alert=f"[SKIP]   {s.ticker}: Fundamental decline detected — pattern unlikely.",
            depth_pct=0.0, disqualified=True,
            disqualify_reason="Internal/fundamental decline. Business has changed.",
            entry_zones=None, timing_score=0.0, urgency="SKIP",
        )

    if s.sector_type == SectorType.STRUCTURAL and s.fundamentals_score <= 2:
        return ModelResult(
            ticker=s.ticker, probability=0.0, stage=CupStage.LEFT_SIDE_EARLY,
            alert=f"[SKIP]   {s.ticker}: Structural sector decline + weak fundamentals — avoid.",
            depth_pct=0.0, disqualified=True,
            disqualify_reason="Structurally declining sector with poor fundamentals.",
            entry_zones=None, timing_score=0.0, urgency="SKIP",
        )

    # Component scores
    depth_score, depth_pct = _score_decline_depth(s.peak_price, s.current_price)

    components = {
        "decline_reason": _score_decline_reason(s.decline_reason),
        "prior_uptrend":  _score_prior_uptrend(s.had_clear_prior_uptrend),
        "decline_depth":  depth_score,
        "decline_shape":  _score_decline_shape(s.decline_shape),
        "volume_profile": _score_volume_profile(
                              s.volume_drying_up_at_bottom,
                              s.volume_picking_up_on_right_side),
        "fundamentals":   _score_fundamentals(s.fundamentals_score),
        "sector_type":    _score_sector(s.sector_type),
    }

    probability = sum(components[k] * WEIGHTS[k] for k in components)
    probability = round(min(100.0, max(0.0, probability)), 1)

    stage = _detect_stage(s, depth_pct)
    alert = _generate_alert(stage, probability, s.ticker)

    # Track-A extensions
    entry_zones  = _compute_entry_zones(s)
    timing_score = _compute_timing_score(s, stage, depth_pct, probability)
    urgency      = _compute_urgency(stage, disqualified=False)

    return ModelResult(
        ticker=s.ticker,
        probability=probability,
        stage=stage,
        alert=alert,
        depth_pct=round(depth_pct, 1),
        component_scores=components,
        entry_zones=entry_zones,
        timing_score=timing_score,
        urgency=urgency,
    )


# ---------------------------------------------------------------------------
# Report printer
# ---------------------------------------------------------------------------

_URGENCY_COLORS = {
    "BUY":    "\033[92m",
    "SIGNAL": "\033[93m",
    "ALERT":  "\033[33m",
    "WATCH":  "",
    "SKIP":   "",
}
_RESET = "\033[0m"


def print_report(result: ModelResult) -> None:
    color = _URGENCY_COLORS.get(result.urgency, "")
    reset = _RESET if color else ""

    print(f"\n{color}{'='*60}")
    print(f"  {result.ticker}")
    print(f"{'='*60}")

    if result.disqualified:
        print(f"  STATUS:  DISQUALIFIED")
        print(f"  REASON:  {result.disqualify_reason}")
        print(f"  {result.alert}")
        print(f"{'='*60}{reset}")
        return

    stage_label = result.stage.value.replace("_", " ").title()
    bar_filled  = int(result.probability / 5)
    bar         = "#" * bar_filled + "-" * (20 - bar_filled)

    print(f"  Stage:          {stage_label}")
    print(f"  Decline:        {result.depth_pct:.1f}% from peak")
    print(f"  Probability:    [{bar}] {result.probability:.0f}%")
    print(f"  Timing Score:   {result.timing_score:.1f} / 100")
    print(f"  Urgency:        {result.urgency}")
    print()

    if result.entry_zones:
        ez = result.entry_zones
        lo, hi = ez["right_side_add"]
        print(f"  Entry Zones:")
        print(f"    Cup Bottom:       ${ez['cup_bottom']:>10.2f}")
        print(f"    Right-Side Add:   ${lo:>10.2f} - ${hi:.2f}")
        print(f"    Handle Pivot:     ${ez['handle_pivot']:>10.2f}")
        print(f"    Stop Loss:        ${ez['stop_loss']:>10.2f}")
        print()

    print(f"  Component Scores (weighted):")
    for key, score in result.component_scores.items():
        weight   = WEIGHTS[key]
        weighted = score * weight
        label    = key.replace("_", " ").title().ljust(18)
        print(f"    {label}  {score:.2f} x {weight:2d}  =  {weighted:5.1f} pts")
    print()
    print(f"  {result.alert}")
    print(f"{'='*60}{reset}")
    print()


# ---------------------------------------------------------------------------
# Example
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    from cup_handle_model import StockInput as _OrigInput  # noqa: F401 — kept for reference

    stocks = [
        StockInput(
            ticker="MSFT",
            decline_reason=DeclineReason.MACRO_SENTIMENT,
            had_clear_prior_uptrend=True,
            peak_price=525, current_price=369,
            decline_shape=DeclineShape.VERTICAL_CLIFF,
            volume_drying_up_at_bottom=False,
            volume_picking_up_on_right_side=False,
            fundamentals_score=5,
            sector_type=SectorType.CYCLICAL,
            weeks_sideways_at_bottom=0,
        ),
        StockInput(
            ticker="AMZN",
            decline_reason=DeclineReason.MACRO_SENTIMENT,
            had_clear_prior_uptrend=True,
            peak_price=245, current_price=210,
            decline_shape=DeclineShape.GRADUAL_ROUNDED,
            volume_drying_up_at_bottom=True,
            volume_picking_up_on_right_side=False,
            fundamentals_score=5,
            sector_type=SectorType.CYCLICAL,
            weeks_sideways_at_bottom=4,
        ),
    ]

    print("\nCUP & HANDLE MODEL v2\n")
    for s in stocks:
        print_report(evaluate(s))
