"""
Smoke test for orchestrator.py.

Tests three things without running the full pipeline:
  1. generate_code — streaming with adaptive thinking returns non-empty text
  2. evaluate_code — JSON evaluation parses into QualityResult correctly
  3. run_track    — generation + evaluation + (optional) refinement loop
                    using a tiny prompt and rubric so the loop terminates fast

Run:
    python test_orchestrator.py
"""

import asyncio
import json
import sys
from pathlib import Path

# Patch OUT_DIR before importing so no 'generated/' output is created during tests
import orchestrator
orchestrator.OUT_DIR = Path(__file__).parent / "test_output"
orchestrator.OUT_DIR.mkdir(exist_ok=True)

from orchestrator import (
    generate_code,
    evaluate_code,
    run_track,
    QualityResult,
    aprint,
)
import anthropic


# ---------------------------------------------------------------------------
# Minimal test rubric — expects exactly one function named `add`
# ---------------------------------------------------------------------------

MINI_RUBRIC = """
Evaluate the Python code below.
Return a JSON object matching this schema exactly — no markdown, no explanation:
{
  "score": <float 0.0–1.0>,
  "passed": <bool>,
  "issues": [<string>, ...],
  "refinement_instructions": <string>
}

Scoring criteria (each worth 0.5):
1. There is a function named `add` that takes two arguments.
2. The function returns the sum of its two arguments.

Set passed=True if score >= 0.85.
Return ONLY the JSON object.
"""

MINI_PROMPT = "Write a Python function named `add` that takes two numbers and returns their sum. Return only the complete Python file."

GOOD_CODE = "def add(a, b):\n    return a + b\n"
BAD_CODE  = "def multiply(a, b):\n    return a * b\n"


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

PASS  = "\033[92mPASS\033[0m"
FAIL  = "\033[91mFAIL\033[0m"
results: list[tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str = "") -> None:
    tag = PASS if ok else FAIL
    print(f"  [{tag}] {name}" + (f" — {detail}" if detail else ""))
    results.append((name, ok, detail))


# ---------------------------------------------------------------------------
# Test 1: evaluate_code — good code should pass
# ---------------------------------------------------------------------------

async def test_evaluate_good(client: anthropic.AsyncAnthropic) -> None:
    print("\n[TEST 1] evaluate_code with passing code")
    result = await evaluate_code(client, "TEST", GOOD_CODE, MINI_RUBRIC)
    record("returns QualityResult", isinstance(result, QualityResult))
    record("score is float in [0,1]", isinstance(result.score, float) and 0.0 <= result.score <= 1.0,
           f"score={result.score:.2f}")
    record("good code passes (score >= 0.85)", result.passed,
           f"score={result.score:.2f}, issues={result.issues}")


# ---------------------------------------------------------------------------
# Test 2: evaluate_code — bad code should fail
# ---------------------------------------------------------------------------

async def test_evaluate_bad(client: anthropic.AsyncAnthropic) -> None:
    print("\n[TEST 2] evaluate_code with failing code")
    result = await evaluate_code(client, "TEST", BAD_CODE, MINI_RUBRIC)
    record("returns QualityResult", isinstance(result, QualityResult))
    record("bad code does not pass", not result.passed,
           f"score={result.score:.2f}")
    record("has at least one issue", len(result.issues) >= 1,
           f"issues={result.issues}")
    record("refinement_instructions non-empty", len(result.refinement_instructions) > 0)


# ---------------------------------------------------------------------------
# Test 3: generate_code — streaming returns non-empty text
# ---------------------------------------------------------------------------

async def test_generate(client: anthropic.AsyncAnthropic) -> None:
    print("\n[TEST 3] generate_code — streaming with adaptive thinking")
    messages = [{"role": "user", "content": MINI_PROMPT}]
    code = await generate_code(client, "TEST", messages)
    record("returns non-empty string", isinstance(code, str) and len(code) > 0,
           f"{len(code)} chars")
    record("contains 'def add'", "def add" in code)


# ---------------------------------------------------------------------------
# Test 4: run_track — full loop with a trivial prompt
# ---------------------------------------------------------------------------

async def test_run_track(client: anthropic.AsyncAnthropic) -> None:
    print("\n[TEST 4] run_track — generation + evaluation loop")
    out = orchestrator.OUT_DIR / "test_add.py"
    code, passed = await run_track(
        client,
        track="TEST",
        initial_prompt=MINI_PROMPT,
        rubric=MINI_RUBRIC,
        output_file=out,
    )
    record("returns (str, bool)", isinstance(code, str) and isinstance(passed, bool))
    record("output file written", out.exists(), str(out))
    record("passed (simple task should pass)", passed)


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

async def main() -> None:
    print("=" * 55)
    print("  orchestrator.py smoke test")
    print("=" * 55)

    client = anthropic.AsyncAnthropic()

    await test_evaluate_good(client)
    await test_evaluate_bad(client)
    await test_generate(client)
    await test_run_track(client)

    total  = len(results)
    passed = sum(1 for _, ok, _ in results if ok)
    failed = total - passed

    print(f"\n{'='*55}")
    print(f"  Results: {passed}/{total} passed", end="")
    if failed:
        print(f"  ({failed} FAILED)", end="")
    print()
    print("=" * 55)

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
