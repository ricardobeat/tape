#!/usr/bin/env python3
"""Trace HEAD commits back to the ORIGINAL authoring commit on a side branch.

Problem: work done by model A on a branch, later rebased / cherry-picked /
squashed onto main by Claude, is credited by git blame to the *merger*, not the
author. That systematically under-counts models whose branches someone else
landed, and over-counts whoever did the landing.

Three linkage signals, strongest first:

  1. patch-id  -- `git patch-id` is invariant under rebase and cherry-pick (it
     hashes the diff, ignoring sha/parent/message/timestamp). If an off-HEAD
     commit has the same patch-id as a HEAD commit, they are the same change.
     This catches rebases and clean cherry-picks.
  2. "(cherry picked from commit X)" trailers -- explicit and exact.
  3. subject match -- for squashes/amends where the diff changed slightly.

Only reattributes when the ORIGIN has attribution at least as good as the
current one, and never overwrites a HEAD commit that carries its own trailer
naming a model (that trailer is ground truth about who wrote it).
"""
import json, subprocess, re
from collections import defaultdict, Counter

REPO = '/Users/rtomasi/cousas/duktape-c3'
OUT = REPO + '/.attrib'

log = json.load(open(f'{OUT}/commit_log.json'))
BY_SHA = {c['sha']: c for c in log['commits']}


def git(*a, **kw):
    return subprocess.run(['git', '-C', REPO, *a], capture_output=True, text=True, **kw).stdout


def patch_ids(shas, label):
    """Return {patch_id: [sha,...]} computed in batches."""
    out = defaultdict(list)
    B = 200
    for i in range(0, len(shas), B):
        batch = shas[i:i + B]
        # patch-id emits "<patch-id> <commit-id>"; append our own sha as a 3rd
        # field so the mapping is unambiguous even when patch-id prints zeros.
        script = f'cd {REPO}\n' + '\n'.join(
            f'git diff-tree -p --no-commit-id --root {s} 2>/dev/null '
            f'| git patch-id --stable | sed "s|$| {s}|"' for s in batch)
        r = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
        for ln in r.stdout.split('\n'):
            parts = ln.split()
            if len(parts) >= 3:
                out[parts[0]].append(parts[2])
        print(f'  {label}: {min(i+B,len(shas))}/{len(shas)}', flush=True)
    return out


head = [c['sha'] for c in log['commits'] if c.get('on_head') and not c.get('is_merge')]
side = [c['sha'] for c in log['commits'] if not c.get('on_head') and not c.get('is_merge')]
print(f'HEAD non-merge {len(head)} | side non-merge {len(side)}')

h_ids = patch_ids(head, 'head')
s_ids = patch_ids(side, 'side')

QUALITY_RANK = {'high': 3, 'medium': 2, 'low': 1, 'none': 0, None: 0}


def better(origin, current):
    """Is origin's attribution usable and at least as trustworthy as current's?"""
    oa, ca = origin['attribution'], current['attribution']
    if not oa.get('model'):
        return False
    if oa.get('model') == ca.get('model'):
        return False
    # never override a real trailer on the HEAD commit
    if ca.get('method') == 'trailer':
        return False
    return QUALITY_RANK[oa.get('attribution_quality')] >= QUALITY_RANK[ca.get('attribution_quality')]


links = {}   # head_sha -> (origin_sha, how)

# --- signal 1: identical patch-id -----------------------------------------
for pid, hs in h_ids.items():
    if pid not in s_ids:
        continue
    for hsha in hs:
        for ssha in s_ids[pid]:
            if hsha == ssha or hsha in links:
                continue
            o, c = BY_SHA.get(ssha), BY_SHA.get(hsha)
            if o and c and better(o, c):
                links[hsha] = (ssha, 'patch-id')
                break

# --- signal 2: explicit cherry-pick trailers -------------------------------
CP = re.compile(r'cherry picked from commit ([0-9a-f]{7,40})', re.I)
body = git('log', 'HEAD', '--format=%H%x1f%b%x1e')
for rec in body.split('\x1e'):
    if '\x1f' not in rec:
        continue
    sha, b = rec.split('\x1f', 1)
    sha = sha.strip()
    if sha in links or sha not in BY_SHA:
        continue
    m = CP.search(b or '')
    if not m:
        continue
    src = m.group(1)
    full = [s for s in BY_SHA if s.startswith(src)]
    if len(full) == 1:
        o, c = BY_SHA[full[0]], BY_SHA[sha]
        if better(o, c):
            links[sha] = (full[0], 'cherry-pick-trailer')

# --- signal 3: subject match for squashed work -----------------------------
side_by_subject = defaultdict(list)
for s in side:
    c = BY_SHA[s]
    key = ' '.join((c['subject'] or '').split()).strip().lower()
    if len(key) >= 20:
        side_by_subject[key].append(s)
for h in head:
    if h in links:
        continue
    c = BY_SHA[h]
    key = ' '.join((c['subject'] or '').split()).strip().lower()
    cands = side_by_subject.get(key) or []
    if len(cands) == 1:
        o = BY_SHA[cands[0]]
        if better(o, c):
            links[h] = (cands[0], 'subject')

print(f'\nreattribution links found: {len(links)}')
print('by method:', dict(Counter(v[1] for v in links.values())))

moved_from = Counter()
moved_to = Counter()
for hsha, (ssha, how) in links.items():
    moved_from[BY_SHA[hsha]['attribution'].get('model') or 'unattributed'] += 1
    moved_to[BY_SHA[ssha]['attribution'].get('model')] += 1
print('\ncredit taken FROM:', moved_from.most_common(10))
print('credit given TO:  ', moved_to.most_common(10))

json.dump({
    'note': ('Maps a HEAD commit to the original side-branch commit that authored the same change, '
             'so blame credit follows the author rather than whoever rebased/cherry-picked it. '
             'Never overrides a HEAD commit that carries its own model trailer.'),
    'links': {k: {'origin': v[0], 'via': v[1],
                  'from_model': BY_SHA[k]['attribution'].get('model'),
                  'to_model': BY_SHA[v[0]]['attribution'].get('model')}
              for k, v in links.items()},
}, open(f'{OUT}/reattribution_map.json', 'w'), indent=1)
print(f'\nwrote {OUT}/reattribution_map.json')
