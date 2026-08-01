#!/usr/bin/env python3
"""Credit the founding commits to Shelley (exe.dev).

The first six commits of the project carry an explicit
`Co-authored-by: Shelley <shelley@exe.dev>` trailer and were authored by
`exe.dev user <exedev@emerald-victory.exe.xyz>`, not by Ricardo. My original
trailer parser only recognised model-shaped Co-Authored-By values (Claude Opus,
MiniMax-M3 and so on) and treated a bare human-style name as prose to ignore, so
these fell through every evidence path and were later swept into the
by-elimination "pi" bucket.

That mattered: those six commits include the initial 4,500-line port, so the
whole founding scaffold was credited to the wrong harness.

Shelley is an agent product (exe.dev), not a model, so it is recorded as its own
harness with the model left unidentified. Evidence quality is 'high' because the
trailer is explicit, unlike the pi rows which are inference from absence.
"""
import json, subprocess, re
from collections import Counter

OUT = '/Users/rtomasi/cousas/duktape-c3/.attrib'
REPO = '/Users/rtomasi/cousas/duktape-c3'

log = json.load(open(f'{OUT}/commit_log.json'))

# Find every commit whose body names Shelley, or whose author is the exe.dev bot.
raw = subprocess.run(
    ['git', '-C', REPO, 'log', '--all', '--format=%H%x1f%ae%x1f%b%x1e'],
    capture_output=True, text=True).stdout

shelley = set()
for rec in raw.split('\x1e'):
    parts = rec.split('\x1f')
    if len(parts) < 3:
        continue
    sha, email, body = parts[0].strip(), parts[1], parts[2]
    if re.search(r'shelley@exe\.dev', body, re.I) or 'exe.xyz' in email:
        shelley.add(sha)

changed = Counter()
for c in log['commits']:
    if c['sha'] not in shelley:
        continue
    a = c['attribution']
    changed[a.get('harness') or 'none'] += 1
    a['harness'] = 'shelley'
    a['model'] = 'shelley (exe.dev)'
    a['vendor'] = 'exe.dev'
    a['method'] = 'trailer'
    a['confidence'] = 1.0
    a['attribution_quality'] = 'high'
    a['inferred_by_elimination'] = False
    a['span_note'] = 'Co-authored-by: Shelley <shelley@exe.dev>'

log['quality_counts'] = dict(Counter(c['attribution'].get('attribution_quality')
                                     for c in log['commits']))
log['method_counts'] = dict(Counter(c['attribution'].get('method') for c in log['commits']))
json.dump(log, open(f'{OUT}/commit_log.json', 'w'), indent=1, default=str)

head = [c for c in log['commits'] if c.get('on_head')]
sh = [c for c in head if c['attribution'].get('harness') == 'shelley']
print(f'{len(shelley)} Shelley commits found, reattributed from: {dict(changed)}')
print(f'on HEAD: {len(sh)} commits, '
      f'{sum(c["insertions_source"] for c in sh):,} source lines written')
for c in sh:
    print(f'   {c["short_sha"]} {c["author_date"][:10]} +{c["insertions_source"]:5} {c["subject"][:52]}')
