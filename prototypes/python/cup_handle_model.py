"""
Cup & Handle Predictability Model
Based on observed characteristics from macro-driven market declines (Oct 2025–Apr 2026).

Evaluates whether a falling large-cap stock is likely to form a cup and handle
continuation pattern, and detects the current stage of that pattern.
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class DeclineReason(Enum):
    MACRO_SENTIMENT = "macro_sentiment"   # External: fear, rates, tariffs, rotation
    FUNDAMENTAL     = "fundamental"        # Internal: earnings miss, competition, etc.
    UNKNOWN         = "unknown"


class DeclineShape(Enum):
    GRADUAL_ROUNDED = "gradual_rounded"   # Orderly profit-taking / rotation
    VERTICAL_CLIFF  = "vertical_cliff"    # Panic / forced selling / fundamental shock
    MIXED           = "mixed"


class SectorType(Enum):
    CYCLICAL    = "cyclical"    # Tech, consumer discretionary, financials — ebb and flow
    STRUCTURAL  = "structural"  # Legacy industry in permanent decline


class CupStage(Enum):
    LEFT_SIDE_EARLY   = "left_side_early"    # Still declining, no sign of bottom
    LEFT_SIDE_LATE    = "left_side_late"     # Decline slowing, approaching potential bottom
    CUP_BOTTOM        = "cup_bottom"         # Volume drying up, sideways consolidation
    RIGHT_SIDE        = "right_side"         # Recovering with increasing volume — ALERT ZONE
    HANDLE            = "handle"             # Tight consolidation after right-side recovery
    BREAKOUT          = "breakout"           # Price exceeds prior high (left rim) on volume
    INDETERMINATE     = "indeterminate"


# ---------------------------------------------------------------------------
# Input dataclass
# ---------------------------------------------------------------------------

@dataclass
class StockInput:
    ticker: str

    # --- Decline reason ---
    decline_reason: DeclineReason = DeclineReason.UNKNOWN

    # --- Prior trend ---
    had_clear_prior_uptrend: bool = False          # Was the stock in a healthy uptrend before drop?

    # --- Decline depth ---
    peak_price: float = 0.0
    current_price: float = 0.0

    # --- Decline shape ---
    decline_shape: DeclineShape = DeclineShape.MIXED

    # --- Volume profile ---
    volume_drying_up_at_bottom: Optional[bool] = None   # None = unknown
    volume_picking_up_on_right_side: Optional[bool] = None

    # --- Fundamentals (1–5 scale) ---
    # 5 = dominant market position, growing earnings, strong cash flow, low debt
    # 1 = unprofitable, shrinking revenue, high debt, losing market share
    fundamentals_score: int = 3                          # must be 1–5

    # --- Sector ---
    sector_type: SectorType = SectorType.CYCLICAL

    # --- Current stage hint (optional, used to refine stage detection) ---
    weeks_sideways_at_bottom: int = 0   # weeks of sideways consolidation observed


# ---------------------------------------------------------------------------
# Scoring weights
# ---------------------------------------------------------------------------

WEIGHTS = {
    "decline_reason":      30,   # Most important filter — external vs internal decline
    "prior_uptrend":       15,   # Cup is a continuation pattern; needs a trend to continue
    "decline_depth":       20,   # Depth controls recoverability
    "decline_shape":       10,   # Gradual = orderly; vertical = panic
    "volume_profile":      10,   # Drying volume at bottom is a key tell
    "fundamentals":        10,   # Institutional backstop for accumulation
    "sector_type":          5,   # Cyclical declines reverse; structural declines may not
}

assert sum(WEIGHTS.values()) == 100


# ---------------------------------------------------------------------------
# Scoring helpers
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
    """Returns (score 0–1, depth_pct). Ideal: <30%. Acceptable: 30–50%. Poor: >50%."""
    if peak <= 0 or current <= 0 or current >= peak:
        return 0.5, 0.0   # unknown / no decline
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
    """Volume drying at bottom + picking up on right side are both bullish signals."""
    if drying is None and picking_up is None:
        return 0.5   # no info
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
# Stage detection
# ---------------------------------------------------------------------------

def _detect_stage(s: StockInput, depth_pct: float) -> CupStage:
    """
    Infer the current cup stage from available signals.
    Rules derived from the observed characteristics in the model notes.
    """
    # Breakout: price has recovered above peak (depth ≤ 0)
    if s.current_price >= s.peak_price:
        return CupStage.BREAKOUT

    # Handle zone: shallow consolidation (<10% depth) after a right-side recovery
    if depth_pct < 10 and s.volume_picking_up_on_right_side is True:
        return CupStage.HANDLE

    # Right side: volume picking up, price recovering
    if s.volume_picking_up_on_right_side is True and depth_pct < 40:
        return CupStage.RIGHT_SIDE

    # Cup bottom: volume drying up, sideways consolidation
    if s.volume_drying_up_at_bottom is True or s.weeks_sideways_at_bottom >= 3:
        return CupStage.CUP_BOTTOM

    # Left side distinction: late vs early
    # Decline slowing (shape not vertical cliff) and moderate depth → late left side
    if s.decline_shape != DeclineShape.VERTICAL_CLIFF and 20 <= depth_pct <= 45:
        return CupStage.LEFT_SIDE_LATE

    if depth_pct < 20 or s.decline_shape == DeclineShape.VERTICAL_CLIFF:
        return CupStage.LEFT_SIDE_EARLY

    return CupStage.INDETERMINATE


# ---------------------------------------------------------------------------
# Alert logic
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
# Main model function
# ---------------------------------------------------------------------------

@dataclass
class ModelResult:
    ticker: str
    probability: float          # 0–100, weighted cup formation probability
    stage: CupStage
    alert: str
    depth_pct: float
    component_scores: dict = field(default_factory=dict)
    disqualified: bool = False
    disqualify_reason: str = ""


def evaluate(s: StockInput) -> ModelResult:
    """
    Score a stock's likelihood of forming a cup and handle pattern.
    Returns a ModelResult with probability, detected stage, and alert.
    """
    # Hard disqualifiers — if these fail, cup formation is very unlikely
    if s.decline_reason == DeclineReason.FUNDAMENTAL:
        return ModelResult(
            ticker=s.ticker, probability=0.0, stage=CupStage.LEFT_SIDE_EARLY,
            alert=f"[SKIP]   {s.ticker}: Fundamental decline detected — pattern unlikely.",
            depth_pct=0.0, disqualified=True,
            disqualify_reason="Internal/fundamental decline. Business has changed.",
        )

    if s.sector_type == SectorType.STRUCTURAL and s.fundamentals_score <= 2:
        return ModelResult(
            ticker=s.ticker, probability=0.0, stage=CupStage.LEFT_SIDE_EARLY,
            alert=f"[SKIP]   {s.ticker}: Structural sector decline + weak fundamentals — avoid.",
            depth_pct=0.0, disqualified=True,
            disqualify_reason="Structurally declining sector with poor fundamentals.",
        )

    # Compute individual scores
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

    # Weighted sum → 0–100
    probability = sum(components[k] * WEIGHTS[k] for k in components)
    probability = round(min(100.0, max(0.0, probability)), 1)

    stage = _detect_stage(s, depth_pct)
    alert = _generate_alert(stage, probability, s.ticker)

    return ModelResult(
        ticker=s.ticker,
        probability=probability,
        stage=stage,
        alert=alert,
        depth_pct=round(depth_pct, 1),
        component_scores=components,
    )


# ---------------------------------------------------------------------------
# Report printer
# ---------------------------------------------------------------------------

def print_report(result: ModelResult) -> None:
    print(f"\n{'='*60}")
    print(f"  {result.ticker}")
    print(f"{'='*60}")
    if result.disqualified:
        print(f"  STATUS:  DISQUALIFIED")
        print(f"  REASON:  {result.disqualify_reason}")
        print(f"  {result.alert}")
        return

    stage_label = result.stage.value.replace("_", " ").title()
    bar_filled = int(result.probability / 5)
    bar = "#" * bar_filled + "-" * (20 - bar_filled)

    print(f"  Stage:        {stage_label}")
    print(f"  Decline:      {result.depth_pct:.1f}% from peak")
    print(f"  Probability:  [{bar}] {result.probability:.0f}%")
    print()
    print(f"  Component Scores (weighted):")
    for key, score in result.component_scores.items():
        weight   = WEIGHTS[key]
        weighted = score * weight
        label    = key.replace("_", " ").title().ljust(18)
        print(f"    {label}  {score:.2f} × {weight:2d}  =  {weighted:5.1f} pts")
    print()
    print(f"  {result.alert}")
    print()


# ---------------------------------------------------------------------------
# Example: stocks from the observation notes (Apr 2, 2026)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    stocks = [
        StockInput(
            ticker="MSFT",
            decline_reason=DeclineReason.MACRO_SENTIMENT,
            had_clear_prior_uptrend=True,
            peak_price=525,
            current_price=369,
            decline_shape=DeclineShape.VERTICAL_CLIFF,    # steep and sustained
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
            peak_price=245,
            current_price=210,
            decline_shape=DeclineShape.GRADUAL_ROUNDED,   # sharp drop then sideways
            volume_drying_up_at_bottom=True,
            volume_picking_up_on_right_side=False,
            fundamentals_score=5,
            sector_type=SectorType.CYCLICAL,
            weeks_sideways_at_bottom=4,
        ),
        StockInput(
            ticker="JPM",
            decline_reason=DeclineReason.MACRO_SENTIMENT,
            had_clear_prior_uptrend=True,
            peak_price=333,
            current_price=292,
            decline_shape=DeclineShape.MIXED,             # choppy / jagged
            volume_drying_up_at_bottom=None,
            volume_picking_up_on_right_side=None,
            fundamentals_score=4,
            sector_type=SectorType.CYCLICAL,
            weeks_sideways_at_bottom=2,
        ),
        StockInput(
            ticker="GOOGL",
            decline_reason=DeclineReason.MACRO_SENTIMENT,
            had_clear_prior_uptrend=True,
            peak_price=344,
            current_price=290,
            decline_shape=DeclineShape.VERTICAL_CLIFF,    # accelerating decline
            volume_drying_up_at_bottom=False,
            volume_picking_up_on_right_side=False,
            fundamentals_score=5,
            sector_type=SectorType.CYCLICAL,
            weeks_sideways_at_bottom=0,
        ),
        StockInput(
            ticker="WMT",
            decline_reason=DeclineReason.MACRO_SENTIMENT,
            had_clear_prior_uptrend=True,
            peak_price=130,
            current_price=122,
            decline_shape=DeclineShape.GRADUAL_ROUNDED,
            volume_drying_up_at_bottom=True,
            volume_picking_up_on_right_side=True,
            fundamentals_score=4,
            sector_type=SectorType.CYCLICAL,
            weeks_sideways_at_bottom=6,
        ),
    ]

    print("\nCUP & HANDLE PREDICTABILITY MODEL")
    print("Observation window: Oct 2025 – Apr 2, 2026\n")

    results = [evaluate(s) for s in stocks]
    for r in results:
        print_report(r)

    # Summary table
    print("\n" + "="*60)
    print("  SUMMARY RANKING (by probability)")
    print("="*60)
    ranked = sorted(results, key=lambda r: r.probability, reverse=True)
    print(f"  {'Ticker':<8} {'Probability':>12}  {'Stage'}")
    print(f"  {'-'*8} {'-'*12}  {'-'*30}")
    for r in ranked:
        stage_label = r.stage.value.replace("_", " ").title()
        print(f"  {r.ticker:<8} {r.probability:>11.0f}%  {stage_label}")
    print()
