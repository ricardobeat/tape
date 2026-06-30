#!/usr/bin/env python3
"""Capture failing test paths for a phase so we can analyze the failure pattern."""
import os
import subprocess
import sys
import time
import select
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
TEST262_DIR = os.path.join(PROJECT_DIR, "test262", "test")
VM_BINARY = os.path.join(PROJECT_DIR, "out", "batch_test_vm")

PHASE_DIRS = {
    3: [
        "language/expressions/object", "language/expressions/array",
        "language/expressions/member-expression",
        "language/expressions/property-accessors",
        "built-ins/Object", "built-ins/Array", "built-ins/Array/length",
    ],
    5: [
        "built-ins/Boolean", "built-ins/String", "built-ins/Number",
        "built-ins/Object", "built-ins/Array", "built-ins/Function",
    ],
    6: [
        "built-ins/Math", "built-ins/String/prototype",
        "built-ins/Array/prototype", "built-ins/Number/prototype",
        "built-ins/Boolean/prototype", "built-ins/Function/prototype",
    ],
    8: [
        "built-ins/JSON", "built-ins/Date", "built-ins/RegExp",
        "built-ins/parseInt", "built-ins/parseFloat",
    ],
    17: [
        "built-ins/Map", "built-ins/Set", "built-ins/Symbol", "built-ins/Promise",
        "built-ins/WeakMap", "built-ins/WeakSet",
    ],
}

SKIP_DIRS = {
    "annexB", "intl402", "staging", "harness",
    "built-ins/Temporal", "built-ins/ShadowRealm",
    "built-ins/DisposableStack", "built-ins/AsyncDisposableStack",
    "built-ins/SuppressedError", "built-ins/AbstractModuleSource",
    "built-ins/SharedArrayBuffer", "built-ins/Atomics",
    "built-ins/Proxy", "built-ins/WeakRef",
    "built-ins/FinalizationRegistry", "built-ins/BigInt",
}

UNSUPPORTED_PATTERN = re.compile(
    r"features:\s*\[.*\b(?:"
    r"proxy|BigInt|async|module|"
    r"Reflect|SharedArrayBuffer|Atomics|Intl|"
    r"TypedArray|DataView|Float32Array|Float64Array|Int8Array|Int16Array|"
    r"Int32Array|Uint8Array|Uint16Array|Uint32Array|Uint8ClampedArray|"
    r"FinalizationRegistry|WeakRef|structured-clone|import\.meta|"
    r"dynamic-import|"
    r"class-methods-private|class-static-methods-private|"
    r"class-fields-private|class-fields-public|"
    r"class-static-fields-private|class-static-fields-public|"
    r"class-static-block|"
    r"object-rest|explicit-resource-management|"
    r"logical-assignment|resizable-arraybuffer|"
    r"array-grouping|upsert|set-methods|"
    r"symbols-as-weakmap-keys|cross-realm|"
    r"await-dictionary"
    r")\b"
)

# Strict-only engine: tests that expect non-strict behavior (no flags:
# [noStrict] but their body relies on sloppy-mode-only features) — listed
# explicitly since they have no metadata to match.
SKIP_FILES = {
    "built-ins/Function/15.3.2.1-11-1.js",
    "built-ins/Function/15.3.2.1-11-3.js",
    "built-ins/Function/15.3.2.1-11-5.js",
    "built-ins/Function/15.3.2.1-11-9-s.js",
    "built-ins/Date/prop-desc.js",
}


def should_skip(path):
    rel = os.path.relpath(path, TEST262_DIR)
    for skip_dir in SKIP_DIRS:
        if rel.startswith(skip_dir + os.sep):
            return True
    if rel in SKIP_FILES:
        return True
    try:
        with open(path) as f:
            header = f.read(2000)
    except OSError:
        return True
    if "$DONOTEVALUATE" in header:
        return True
    if UNSUPPORTED_PATTERN.search(header):
        return True
    if re.search(r"flags:\s*\[.*\bnoStrict\b", header):
        return True
    return False


def collect_tests(phase):
    tests = []
    for rel_dir in PHASE_DIRS[phase]:
        full = os.path.join(TEST262_DIR, rel_dir)
        if not os.path.isdir(full):
            continue
        for dirpath, _dirnames, filenames in os.walk(full):
            for entry in filenames:
                if not entry.endswith(".js"):
                    continue
                path = os.path.join(dirpath, entry)
                if should_skip(path):
                    continue
                tests.append(path)
    return tests


def run_phase_capture(phase, num_workers=3, timeout_s=10):
    tests = collect_tests(phase)
    print(f"Phase {phase}: {len(tests)} tests to run", file=sys.stderr)

    workers = []
    for i in range(num_workers):
        p = subprocess.Popen(
            [VM_BINARY, "--worker"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
        )
        workers.append({"proc": p, "pending": None, "start": 0, "buf": b""})

    fails = []
    test_q = list(tests)
    next_w = 0

    while test_q or any(w["pending"] for w in workers):
        for w in workers:
            if w["proc"].poll() is None and w["pending"] is None and test_q:
                t = test_q.pop(0)
                w["pending"] = t
                w["start"] = time.monotonic()
                w["proc"].stdin.write((t + "\n").encode())
                w["proc"].stdin.flush()

        fds = [w["proc"].stdout.fileno() for w in workers
               if w["proc"].poll() is None and w["pending"] is not None]
        if fds:
            try:
                readable, _, _ = select.select(fds, [], [], 0.1)
            except (ValueError, OSError):
                readable = []
        else:
            readable = []

        for fd in readable:
            for w in workers:
                if w["proc"].poll() is None and w["proc"].stdout.fileno() == fd:
                    line = w["proc"].stdout.readline()
                    if not line:
                        continue
                    line = line.decode().strip()
                    if line.startswith("PASS "):
                        w["pending"] = None
                    elif line.startswith("FAIL "):
                        fails.append(line[5:])
                        w["pending"] = None
                    break

        # Timeout check
        now = time.monotonic()
        for w in workers:
            if w["proc"].poll() is None and w["pending"] is not None:
                if now - w["start"] > timeout_s:
                    fails.append(f"TIMEOUT: {w['pending']}")
                    w["proc"].kill()
                    w["proc"].wait()
                    w["proc"] = subprocess.Popen(
                        [VM_BINARY, "--worker"],
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        bufsize=0,
                    )
                    w["pending"] = None

    for w in workers:
        if w["proc"].poll() is None:
            w["proc"].kill()

    for f in sorted(fails):
        print(f)
    print(f"---", file=sys.stderr)
    print(f"Total fails: {len(fails)}", file=sys.stderr)


if __name__ == "__main__":
    phase = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    out_path = sys.argv[2] if len(sys.argv) > 2 else f"/tmp/fails_phase{phase}.txt"
    old = sys.stdout
    with open(out_path, "w") as f:
        sys.stdout = f
        run_phase_capture(phase)
    sys.stdout = old
    print(f"Wrote fails to {out_path}")
