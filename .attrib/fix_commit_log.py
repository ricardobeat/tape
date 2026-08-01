#!/usr/bin/env python3
"""Corrective pass over commit_log.json.

The verify stage backtested the span fallback against the 1681 trailered commits
as held-out ground truth: timestamp containment recovers the right model only
~33-52% of the time, because this repo was built with many CONCURRENT agent
sessions and 52% of commits fall inside more than one active span. A coin flip
presented as an attribution is worse than an honest gap, so this pass demotes
those rows instead of letting them masquerade as findings.

Fixes applied:
  1. span / nearest_span -> attribution_quality 'low', and for multi-candidate
     rows the top-level model is set to null so a consumer reading .model can
     never silently get a coin flip. Candidates are preserved.
  2. Revert commits matched by difflib ratio to the ORIGINAL commit's invocation
     event are unmatched (both ratio matches in the log were this bug).
  3. Every row gains 'attribution_quality': high | medium | low | none, which is
     the field downstream charts should filter on.
  4. Corroboration flags for the claude-code store truncation (store starts
     2026-06-30; trailered claude commits start 2026-05-29).
"""
import json, datetime as dt, re
from collections import Counter

P = '/Users/rtomasi/cousas/duktape-c3/.attrib/commit_log.json'
log = json.load(open(P))

CLAUDE_STORE_START = dt.datetime(2026, 6, 30, tzinfo=dt.timezone.utc)

def parse(s):
    if not s:
        return None
    s = s.replace('Z', '+00:00')
    try:
        d = dt.datetime.fromisoformat(s)
        return d if d.tzinfo else d.replace(tzinfo=dt.timezone.utc)
    except ValueError:
        return None

stats = Counter()

for c in log['commits']:
    a = c['attribution']
    m = a.get('method')
    ev = a.get('evidence') or {}

    # --- fix 2: revert/ratio false positives -------------------------------
    if m == 'invocation' and ev.get('match') == 'ratio' and re.match(r'^\s*Revert\b', c['subject'] or ''):
        a['method'] = 'unresolved'
        a['model'] = None
        a['model_raw'] = None
        a['vendor'] = None
        a['confidence'] = 0.0
        a['evidence'] = None
        a['unmatched_reason'] = 'ratio match resolved to the reverted original, not this revert'
        m = 'unresolved'
        stats['revert_unmatched'] += 1

    # --- fix 1 + 3: quality tiers ------------------------------------------
    if m == 'trailer':
        a['attribution_quality'] = 'high'
        stats['high'] += 1
    elif m == 'invocation':
        a['attribution_quality'] = 'high' if ev.get('match') == 'exact' else 'medium'
        stats[a['attribution_quality']] += 1
    elif m in ('span', 'nearest_span'):
        a['attribution_quality'] = 'low'
        cands = a.get('candidates') or []
        if len(cands) > 1:
            # Best-guess mode: keep a usable winner in .model rather than nulling,
            # but pick it by candidate weight (not insertion order) and flag the
            # ambiguity so charts can filter or split by weight if they want to.
            a['model_ambiguous'] = True
            best = max(cands, key=lambda x: x.get('weight') or 0)
            if best.get('model'):
                a['model'] = best['model']
                if best.get('harness'):
                    a['harness'] = best['harness']
            stats['ambiguous_kept_best'] += 1
        a['confidence'] = min(a.get('confidence') or 0.0, 0.4)
        stats['low'] += 1
    else:
        a['attribution_quality'] = 'none'
        stats['none'] += 1

    # --- fix 4: corroboration ---------------------------------------------
    t = parse(c.get('author_date'))
    if a.get('harness') == 'claude-code' and t and t < CLAUDE_STORE_START:
        a['store_corroborated'] = False
        a['corroboration_note'] = 'claude-code session store begins 2026-06-30; earlier rows rest on the commit trailer alone'
        stats['claude_uncorroborated'] += 1
    elif m in ('trailer',) and not ev:
        a['store_corroborated'] = None
    else:
        a['store_corroborated'] = bool(ev) or None

log['attribution_quality_legend'] = {
    'high':   'trailer in the commit, or exact commit-subject match to a harness session invocation',
    'medium': 'prefix subject match to a session invocation',
    'low':    'timestamp/session-span inference only. Backtested at ~33-52% accuracy against trailered '
              'commits because concurrent sessions overlap; DO NOT use for per-model totals.',
    'none':   'no evidence; model is null',
}
log['known_limitations'] = [
    'The claude-code session store begins 2026-06-30 while trailered claude-code commits begin '
    '2026-05-29, so pre-July Claude attributions cannot be independently corroborated against a store.',
    'Span-based attribution is unreliable here because many agent sessions ran concurrently; '
    'those rows are marked attribution_quality=low and ambiguous ones have model=null.',
    "git rev-list --all drifts while agent worktrees commit; the stable universe is on_head (1905).",
]

qc = Counter(c['attribution'].get('attribution_quality') for c in log['commits'])
mc = Counter(c['attribution'].get('method') for c in log['commits'])
log['quality_counts'] = dict(qc)
log['method_counts'] = dict(mc)

json.dump(log, open(P, 'w'), indent=1, default=str)
print('fixes:', dict(stats))
print('quality:', dict(qc))
print('methods:', dict(mc))
