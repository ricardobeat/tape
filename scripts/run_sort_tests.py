#!/usr/bin/env python3
"""Run only sort tests."""
import sys, os, subprocess, select, time, glob
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
VM_BINARY = os.path.join(PROJECT_DIR, 'out/test262_runner')

# Find all sort test files
sort_dir = os.path.join(PROJECT_DIR, 'test262/test/built-ins/Array/prototype/sort')
tests = sorted(glob.glob(os.path.join(sort_dir, '*.js')))
print(f"Found {len(tests)} sort tests", file=sys.stderr)

# Use 4 workers
workers = []
for i in range(4):
    p = subprocess.Popen(
        [VM_BINARY, '--worker'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, bufsize=0)
    workers.append({'proc': p, 'pending': None, 'start': 0})

results = []
q = list(tests)
TIMEOUT = 8
t0 = time.monotonic()

while q or any(w['pending'] for w in workers):
    for w in workers:
        if w['proc'].poll() is None and w['pending'] is None and q:
            t = q.pop(0)
            w['pending'] = t
            w['start'] = time.monotonic()
            w['proc'].stdin.write((t + '\n').encode())
            w['proc'].stdin.flush()

    fds = [w['proc'].stdout.fileno() for w in workers
           if w['proc'].poll() is None and w['pending'] is not None]
    if fds:
        try:
            readable, _, _ = select.select(fds, [], [], 0.1)
        except (ValueError, OSError):
            readable = []
    else:
        readable = []
        time.sleep(0.05)

    for fd in readable:
        for w in workers:
            if w['proc'].poll() is None and w['proc'].stdout.fileno() == fd:
                line = w['proc'].stdout.readline()
                if not line: continue
                line = line.decode().strip()
                if line.startswith('PASS '):
                    results.append(('PASS', line[5:]))
                    w['pending'] = None
                elif line.startswith('FAIL '):
                    results.append(('FAIL', line[5:]))
                    w['pending'] = None
                break

    now = time.monotonic()
    for w in workers:
        if w['proc'].poll() is None and w['pending'] is not None:
            if now - w['start'] > TIMEOUT:
                results.append(('TIMEOUT', w['pending']))
                w['proc'].kill()
                w['proc'].wait()
                w['proc'] = subprocess.Popen(
                    [VM_BINARY, '--worker'],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, bufsize=0)
                w['pending'] = None

for w in workers:
    if w['proc'].poll() is None:
        w['proc'].kill()

p_count = sum(1 for r, _ in results if r == 'PASS')
f_count = sum(1 for r, _ in results if r == 'FAIL')
t_count = sum(1 for r, _ in results if r == 'TIMEOUT')
print(f"Total: PASS={p_count} FAIL={f_count} TIMEOUT={t_count} (of {len(tests)})")
print(f"Elapsed: {time.monotonic() - t0:.1f}s")

# Print fails
print("\nFails:")
for r, p in results:
    if r != 'PASS':
        print(f"  {r}  {os.path.basename(p)}")
