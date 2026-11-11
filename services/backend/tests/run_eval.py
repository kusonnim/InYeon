import os
import json
import sys
import time
import asyncio
from pathlib import Path

CURRENT_DIR = Path(__file__).resolve().parent
BACKEND_DIR = CURRENT_DIR.parent
sys.path.insert(0, str(BACKEND_DIR))

from extractors.ai_extractor import analyze_content_async, ExtractionResult

async def evaluate_single_case(case: dict) -> dict:
    cid = case["id"]
    title = case["title"]
    cat = case["category"]
    user_input = case["input"]

    output: ExtractionResult = await analyze_content_async(user_input)

    status = output.status
    summary = output.summary
    actions = output.recommendations.action

    is_pass = True
    fail_reasons = []

    # 1. Check status match
    if status != case["expected_status"]:
        is_pass = False
        fail_reasons.append(f"Status mismatch (Expected: {case['expected_status']}, Got: {status})")

    # 2. Check action existence logic
    if case["should_have_action"] and len(actions) == 0:
        is_pass = False
        fail_reasons.append("Failed to extract required action")
    elif not case["should_have_action"] and len(actions) > 0:
        is_pass = False
        fail_reasons.append("Generated invalid artificial action for casual/info post")

    # 3. Check ground truth keywords in summary
    for kw in case.get("must_include_keywords", []):
        if kw not in summary:
            is_pass = False
            fail_reasons.append(f"Missing required keyword '{kw}' in summary")

    return {
        "id": cid,
        "category": cat,
        "title": title,
        "is_pass": is_pass,
        "reasons": fail_reasons
    }

async def main():
    fixture_path = CURRENT_DIR / "fixtures" / "test_cases.json"
    if not fixture_path.exists():
        print(f"❌ Fixture file not found: {fixture_path}")
        return

    with open(fixture_path, "r", encoding="utf-8") as f:
        test_cases = json.load(f)


    print(f"🚀 ITDA Evaluation Started ({len(test_cases)} sequential test cases)")
    print("=" * 70)

    start_time = time.time()
    results = []

    for i, case in enumerate(test_cases, 1):
        print(f"\n[{i}/{len(test_cases)}] 테스트 진행 중...")
        result = await evaluate_single_case(case)
        results.append(result)

        if i < len(test_cases):
            await asyncio.sleep(2)


    elapsed_time = time.time() - start_time
    passed_count = sum(1 for r in results if r["is_pass"])

    for r in results:
        symbol = "✅ PASS" if r["is_pass"] else "❌ FAIL"
        print(f"[{symbol}] {r['id']} | {r['category']:10} | {r['title']}")
        if not r["is_pass"]:
            print(f" └─ Reasons: {', '.join(r['reasons'])}")

    print("=" * 70)
    pass_rate = (passed_count / len(test_cases) * 100) if test_cases else 0
    print(f"📊 Final Evaluation Summary: {passed_count}/{len(test_cases)} Passed ({pass_rate:.1f}%)")
    print(f"⚡ Total Execution Time: {elapsed_time:.2f} seconds")

if __name__ == "__main__":
    asyncio.run(main())