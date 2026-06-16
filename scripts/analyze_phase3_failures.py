#!/usr/bin/env python3
"""Analyze phase 3 test262 failures, grouped by root cause keyword.

Groups failing tests by keyword patterns found in their path so we can
identify which areas of the object system need the most attention.

Usage:
    python3 scripts/analyze_phase3_failures.py            # Run fresh
    python3 scripts/analyze_phase3_failures.py --cached   # Use cached /tmp/phase3_fails.txt
"""

import sys
import os
import subprocess
import re
import json
import argparse
from collections import Counter, defaultdict

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── Classification patterns ────────────────────────────────────────────────
# Each entry: (display_label, [list of substrings to match in lowercased path])
# Order matters — first match wins, so put more specific patterns first.
CLASSIFIERS = [
    ("GOPD", ["getownpropertydescriptor", "gopd"]),
    ("defineProperty", ["defineproperty"]),
    ("preventExtensions", ["preventextensions"]),
    ("seal/freeze", ["seal", "freez", "frozen", "issealed", "isfrozen"]),
    ("writable", ["writable"]),
    ("configurable", ["configurable"]),
    ("enumerable", ["enumerable"]),
    ("Array", ["/array/"]),
]


def classify(path: str) -> str:
    """Classify a test path into a root-cause category.

    Returns the label of the first matching classifier, or 'Other'.
    """
    lower = path.lower()
    for label, keywords in CLASSIFIERS:
        for kw in keywords:
            if kw in lower:
                return label
    return "Other"


# ── Data sources ───────────────────────────────────────────────────────────

FAILS_CACHE = "/tmp/phase3_fails.txt"


def run_phase3() -> tuple[str, str, int]:
    """Run *phase_runner.py 3* and return (stdout, stderr, returncode)."""
    phase_runner = os.path.join(PROJECT_DIR, "scripts", "phase_runner.py")
    proc = subprocess.run(
        [sys.executable, phase_runner, "3"],
        capture_output=True,
        text=True,
        cwd=PROJECT_DIR,
        timeout=600,  # 10-minute safety limit
    )
    return proc.stdout, proc.stderr, proc.returncode


def read_fails_file(path: str = FAILS_CACHE) -> list[tuple[str, str]]:
    """Read (status, test_path) pairs from the fails file phase_runner writes.

    Expected format per line:
        FAIL /full/path/to/test.js
        TIMEOUT /full/path/to/test.js
    """
    if not os.path.isfile(path):
        return []
    fails: list[tuple[str, str]] = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("FAIL "):
                fails.append(("FAIL", line[5:].strip()))
            elif line.startswith("TIMEOUT "):
                fails.append(("TIMEOUT", line[8:].strip()))
    return fails


def parse_summary(stdout: str) -> dict | None:
    """Extract pass/fail/timeout counts from the 'Total:' line in stdout.

    Expected format:
        Total: PASS=123 FAIL=456 TIMEOUT=0 (of 579)
    """
    for line in stdout.splitlines():
        if line.startswith("Total:"):
            m = re.match(
                r"Total:\s*PASS=(\d+)\s+FAIL=(\d+)\s+TIMEOUT=(\d+)",
                line,
            )
            if m:
                return {
                    "pass": int(m.group(1)),
                    "fail": int(m.group(2)),
                    "timeout": int(m.group(3)),
                }
    return None


def relpath(p: str) -> str:
    """Strip the absolute prefix to get a concise relative path."""
    if "test262/test/" in p:
        return p.split("test262/test/", 1)[1]
    # Already relative or a different prefix — use as-is
    return p


# ── Main ───────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Analyze phase 3 test262 failures grouped by root cause."
    )
    parser.add_argument(
        "--cached",
        action="store_true",
        help=(
            "Use cached /tmp/phase3_fails.txt instead of re-running "
            "the full phase 3 test suite."
        ),
    )
    args = parser.parse_args()

    summary = None

    # ── Obtain failure list ───────────────────────────────────────────────
    if args.cached and os.path.isfile(FAILS_CACHE):
        fails = read_fails_file()
        print("Using cached results from " + FAILS_CACHE, file=sys.stderr)
    else:
        print("Running phase 3 tests (this may take a while)...", file=sys.stderr)
        try:
            stdout, stderr, rc = run_phase3()
        except subprocess.TimeoutExpired:
            print("ERROR: phase_runner timed out after 10 minutes", file=sys.stderr)
            fails = read_fails_file()
            if not fails:
                print("No cached results available either.", file=sys.stderr)
                return 1
        else:
            # phase_runner writes the fails file on completion
            fails = read_fails_file()
            summary = parse_summary(stdout)
            if not summary:
                print("Warning: could not parse summary line from stdout",
                      file=sys.stderr)

        if not fails:
            # One last fallback
            fails = read_fails_file()

    if not fails:
        print("No failures found — all phase 3 tests passed!", file=sys.stderr)
        _save_results([], {}, None)
        return 0

    # ── Aggregate ─────────────────────────────────────────────────────────
    total = len(fails)
    fail_count = sum(1 for s, _ in fails if s == "FAIL")
    timeout_count = sum(1 for s, _ in fails if s == "TIMEOUT")

    groups: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for status, path in fails:
        cat = classify(path)
        groups[cat].append((status, path))

    cat_counts = {cat: len(items) for cat, items in groups.items()}

    # Path frequency (using relative paths for output)
    path_counts: Counter[str] = Counter(relpath(p) for _, p in fails)
    top_n = 5
    top_failures = path_counts.most_common(top_n)

    # ── Print summary ────────────────────────────────────────────────────
    defined_order = [c[0] for c in CLASSIFIERS]
    sorted_cats = sorted(
        cat_counts,
        key=lambda x: (defined_order.index(x) if x in defined_order else 999, x),
    )

    header = "Phase 3 Failure Analysis"
    print()
    print(header)
    print("=" * len(header))
    print(f"Total failures: {total}  (FAIL={fail_count}, TIMEOUT={timeout_count})")
    if summary:
        print(
            f"Overall: PASS={summary['pass']}  "
            f"FAIL={summary['fail']}  "
            f"TIMEOUT={summary['timeout']}"
        )
    print()

    if sorted_cats:
        max_label_len = max(len(c) for c in sorted_cats)
        print("By root cause:")
        for cat in sorted_cats:
            count = cat_counts[cat]
            print(f"  {cat + ':':<{max_label_len + 1}} {count:>4}")
        print()

    print(f"Top {top_n} failures by frequency:")
    for path, count in top_failures:
        print(f"  {path} : {count} occurrence{'s' if count != 1 else ''}")
    print()

    # ── Save JSON ─────────────────────────────────────────────────────────
    out_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "phase3_failures.json"
    )
    data = {
        "total": total,
        "fail": fail_count,
        "timeout": timeout_count,
        "by_category": {cat: cat_counts.get(cat, 0) for cat in sorted_cats},
        "top_failures": [{"path": p, "count": c} for p, c in top_failures],
        "failures": [
            {"status": s, "path": p, "category": classify(p)}
            for s, p in fails
        ],
    }
    with open(out_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Saved grouped results to {out_path}", file=sys.stderr)

    return 1 if total > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
