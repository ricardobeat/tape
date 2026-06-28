#!/usr/bin/env python3
"""Run a phase and dump fail paths."""
import sys, os, subprocess, select, time, argparse
from collections import defaultdict

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(PROJECT_DIR, 'scripts'))
import run_test262

parser = argparse.ArgumentParser()
parser.add_argument("phase", type=int)
parser.add_argument("--workers", type=int, default=3)
parser.add_argument("--timeout", type=int, default=8)
args = parser.parse_args()

phase_idx = run_test262.resolve_phase_num(args.phase)
tests, skipped = run_test262.build_phase_tests(phase_idx, es5_only=False)
print(f"Phase {args.phase}: {len(tests)} tests, {skipped} skipped", file=sys.stderr)

workers = []
for i in range(args.workers):
    p = subprocess.Popen(
        [os.path.join(PROJECT_DIR, 'out/batch_test_vm'), '--worker'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, bufsize=0)
    workers.append({'proc': p, 'pending': None, 'start': 0})

results = []
q = list(tests)
t0 = time.monotonic()

while q or any(w['pending'] for w in workers):
    for w in workers:
        if w['proc'].poll() is None and w['pending'] is None and q:
            t = q.pop(0)
            w['pending'] = t
            w['start'] = time.monotonic()
            try:
                w['proc'].stdin.write((t + '\n').encode())
                w['proc'].stdin.flush()
            except (BrokenPipeError, OSError):
                pass  # worker died; will be caught in dead-worker check below

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
                elif line.startswith('COMPILE_ERROR '):
                    results.append(('PASS', line[14:]))
                    w['pending'] = None
                elif line.startswith('FAIL '):
                    results.append(('FAIL', line[5:]))
                    w['pending'] = None
                break

    now = time.monotonic()
    for w in workers:
        if w['pending'] is not None:
            if w['proc'].poll() is not None:
                # Worker crashed — record failure and restart
                results.append(('FAIL', w['pending']))
                w['proc'] = subprocess.Popen(
                    [os.path.join(PROJECT_DIR, 'out/batch_test_vm'), '--worker'],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, bufsize=0)
                w['pending'] = None
            elif now - w['start'] > args.timeout:
                results.append(('TIMEOUT', w['pending']))
                w['proc'].kill()
                w['proc'].wait()
                w['proc'] = subprocess.Popen(
                    [os.path.join(PROJECT_DIR, 'out/batch_test_vm'), '--worker'],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL, bufsize=0)
                w['pending'] = None

for w in workers:
    if w['proc'].poll() is None:
        w['proc'].kill()

fails_by_dir = defaultdict(list)
for r, p in results:
    if r != 'PASS':
        rel = p.split('test262/test/')[-1]
        parts = rel.split('/')
        key = '/'.join(parts[:2]) if len(parts) > 2 else rel
        fails_by_dir[key].append((r, p))

for k, v in sorted(fails_by_dir.items(), key=lambda x: -len(x[1])):
    print(f"{len(v):5d}  {k}")

p_count = sum(1 for r, _ in results if r == 'PASS')
f_count = sum(1 for r, _ in results if r == 'FAIL')
t_count = sum(1 for r, _ in results if r == 'TIMEOUT')
print()
print(f"Total: PASS={p_count} FAIL={f_count} TIMEOUT={t_count} (of {len(tests)})")

out_path = f'/tmp/phase{args.phase}_fails.txt'
with open(out_path, 'w') as f:
    for r, p in results:
        if r != 'PASS':
            f.write(f'{r} {p}\n')
print(f'Wrote fails to {out_path}', file=sys.stderr)
print(f'Elapsed: {time.monotonic() - t0:.1f}s', file=sys.stderr)
