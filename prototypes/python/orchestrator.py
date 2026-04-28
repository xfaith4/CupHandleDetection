"""
orchestrator.py
Multi-agent orchestration for the Cup & Handle model improvements.

Runs Track A (scoring/timing logic) and Track B (data fetcher) in parallel,
evaluates each output against a quality rubric, refines up to MAX_REFINEMENTS
times, then passes both outputs to an integration agent that builds pipeline.py.

Usage:
    python orchestrator.py

Requirements:
    pip install anthropic pydantic
"""

import asyncio
import json
import logging
import re
import sys
from datetime import datetime
from pathlib import Path

import anthropic
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

MODEL           = "claude-opus-4-6"
MAX_REFINEMENTS = 3
MAX_TOKENS_CODE = 16_000
MAX_TOKENS_EVAL = 8_000
ROOT            = Path(__file__).parent
OUT_DIR         = ROOT / "generated"
LOG_FILE        = OUT_DIR / f"run_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

OUT_DIR.mkdir(exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
    ],
)
log = logging.getLogger(__name__)

# Thread-safe console lock so parallel track output doesn't interleave
_print_lock = asyncio.Lock()


async def aprint(msg: str) -> None:
    async with _print_lock:
        log.info(msg)


# ---------------------------------------------------------------------------
# Quality evaluation schema (Pydantic)
# ---------------------------------------------------------------------------

class QualityResult(BaseModel):
    score: float                     # 0.0 – 1.0
    passed: bool                     # score >= 0.85
    issues: list[str]
    refinement_instructions: str     # empty string when passed


# ---------------------------------------------------------------------------
# Quality rubrics
# ---------------------------------------------------------------------------

RUBRIC_A = """
Evaluate the generated Python code for Track A (model scoring and timing extensions).
Return a JSON object matching this schema exactly:
{
  "score": <float 0.0–1.0>,
  "passed": <bool>,
  "issues": [<string>, ...],
  "refinement_instructions": <string>
}

Scoring criteria (each worth 1/11 of the total):
1. ModelResult has entry_zones dict with keys: cup_bottom, right_side_add, handle_pivot, stop_loss.
2. entry_zones values are derived from pattern geometry (not arbitrary constants).
3. timing_score (C(t)) is computed as: 0.35*price_score + 0.35*volume_score + 0.20*duration_score + 0.10*regime_score, result ×100.
4. The four C(t) component weights sum to exactly 1.0 in the code.
5. urgency field added to ModelResult with values: WATCH / ALERT / SIGNAL / BUY / SKIP.
6. urgency mapping follows: LEFT_SIDE → WATCH, CUP_BOTTOM/RIGHT_SIDE → ALERT, HANDLE → SIGNAL, BREAKOUT → BUY, disqualified → SKIP.
7. stage_history list added to ModelResult (may be empty with a TODO comment for live timestamps).
8. disqualified stocks default to entry_zones=None and timing_score=0.0.
9. All new fields are typed (type hints present on the dataclass).
10. No syntax errors — code is complete and importable.
11. evaluate() function updated; the existing scoring logic is preserved unchanged.

Set passed=True only if score >= 0.85.
In refinement_instructions, list exactly what to fix (be specific about field names and logic).
Return ONLY the JSON object — no markdown, no explanation.
"""

RUBRIC_B = """
Evaluate the generated Python code for Track B (data fetcher module: data_fetcher.py).
Return a JSON object matching this schema exactly:
{
  "score": <float 0.0–1.0>,
  "passed": <bool>,
  "issues": [<string>, ...],
  "refinement_instructions": <string>
}

Scoring criteria (each worth 1/12 of the total):
1. fetch_ohlcv(ticker, period="2y") -> pd.DataFrame is present with correct signature.
2. fetch_ohlcv raises ValueError with a clear message if the returned DataFrame has fewer than 50 rows.
3. fetch_ohlcv retries exactly once on yfinance failure before raising.
4. compute_peak_price(df) -> float returns the maximum close price in the DataFrame.
5. compute_volume_stats(df, lookback=20) -> dict returns keys: avg_volume_50d, z_v_latest, surge_ratio.
6. z_v_latest in compute_volume_stats is clipped to [-5, +5].
7. surge_ratio in compute_volume_stats = latest_volume / avg_volume_50d (or lookback mean).
8. compute_weeks_sideways(df, window=5, threshold=0.05) -> int slides BACKWARDS from the end of the series.
9. classify_decline_shape(df, peak_idx) -> DeclineShape uses 10-bar windows and imports DeclineShape from cup_handle_model.
10. stock_input_from_ticker(ticker) -> StockInput orchestrates all the above functions.
11. stock_input_from_ticker uses a 200-day SMA crossover to set had_clear_prior_uptrend.
12. No syntax errors — code is complete and importable as a standalone module.

Set passed=True only if score >= 0.85.
In refinement_instructions, list exactly what to fix (be specific about function signatures and logic).
Return ONLY the JSON object — no markdown, no explanation.
"""

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

CONTEXT = """
You are extending a cup-and-handle pattern detection model written in Python.
The existing model is in cup_handle_model.py (same directory). Key facts:

- StockInput and ModelResult are @dataclass types (no __init__ override needed).
- CupStage enum: LEFT_SIDE_EARLY, LEFT_SIDE_LATE, CUP_BOTTOM, RIGHT_SIDE, HANDLE, BREAKOUT, INDETERMINATE.
- DeclineReason enum: MACRO_SENTIMENT, FUNDAMENTAL, UNKNOWN.
- DeclineShape enum: GRADUAL_ROUNDED, VERTICAL_CLIFF, MIXED.
- evaluate(s: StockInput) -> ModelResult is the main entry point.
- WEIGHTS dict sums to 100; do not change existing weights.
- depth_pct = (peak_price - current_price) / peak_price * 100.

Write complete, runnable Python 3.10+ code. Include all imports. Use type hints.
"""

PROMPT_A = CONTEXT + """

## Task: Extend cup_handle_model.py (Track A)

Add the following to the existing file WITHOUT changing any existing logic:

### 1. entry_zones field on ModelResult
Add `entry_zones: Optional[dict] = None` to ModelResult.
Populate it inside evaluate() based on current_price and depth geometry:
- cup_bottom:    current_price (the entry price for this stage)
- right_side_add: peak_price * 0.95 to peak_price * 0.97 (a range tuple)
- handle_pivot:  peak_price + 0.10 (O'Neil pivot point)
- stop_loss:     current_price * 0.92 (7–8% below current)
Set entry_zones=None for disqualified stocks.

### 2. timing_score field on ModelResult
Add `timing_score: float = 0.0` to ModelResult.
Implement _compute_timing_score(s: StockInput, stage: CupStage, depth_pct: float, probability: float) -> float.
Formula: C(t) = (0.35 * price_score + 0.35 * volume_score + 0.20 * duration_score + 0.10 * regime_score) * 100

Component definitions:
- price_score:    1.0 if depth_pct <= 20, 0.75 if <=35, 0.5 if <=45, 0.25 if <=55, else 0.0
- volume_score:   1.0 if volume_drying_up_at_bottom AND volume_picking_up_on_right_side,
                  0.5 if exactly one is True, 0.0 if both False, 0.5 if both None
- duration_score: 1.0 if weeks_sideways_at_bottom >= 4, 0.5 if >= 2, 0.0 otherwise
- regime_score:   use fundamentals_score mapped to 0–1 (same as _score_fundamentals)
Set timing_score=0.0 for disqualified stocks.

### 3. urgency field on ModelResult
Add `urgency: str = "WATCH"` to ModelResult.
Map stage to urgency inside evaluate():
- LEFT_SIDE_EARLY / LEFT_SIDE_LATE / INDETERMINATE → "WATCH"
- CUP_BOTTOM / RIGHT_SIDE → "ALERT"
- HANDLE → "SIGNAL"
- BREAKOUT → "BUY"
- disqualified → "SKIP"

### 4. stage_history field on ModelResult
Add `stage_history: list = field(default_factory=list)` to ModelResult.
Leave it as an empty list with a comment: # TODO: populate from live stage-transition timestamps

Return the COMPLETE updated cup_handle_model.py file — every line, including the original content.
"""

PROMPT_B = CONTEXT + """

## Task: Create data_fetcher.py (Track B)

Write a new file data_fetcher.py that auto-populates StockInput from live market data.

### Required functions (in this order):

```python
def fetch_ohlcv(ticker: str, period: str = "2y") -> pd.DataFrame:
    \"\"\"
    Fetch OHLCV daily bars using yfinance.
    Columns: open, high, low, close, volume (lowercase).
    Raises ValueError if fewer than 50 rows returned.
    Retries once on failure before raising.
    \"\"\"

def compute_peak_price(df: pd.DataFrame) -> float:
    \"\"\"Return the maximum close price in the DataFrame.\"\"\"

def compute_volume_stats(df: pd.DataFrame, lookback: int = 20) -> dict:
    \"\"\"
    Returns dict with keys:
      avg_volume_50d  — mean volume over the last 50 bars (or all bars if < 50)
      z_v_latest      — z-score of latest volume vs lookback window, clipped to [-5, +5]
      surge_ratio     — latest_volume / avg_volume_50d
    \"\"\"

def compute_weeks_sideways(df: pd.DataFrame, window: int = 5, threshold: float = 0.05) -> int:
    \"\"\"
    Slide BACKWARDS from the end of the series.
    A bar is 'sideways' if normalized price range < threshold:
        (high - low) / close < threshold
    Count consecutive sideways bars until a non-sideways bar is found.
    Convert bars to weeks: bars // window.
    \"\"\"

def classify_decline_shape(df: pd.DataFrame, peak_idx: int) -> DeclineShape:
    \"\"\"
    Classify how the stock declined from peak_idx to the most recent bar.
    Use 10-bar windows:
    - Any 10-bar window with max-to-min drop > 25% → VERTICAL_CLIFF
    - Decline spread over 8+ weeks with no single 10-bar drop > 15% → GRADUAL_ROUNDED
    - Otherwise → MIXED
    Import DeclineShape from cup_handle_model.
    \"\"\"

def stock_input_from_ticker(ticker: str) -> StockInput:
    \"\"\"
    Orchestrate all above functions to produce a StockInput.
    - peak_price: from compute_peak_price
    - current_price: last close
    - had_clear_prior_uptrend: True if last close > 200-day SMA, False otherwise
      (if fewer than 200 bars, use available data)
    - volume_drying_up_at_bottom: surge_ratio < 0.7
    - volume_picking_up_on_right_side: None (cannot determine from price history alone)
    - decline_shape: from classify_decline_shape using argmax of close as peak_idx
    - weeks_sideways_at_bottom: from compute_weeks_sideways
    - decline_reason: DeclineReason.UNKNOWN (cannot auto-detect)
    - fundamentals_score: 3 (neutral default; override manually)
    - sector_type: SectorType.CYCLICAL (default; override manually)
    \"\"\"
```

Include a `if __name__ == "__main__":` block that fetches MSFT and prints its StockInput.

Return the COMPLETE data_fetcher.py file — every line.
"""

PROMPT_INTEGRATION = """
You are integrating two Python modules into a single pipeline script.

Track A output (cup_handle_model_v2.py):
{code_a}

Track B output (data_fetcher.py):
{code_b}

## Task: Create pipeline.py

Write pipeline.py that:

1. Imports evaluate from cup_handle_model_v2 and stock_input_from_ticker from data_fetcher.
2. Defines run_pipeline(tickers: list[str]) -> list[ModelResult]:
   - For each ticker: call stock_input_from_ticker, then evaluate.
   - Skip and log a warning for any ticker that raises an exception.
   - Return sorted results by timing_score descending.
3. Defines print_report(result: ModelResult) -> None:
   - Uses ANSI color codes based on urgency:
       SKIP → no color, BUY → green (\\033[92m), SIGNAL → bright yellow (\\033[93m),
       ALERT → yellow (\\033[33m), WATCH → default (\\033[0m)
   - Prints: ticker, stage, depth_pct, probability, timing_score, urgency, entry_zones.
4. Defines a __main__ block that:
   - Runs run_pipeline(["MSFT", "AMZN", "JPM", "GOOGL", "WMT"])
   - Calls print_report for each result
   - Prints a summary ranking table.

Return the COMPLETE pipeline.py file — every line.
"""

# ---------------------------------------------------------------------------
# Core generation function
# ---------------------------------------------------------------------------

async def generate_code(
    client: anthropic.AsyncAnthropic,
    track: str,
    messages: list[dict],
) -> str:
    """Stream a code generation request; return the text content."""
    await aprint(f"[{track}] Generating... (streaming)")
    chars_received = 0

    async with client.messages.stream(
        model=MODEL,
        max_tokens=MAX_TOKENS_CODE,
        thinking={"type": "adaptive"},
        messages=messages,
    ) as stream:
        async for event in stream:
            if hasattr(event, "type") and event.type == "content_block_delta":
                delta = getattr(event, "delta", None)
                if delta and getattr(delta, "type", None) == "text_delta":
                    chars_received += len(delta.text)
                    if chars_received % 1000 < len(delta.text):
                        await aprint(f"[{track}]   ... {chars_received} chars received")

        final = await stream.get_final_message()

    code = "".join(
        b.text for b in final.content if getattr(b, "type", None) == "text"
    )
    await aprint(f"[{track}] Generation complete — {len(code)} chars")
    return code


# ---------------------------------------------------------------------------
# Quality evaluation function
# ---------------------------------------------------------------------------

async def evaluate_code(
    client: anthropic.AsyncAnthropic,
    track: str,
    code: str,
    rubric: str,
) -> QualityResult:
    """Evaluate generated code against a rubric; return QualityResult."""
    await aprint(f"[{track}] Evaluating quality...")

    eval_prompt = f"{rubric}\n\n---\n\nCode to evaluate:\n```python\n{code}\n```"

    response = await client.messages.create(
        model=MODEL,
        max_tokens=MAX_TOKENS_EVAL,
        messages=[{"role": "user", "content": eval_prompt}],
    )

    raw = response.content[0].text.strip()
    # Extract the first complete {...} JSON object regardless of surrounding text/fences.
    # This handles: bare JSON, ```json ... ```, and any leading/trailing prose.
    match = re.search(r'\{.*\}', raw, re.DOTALL)
    if not match:
        raise ValueError(f"[{track}] Evaluator returned no JSON object. Raw response:\n{raw[:500]}")
    data = json.loads(match.group())
    result = QualityResult(**data)
    status = "PASSED" if result.passed else f"FAILED ({len(result.issues)} issues)"
    await aprint(f"[{track}] Quality: {result.score:.2f} — {status}")
    if not result.passed:
        for issue in result.issues:
            await aprint(f"[{track}]   • {issue}")
    return result


# ---------------------------------------------------------------------------
# Track runner (generation → evaluation → refinement loop)
# ---------------------------------------------------------------------------

async def run_track(
    client: anthropic.AsyncAnthropic,
    track: str,
    initial_prompt: str,
    rubric: str,
    output_file: Path,
) -> tuple[str, bool]:
    """
    Run a full generation + evaluation + refinement cycle.
    Returns (final_code, passed).
    """
    messages: list[dict] = [{"role": "user", "content": initial_prompt}]

    for attempt in range(MAX_REFINEMENTS + 1):
        if attempt > 0:
            await aprint(f"[{track}] Refinement {attempt}/{MAX_REFINEMENTS}")

        code = await generate_code(client, track, messages)
        quality = await evaluate_code(client, track, code, rubric)

        if quality.passed:
            await aprint(f"[{track}] Accepted on attempt {attempt + 1}")
            output_file.write_text(code, encoding="utf-8")
            await aprint(f"[{track}] Written -> {output_file}")
            return code, True

        if attempt < MAX_REFINEMENTS:
            # Extend conversation with assistant reply + refinement request
            messages.append({"role": "assistant", "content": code})
            messages.append({
                "role": "user",
                "content": (
                    f"The code did not meet the quality threshold (score={quality.score:.2f}).\n"
                    f"Please fix the following issues and return the complete corrected file:\n\n"
                    f"{quality.refinement_instructions}"
                ),
            })

    # Max refinements reached — write best effort and warn
    await aprint(f"[{track}] WARNING: max refinements reached — writing best-effort output")
    output_file.write_text(code, encoding="utf-8")
    await aprint(f"[{track}] Written → {output_file}")
    return code, False


# ---------------------------------------------------------------------------
# Integration agent
# ---------------------------------------------------------------------------

async def run_integration(
    client: anthropic.AsyncAnthropic,
    code_a: str,
    code_b: str,
) -> Path:
    """Build pipeline.py from both track outputs."""
    out = OUT_DIR / "pipeline.py"
    prompt = PROMPT_INTEGRATION.format(code_a=code_a, code_b=code_b)
    messages = [{"role": "user", "content": prompt}]

    await aprint("[INTEGRATION] Building pipeline.py...")
    code = await generate_code(client, "INTEGRATION", messages)
    out.write_text(code, encoding="utf-8")
    await aprint(f"[INTEGRATION] Written -> {out}")
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main() -> None:
    await aprint("=" * 60)
    await aprint("Cup & Handle Orchestrator")
    await aprint(f"Model: {MODEL}  |  Max refinements: {MAX_REFINEMENTS}")
    await aprint(f"Output: {OUT_DIR}")
    await aprint("=" * 60)

    client = anthropic.AsyncAnthropic()

    # Run Track A and Track B in parallel
    (code_a, passed_a), (code_b, passed_b) = await asyncio.gather(
        run_track(
            client,
            track="A",
            initial_prompt=PROMPT_A,
            rubric=RUBRIC_A,
            output_file=OUT_DIR / "cup_handle_model_v2.py",
        ),
        run_track(
            client,
            track="B",
            initial_prompt=PROMPT_B,
            rubric=RUBRIC_B,
            output_file=OUT_DIR / "data_fetcher.py",
        ),
    )

    await aprint(f"\nTrack A: {'OK' if passed_a else 'best-effort'}")
    await aprint(f"Track B: {'OK' if passed_b else 'best-effort'}")

    if not passed_a or not passed_b:
        await aprint(
            "WARNING: One or more tracks did not fully pass quality checks. "
            "Integration may require manual review."
        )

    pipeline_path = await run_integration(client, code_a, code_b)

    await aprint("\n" + "=" * 60)
    await aprint("Done.")
    await aprint(f"  cup_handle_model_v2.py -> {OUT_DIR / 'cup_handle_model_v2.py'}")
    await aprint(f"  data_fetcher.py        -> {OUT_DIR / 'data_fetcher.py'}")
    await aprint(f"  pipeline.py            -> {pipeline_path}")
    await aprint(f"  log                    -> {LOG_FILE}")
    await aprint("=" * 60)


if __name__ == "__main__":
    asyncio.run(main())
