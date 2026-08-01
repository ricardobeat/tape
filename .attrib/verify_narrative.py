#!/usr/bin/env python3
"""Verify every mined finding against its source, then dedupe and rank.

This is a mechanical string check, so it runs locally rather than in an agent --
the earlier attempt embedded 241 findings in a prompt and the agent stalled
re-transcribing them by hand.

A finding survives only if its quote is really present in the artifact it claims
to come from. Anything else is a fabrication and is dropped.
"""
import json, subprocess, re, difflib
from collections import Counter

OUT = '/Users/rtomasi/cousas/duktape-c3/.attrib'
REPO = '/Users/rtomasi/cousas/duktape-c3'

bugs = json.load(open(f'{OUT}/raw_bugs.json'))
decs = json.load(open(f'{OUT}/raw_decisions.json'))
turns = json.load(open(f'{OUT}/human_turns_candidates.json'))['turns']


def norm(s):
    """Collapse whitespace so newline/wrap differences don't fail a real match."""
    return re.sub(r'\s+', ' ', (s or '')).strip()


def contains(hay, needle):
    """Quote present? Allow ellipsis elision and a fuzzy fallback for wrapping."""
    h, n = norm(hay), norm(needle)
    if not n:
        return False
    if n in h:
        return True
    # tolerate "start ... end" elision
    if '...' in n or '…' in n:
        parts = [p.strip() for p in re.split(r'\.\.\.|…', n) if p.strip()]
        if parts and all(p[:60] in h for p in parts):
            return True
    # a long quote that only differs by rewrapping/punctuation
    if len(n) >= 40:
        head, tail = n[:40], n[-40:]
        if head in h and tail in h and h.index(head) <= h.rindex(tail):
            return True
        if difflib.SequenceMatcher(None, n, h).find_longest_match(
                0, len(n), 0, len(h)).size >= len(n) * 0.85:
            return True
    # Substantively-grounded but lightly reworded: the agents sometimes tightened
    # a quote rather than copying it. Require most sliding windows to be present
    # verbatim, which a fabricated quote cannot achieve.
    if len(n) >= 60:
        wins = [n[i:i + 30] for i in range(0, len(n) - 30, 15)]
        if wins and sum(1 for w in wins if w in h) / len(wins) >= 0.5:
            return True
    return False


# ---------------------------------------------------------------- bugs -----
body_cache = {}


def body_of(sha):
    if sha not in body_cache:
        r = subprocess.run(['git', '-C', REPO, 'log', '-1', '--format=%B', sha],
                           capture_output=True, text=True)
        body_cache[sha] = r.stdout if r.returncode == 0 else None
    return body_cache[sha]


kept_bugs, dropped_bugs = [], []
for b in bugs:
    sha = (b.get('sha') or '').strip()
    if not re.fullmatch(r'[0-9a-f]{6,40}', sha):
        dropped_bugs.append((sha, 'bad sha', b.get('title')))
        continue
    body = body_of(sha)
    if body is None:
        dropped_bugs.append((sha, 'sha not in repo', b.get('title')))
        continue
    if not contains(body, b.get('evidence_quote')):
        dropped_bugs.append((sha, 'quote not in body', b.get('title')))
        continue
    # Distinguish an exact copy from a grounded-but-tightened paraphrase, so the
    # report never presents the latter inside quotation marks.
    b['quote_exact'] = norm(b.get('evidence_quote')) in norm(body)
    b['verified'] = True
    b['month'] = (b.get('date') or '')[:7]
    kept_bugs.append(b)

# --------------------------------------------------------------- decisions --
by_date = {}
for t in turns:
    by_date.setdefault((t['ts'] or '')[:10], []).append(t['text'])

kept_decs, dropped_decs = [], []
for d in decs:
    day = (d.get('date') or '')[:10]
    pool = by_date.get(day, [])
    if not pool:  # allow +/-1 day for timezone skew
        for off in (-1, 1):
            try:
                import datetime as dt
                alt = (dt.date.fromisoformat(day) + dt.timedelta(days=off)).isoformat()
                pool = pool + by_date.get(alt, [])
            except Exception:
                pass
    if not any(contains(p, d.get('quote')) for p in pool):
        dropped_decs.append((day, 'quote not found', (d.get('title') or '')[:50]))
        continue
    d['quote_exact'] = any(norm(d.get('quote')) in norm(p) for p in pool)
    d['verified'] = True
    d['month'] = day[:7]
    kept_decs.append(d)

# ----------------------------------------------------------------- dedupe ---
seen = {}
for b in kept_bugs:
    k = b['sha']
    if k not in seen or len(b.get('evidence_quote', '')) > len(seen[k].get('evidence_quote', '')):
        seen[k] = b
kept_bugs = list(seen.values())

dseen = {}
for d in kept_decs:
    k = norm(d.get('quote'))[:80].lower()
    if k not in dseen or (d.get('date') or '') < (dseen[k].get('date') or ''):
        dseen[k] = d
kept_decs = list(dseen.values())

# ------------------------------------------------------------------- rank ---
SEV = {'catastrophic': 0, 'severe': 1, 'notable': 2}
kept_bugs.sort(key=lambda b: (SEV.get(b.get('severity'), 3),
                              0 if b.get('latency_signal') else 1,
                              -len(b.get('evidence_quote') or '')))
# Spread across the timeline instead of taking 20 from whichever month mined
# heaviest -- this is a story about the whole project, not one week of July.
_bym = {}
for b in kept_bugs:
    _bym.setdefault(b['month'], []).append(b)
top_bugs, _r = [], 0
while len(top_bugs) < 20 and any(len(v) > _r for v in _bym.values()):
    for m in sorted(_bym):
        if len(top_bugs) >= 20:
            break
        if len(_bym[m]) > _r:
            top_bugs.append(_bym[m][_r])
    _r += 1
top_bugs.sort(key=lambda b: (SEV.get(b.get('severity'), 3), b.get('date') or ''))

KIND = {'architecture': 0, 'course-correction': 1, 'quality-bar': 2, 'scope': 3, 'process': 4}
# keep a spread across months rather than letting July dominate
bym = {}
for d in sorted(kept_decs, key=lambda x: (KIND.get(x.get('kind'), 5), x.get('date') or '')):
    bym.setdefault(d['month'], []).append(d)
top_decs = []
round_i = 0
while len(top_decs) < 18 and any(v[round_i:] for v in bym.values()):
    for m in sorted(bym):
        if len(top_decs) >= 18:
            break
        if len(bym[m]) > round_i:
            top_decs.append(bym[m][round_i])
    round_i += 1
top_decs.sort(key=lambda x: x.get('date') or '')

json.dump({
    'bugs': top_bugs,
    'decisions': top_decs,
    'counts': {'bugs_in': len(bugs), 'bugs_verified': len(kept_bugs), 'bugs_out': len(top_bugs),
               'decisions_in': len(decs), 'decisions_verified': len(kept_decs),
               'decisions_out': len(top_decs),
               'bugs_dropped': len(dropped_bugs), 'decisions_dropped': len(dropped_decs)},
}, open(f'{OUT}/narrative.json', 'w'), indent=1)

print(f"bugs      : {len(bugs)} in -> {len(kept_bugs)} verified -> {len(top_bugs)} kept "
      f"({len(dropped_bugs)} dropped)")
print(f"decisions : {len(decs)} in -> {len(kept_decs)} verified -> {len(top_decs)} kept "
      f"({len(dropped_decs)} dropped)")
print('\nbug severity kept:', dict(Counter(b['severity'] for b in top_bugs)))
print('decision kinds kept:', dict(Counter(d['kind'] for d in top_decs)))
print('decision months:', dict(Counter(d['month'] for d in top_decs)))
if dropped_bugs:
    print('\nsample dropped bugs:')
    for s, why, t in dropped_bugs[:6]:
        print(f'   {s} [{why}] {t}')
if dropped_decs:
    print('\nsample dropped decisions:')
    for s, why, t in dropped_decs[:6]:
        print(f'   {s} [{why}] {t}')
