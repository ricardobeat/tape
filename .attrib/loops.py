#!/usr/bin/env python3
"""Detect Ralph-style autonomous loop prompts in the human turns.

A "Ralph loop" is a self-directing prompt re-sent verbatim so the agent keeps
picking up the next task on its own: a spec file as durable state, a numbered
find-implement-test-commit cycle, single-task scoping, and a sentinel token to
stop. The signature in this repo is unmistakable:

    @PRD.md @progress.md
      1. Find the highest-priority task and implement it.
      ...
      ONLY WORK ON A SINGLE TASK.
      If the PRD is complete, output <promise>COMPLETE</promise>.

Counted here because it materially changes how the other numbers read: a loop
tick spends a whole agent turn on find-implement-test-commit whether or not
anything lands, which is why the loop-heavy harnesses show the worst
messages-per-commit ratios.
"""
import json, re, datetime as dt
from collections import Counter, defaultdict

OUT = '/Users/rtomasi/cousas/duktape-c3/.attrib'

turns = json.load(open(f'{OUT}/human_turns.json'))['turns']

norm = lambda t: re.sub(r'\s+', ' ', (t or '').strip().lower())

# Self-directing: tells the agent to select its own next unit of work.
LOOP = re.compile(
    r'(find|pick)\b.{0,40}(next|highest.priority).{0,30}task'
    r'|autonomous loop tick'
    r'|continue if you have next steps',
    re.I)

counts = Counter(norm(t['text']) for t in turns)
loop_texts = {t for t, n in counts.items() if n >= 3 and LOOP.search(t)}
ticks = sorted((t for t in turns if norm(t['text']) in loop_texts),
               key=lambda t: t['ts'] or '')


def parse(s):
    if not s:
        return None
    s = s.replace('Z', '+00:00')
    try:
        x = dt.datetime.fromisoformat(s)
        return x if x.tzinfo else x.replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None


def week(iso):
    d = dt.date.fromisoformat(iso[:10])
    return (d - dt.timedelta(days=d.weekday())).isoformat()


by_week = Counter(week(t['ts']) for t in ticks if t['ts'])
by_harness = Counter(t['harness'] for t in ticks)

# Cadence: gap between consecutive *identical* prompts distinguishes a human
# re-firing after reading the result from an automated runner.
gaps = []
for a, b in zip(ticks, ticks[1:]):
    if norm(a['text']) != norm(b['text']):
        continue
    pa, pb = parse(a['ts']), parse(b['ts'])
    if pa and pb:
        g = (pb - pa).total_seconds() / 60
        if 0 < g < 600:
            gaps.append(g)
gaps.sort()


def pct(p):
    return gaps[int(len(gaps) * p)] if gaps else 0


# The distinct loop variants, ranked by use.
variants = []
for text, n in sorted(((t, counts[t]) for t in loop_texts), key=lambda x: -x[1]):
    original = next(t['text'] for t in turns if norm(t['text']) == text)
    # the stores collapse newlines to runs of spaces; put the line breaks back
    # so the numbered steps read as a list rather than one long paragraph
    pretty = re.sub(r'\s{2,}', '\n', original.strip())
    pretty = re.sub(r'\n{2,}', '\n', pretty)
    variants.append({'uses': n, 'text': pretty[:400]})

# ---- which models actually executed the ticks --------------------------------
# A tick is an instruction; the model that acted on it is whoever committed
# shortly afterwards in the same harness. Two hours is generous enough to cover
# a find-implement-test-commit cycle without spanning unrelated work.
tick_times = sorted((parse(t['ts']), t['harness']) for t in ticks if parse(t['ts']))
WINDOW = dt.timedelta(hours=2)
log = json.load(open(f'{OUT}/commit_log.json'))
loop_commits, all_commits = Counter(), Counter()
for c in log['commits']:
    if not c.get('on_head') or c.get('is_merge'):
        continue
    if not any(f.get('is_source') for f in c['files']):
        continue
    model = c['attribution'].get('model') or 'unattributed'
    harness = c['attribution'].get('harness')
    when = parse(c['author_date'])
    all_commits[model] += 1
    if when and any(tk <= when <= tk + WINDOW and (th == harness or not harness)
                    for tk, th in tick_times):
        loop_commits[model] += 1

# Roll variants up into vendor families: mimo-v2.5 vs mimo-v2.5-pro is not the
# distinction that matters for "was this model driven by a loop".
def family(m):
    for pre, name in (('mimo', 'mimo'), ('claude', 'claude'), ('deepseek', 'deepseek'),
                      ('minimax', 'minimax'), ('kimi', 'kimi'), ('k3', 'kimi'),
                      ('qwen', 'qwen'), ('qwopus', 'qwen'), ('pi', 'pi')):
        if m.startswith(pre):
            return name
    return m

fam_loop, fam_all = Counter(), Counter()
for m, n in all_commits.items():
    fam_loop[family(m)] += loop_commits.get(m, 0)
    fam_all[family(m)] += n

by_model = [
    {'model': f, 'loop_commits': fam_loop.get(f, 0), 'commits': n,
     'loop_share': round(fam_loop.get(f, 0) / n, 3)}
    for f, n in fam_all.most_common() if n >= 10
]

markers = {m: sum(1 for t in turns if m.lower() in (t['text'] or '').lower())
           for m in ('<promise>', 'ONLY WORK ON A SINGLE TASK', 'parallel agents')}

doc = {
    'note': ('Ralph-style loop prompts: a self-directing instruction re-sent verbatim so the '
             'agent keeps selecting its own next task. Detected as prompts repeated at least '
             'three times that tell the agent to find the next/highest-priority task.'),
    'total_turns': len(turns),
    'tick_count': len(ticks),
    'tick_share': round(len(ticks) / len(turns), 4),
    'variant_count': len(loop_texts),
    'by_harness': dict(by_harness.most_common()),
    'by_month': dict(sorted(Counter((t['ts'] or '')[:7] for t in ticks).items())),
    'by_week': dict(sorted(by_week.items())),
    'cadence_minutes': {
        'n': len(gaps),
        'p25': round(pct(.25)), 'median': round(pct(.50)), 'p75': round(pct(.75)),
        'under_2min': sum(1 for g in gaps if g < 2),
        'under_2min_share': round(sum(1 for g in gaps if g < 2) / len(gaps), 3) if gaps else 0,
    },
    'markers': markers,
    'by_model': by_model,
    'loop_commit_total': sum(loop_commits.values()),
    'commit_total': sum(all_commits.values()),
    'variants': variants[:8],
}
json.dump(doc, open(f'{OUT}/loops.json', 'w'), indent=1)

print(f"{len(ticks)} loop ticks of {len(turns)} turns ({100*len(ticks)/len(turns):.1f}%), "
      f"{len(loop_texts)} variants")
print('harness:', dict(by_harness.most_common()))
print('month  :', dict(sorted(Counter((t['ts'] or '')[:7] for t in ticks).items())))
print(f"cadence: median {round(pct(.5))} min, {doc['cadence_minutes']['under_2min']} gaps under 2 min")
print('markers:', markers)
print(f"\nloop-driven commits: {sum(loop_commits.values())}/{sum(all_commits.values())}")
for r in by_model[:8]:
    print(f"  {r['model']:24} {r['loop_commits']:4}/{r['commits']:4} = {100*r['loop_share']:3.0f}%")
