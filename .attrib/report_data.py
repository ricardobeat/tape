#!/usr/bin/env python3
"""Build the single JSON payload the HTML report embeds.

Commit counts here are SOURCE-ONLY: a commit counts only if it changed a file
classified is_source (engine, cli, scripts, libregexp) -- docs/backlog/progress
churn is excluded, since 401 of 1775 on-HEAD non-merge commits touch no code at
all and would otherwise flatter whoever wrote the most markdown.
"""
import json, subprocess
from collections import Counter, defaultdict

OUT = '/Users/rtomasi/cousas/duktape-c3/.attrib'

log = json.load(open(f'{OUT}/commit_log.json'))
lines = json.load(open(f'{OUT}/line_attribution.json'))
totals = json.load(open(f'{OUT}/line_totals.json'))
sess = json.load(open(f'{OUT}/session_activity.json'))
toks = json.load(open(f'{OUT}/token_totals.json'))
costs = json.load(open(f'{OUT}/cost_estimates.json'))
activity = json.load(open(f'{OUT}/activity_weekly.json'))
loops = json.load(open(f'{OUT}/loops.json'))
try:
    narr = json.load(open(f'{OUT}/narrative.json'))
except Exception:
    narr = {'bugs': [], 'decisions': []}

head = [c for c in log['commits'] if c.get('on_head')]
nonmerge = [c for c in head if not c.get('is_merge')]


def is_src(c):
    return any(f.get('is_source') for f in c['files'])


src = [c for c in nonmerge if is_src(c)]
docs_only = [c for c in nonmerge if not is_src(c)]

MODEL = lambda c: c['attribution'].get('model') or 'unattributed'
# 'unknown' in the timeline bar folds into pi: by elimination it is the harness
# with no local session store. (Line and token credit is unaffected; the vendored
# libregexp import is still excluded from per-model totals elsewhere.)
HARNESS = lambda c: c['attribution'].get('harness') or 'pi'

# ---- per-model rollup (source-only commits) -------------------------------
surv = lines['by_model']
written = Counter()
for c in src:
    written[MODEL(c)] += sum(
        (f.get('added') or 0) for f in c['files']
        if f.get('is_source') and not f['path'].startswith('libregexp/'))

sess_by_model = {r['model']: r for r in sess['by_model']}
tot_by_model = {r['model']: r for r in totals['by_model']}
tok_by_model = {r['model']: r for r in toks['by_model']}
cost_by_model = {r['model']: r for r in costs['by_model']}

models = []
for m in sorted(set(written) | set(surv), key=lambda x: -surv.get(x, 0)):
    s = sess_by_model.get(m, {})
    t = tot_by_model.get(m, {})
    k = tok_by_model.get(m, {})
    models.append({
        'tokens_out': k.get('tokens_out', 0),
        'tokens_fresh_in': k.get('tokens_fresh_in', 0),
        'tokens_cache_in': k.get('tokens_cache_in', 0),
        'out_per_msg': k.get('out_per_msg', 0),
        'tok_per_written': k.get('tokens_per_written_line'),
        'tok_per_surviving': k.get('tokens_per_surviving_line'),
        'cost_usd': (cost_by_model.get(m) or {}).get('cost_best'),
        'cost_recorded': (cost_by_model.get(m) or {}).get('cost_recorded'),
        'cost_estimated': (cost_by_model.get(m) or {}).get('cost_estimated'),
        'cost_basis': (cost_by_model.get(m) or {}).get('cost_basis'),
        'model': m,
        'vendor': (t.get('vendor') or ''),
        'commits_source': sum(1 for c in src if MODEL(c) == m),
        'commits_all': sum(1 for c in nonmerge if MODEL(c) == m),
        'lines_written': written.get(m, 0),
        'lines_surviving': surv.get(m, 0),
        'survival': round(surv.get(m, 0) / written[m], 3) if written.get(m) else None,
        'sessions': s.get('sessions', 0),
        'messages': s.get('assistant_messages', 0),
        'hours': s.get('active_hours', 0),
        'first': (t.get('first_commit') or (s.get('first_seen') or '')[:10]),
        'last': (t.get('last_commit') or (s.get('last_seen') or '')[:10]),
        'harnesses': s.get('harnesses', []),
        'quality_high': None,
    })

# share of surviving code
TS = sum(surv.values()) or 1
for m in models:
    m['pct_codebase'] = round(100 * m['lines_surviving'] / TS, 2)

# ---- timelines ------------------------------------------------------------
by_week = defaultdict(lambda: defaultdict(int))
for c in src:
    wk = c['author_date'][:10]
    by_week[wk][MODEL(c)] += 1

cum = defaultdict(int)
timeline = []
for day in sorted(by_week):
    for m, n in by_week[day].items():
        cum[m] += n
    timeline.append({'date': day, 'totals': dict(cum),
                     'day': {m: n for m, n in by_week[day].items()}})

# Same daily axis, in source lines ADDED per model (vendored libregexp excluded).
#
# Deliberately gross additions, not net. Net (added minus deleted) badly
# misrepresents models that rewrite: claude-opus-5 edited 8,646 lines in place,
# where a one-line change counts as +1 -1 and nets to zero. That put it at 4,104
# net against 14,336 lines git blame says it actually owns today. Additions
# track "how much code did this model write", which is what the chart is for;
# the written-vs-surviving table already covers what survived.
lines_by_day = defaultdict(lambda: defaultdict(int))
for c in src:
    day = c['author_date'][:10]
    added = sum((f.get('added') or 0) for f in c['files']
                if f.get('is_source') and not f['path'].startswith('libregexp/'))
    lines_by_day[day][MODEL(c)] += added

lcum = defaultdict(int)
line_timeline = []
for day in sorted(lines_by_day):
    for m, n in lines_by_day[day].items():
        lcum[m] += n
    line_timeline.append({'date': day, 'totals': {k: v for k, v in lcum.items()},
                          'day': dict(lines_by_day[day])})

# harness share over time (monthly, kept for reference)
hmonth = defaultdict(Counter)
for c in src:
    hmonth[c['author_date'][:7]][HARNESS(c)] += 1

cmonth = defaultdict(Counter)
for c in src:
    cmonth[c['author_date'][:7]][c['category']] += 1

# weekly buckets drive the continuous timeline charts: 11 weeks reads as a
# trend, where 68 daily bars is noise and 3 monthly blocks hides the shape.
import datetime as _dt


def _week(iso):
    x = _dt.date.fromisoformat(iso[:10])
    return (x - _dt.timedelta(days=x.weekday())).isoformat()


hweek = defaultdict(Counter)
cweek = defaultdict(Counter)
for c in src:
    w = _week(c['author_date'])
    hweek[w][HARNESS(c)] += 1
    cweek[w][c['category']] += 1
weeks = sorted(set(hweek) | set(cweek))

# ---- areas ---------------------------------------------------------------
areas = {k: v for k, v in lines['by_area'].items()}

payload = {
    'meta': {
        'repo': 'duktape-c3',
        'first_commit': min(c['author_date'] for c in head)[:10],
        'last_commit': max(c['author_date'] for c in head)[:10],
        'commits_head': len(head),
        'commits_nonmerge': len(nonmerge),
        'commits_source': len(src),
        'commits_docs_only': len(docs_only),
        'lines_surviving': sum(surv.values()),
        'lines_written': sum(written.values()),
        'files': lines['totals']['files_blamed'],
        'models': len(models),
        'models_no_commits': sess['totals']['models_without_commits'],
        'sessions': sess['totals']['sessions'],
        'messages': sess['totals']['assistant_messages'],
        'tokens_out': toks['totals']['tokens_out'],
        'tokens_fresh_in': toks['totals']['tokens_fresh_in'],
        'tokens_cache_in': toks['totals']['tokens_cache_in'],
        'cost_known': costs['totals']['recorded'],
        'cost_best': costs['totals']['best'],
        'cost_estimated': costs['totals']['estimated'],
        'cost_actual': costs['totals']['actual'],
        'cost_multiple': costs['totals']['multiple'],
        'survival': round(sum(surv.values()) / max(1, sum(written.values())), 3),
    },
    'coverage': sess.get('coverage', {}),
    'models': models,
    'sessions_all': sess['by_model'],
    'activity_weekly': activity,
    'loops': loops,
    'timeline': timeline,
    'line_timeline': line_timeline,
    'harness_month': {k: dict(v) for k, v in sorted(hmonth.items())},
    'category_month': {k: dict(v) for k, v in sorted(cmonth.items())},
    'weeks': weeks,
    'harness_week': {k: dict(v) for k, v in sorted(hweek.items())},
    'category_week': {k: dict(v) for k, v in sorted(cweek.items())},
    'by_harness_lines': lines['by_harness'],
    'by_quality_lines': lines['by_attribution_quality'],
    'areas': areas,
    'tokens': toks,
    'costs': costs,
    'narrative': narr,
    'quality_counts': log.get('quality_counts', {}),
    'method_counts': log.get('method_counts', {}),
    'limitations': log.get('known_limitations', []),
}

json.dump(payload, open(f'{OUT}/report_data.json', 'w'), separators=(',', ':'))
print('models:', len(models))
print('source commits:', len(src), '| docs-only excluded:', len(docs_only))
print('surviving lines:', sum(surv.values()))
print('timeline points:', len(timeline))
print('narrative: bugs', len(narr.get('bugs', [])), 'decisions', len(narr.get('decisions', [])))
print('bytes:', len(open(f'{OUT}/report_data.json').read()))
