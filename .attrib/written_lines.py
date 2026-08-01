#!/usr/bin/env python3
"""Total lines WRITTEN per model (gross authorship), joined against surviving lines.

Written  = sum of insertions_source over that model's commits (on HEAD, merges
           excluded so a merge does not double-count its branch's work).
Surviving = git blame on HEAD (from blame_lines.py).

survival_rate = surviving / written. It is the share of a model's authored source
lines that are still present in the tree today. Low rates are normal in a repo
with this much rewriting, and a model whose work was later replaced still did the
work -- the two columns answer different questions.

Vendored libregexp is excluded from BOTH sides: its import commit's insertions
are dropped so a 9,936-line third-party import does not inflate whoever ran it.
"""
import json
from collections import Counter, defaultdict

OUT = '/Users/rtomasi/cousas/duktape-c3/.attrib'
log = json.load(open(f'{OUT}/commit_log.json'))
blame = json.load(open(f'{OUT}/line_attribution.json'))

VENDORED_PREFIXES = ('libregexp/',)

written = Counter()
deleted = Counter()
commits = Counter()
written_by_harness = Counter()
written_by_quality = Counter()
written_by_cat = defaultdict(Counter)
vendored_written = Counter()

for c in log['commits']:
    if not c.get('on_head'):
        continue
    if c.get('is_merge'):
        continue  # merge commits re-report their branch's lines
    a = c['attribution']
    model = a.get('model') or 'unattributed'

    add = dele = vend = 0
    for f in c['files']:
        if not f.get('is_source'):
            continue
        p = f['path']
        ai = f.get('added') or 0
        di = f.get('deleted') or 0
        if p.startswith(VENDORED_PREFIXES):
            vend += ai
            continue
        add += ai
        dele += di

    if add or dele:
        written[model] += add
        deleted[model] += dele
        commits[model] += 1
        written_by_harness[a.get('harness') or 'unknown'] += add
        written_by_quality[a.get('attribution_quality') or 'none'] += add
        written_by_cat[c.get('category') or 'other'][model] += add
    if vend:
        vendored_written[model] += vend

surviving = blame['by_model']

rows = []
for model in sorted(set(written) | set(surviving), key=lambda m: -written.get(m, 0)):
    w = written.get(model, 0)
    s = surviving.get(model, 0)
    rows.append({
        'model': model,
        'commits': commits.get(model, 0),
        'lines_written': w,
        'lines_deleted': deleted.get(model, 0),
        'net_lines': w - deleted.get(model, 0),
        'lines_surviving': s,
        'survival_rate': round(s / w, 4) if w else None,
        'share_of_written': round(w / sum(written.values()), 4) if written else 0,
        'share_of_surviving': round(s / sum(surviving.values()), 4) if surviving else 0,
    })

doc = {
    'note': ('lines_written = insertions on source files, on-HEAD non-merge commits. '
             'lines_surviving = git blame HEAD. survival_rate = surviving/written. '
             'Vendored libregexp excluded from both.'),
    'totals': {
        'lines_written': sum(written.values()),
        'lines_deleted': sum(deleted.values()),
        'lines_surviving': sum(surviving.values()),
        'overall_survival_rate': round(sum(surviving.values()) / sum(written.values()), 4),
        'vendored_written_excluded': sum(vendored_written.values()),
    },
    'by_model': rows,
    'written_by_harness': dict(written_by_harness.most_common()),
    'written_by_quality': dict(written_by_quality.most_common()),
    'written_by_category': {k: dict(v.most_common()) for k, v in written_by_cat.items()},
}
json.dump(doc, open(f'{OUT}/line_totals.json', 'w'), indent=1)

T = doc['totals']
print(f"written {T['lines_written']:,} | deleted {T['lines_deleted']:,} | "
      f"surviving {T['lines_surviving']:,} | overall survival {100*T['overall_survival_rate']:.1f}%\n")
print(f"{'model':28} {'commits':>7} {'written':>9} {'surviving':>10} {'survive%':>9}")
for r in rows[:22]:
    sr = f"{100*r['survival_rate']:.1f}%" if r['survival_rate'] is not None else '-'
    print(f"{r['model']:28} {r['commits']:7} {r['lines_written']:9,} {r['lines_surviving']:10,} {sr:>9}")
print('\n-- written by harness --')
for k, v in doc['written_by_harness'].items():
    print(f'  {k:14} {v:9,}  {100*v/T["lines_written"]:5.1f}%')
