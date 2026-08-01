#!/usr/bin/env python3
"""Re-attribute span-based commits using GAP-SPLIT sessions.

Bug this fixes: a session's span was taken as (first assistant message, last
assistant message). A session resumed days later therefore claimed the entire
gap as active time. One claude-fable-5 session ran 2026-07-21 -> 2026-07-29 and
swallowed Jul 28-29, days on which the store shows fable-5 sent zero messages
and claude-opus-5 sent 2,191. That handed 40 commits to the wrong model.

Fix: rebuild spans from per-message timestamps, breaking a session into separate
active windows wherever there is a gap longer than GAP_MINUTES. A commit is then
only attributable to a model that was demonstrably mid-conversation.

Re-runs the span/nearest_span attribution against the corrected windows and
rewrites commit_log.json in place. Trailer and invocation attributions are never
touched -- they are hard evidence and outrank any timestamp inference.
"""
import json, sqlite3, os, glob, datetime as dt
from collections import defaultdict, Counter

REPO = '/Users/rtomasi/cousas/duktape-c3'
OUT = REPO + '/.attrib'
HOME = os.path.expanduser('~')
OC_PROJECT = '43ec93a49c9da24ec1679d7b5580bc8b83f9ab0f'
GAP_MINUTES = 45          # idle longer than this ends an active window
PAD_MINUTES = 10          # commits land shortly after the message that made them


def canon(m):
    if not m:
        return None
    m = m.strip().split('/')[-1].lower()
    for a, b in (('claude-opus-4-8', 'claude-opus-4.8'), ('claude-opus-4-7', 'claude-opus-4.7'),
                 ('claude-opus-4-6', 'claude-opus-4.6'), ('claude-sonnet-4-6', 'claude-sonnet-4.6'),
                 ('claude-haiku-4-5-20251001', 'claude-haiku-4.5'), ('xiaomi-mimo-', 'mimo-')):
        m = m.replace(a, b)
    if m.startswith('coding-'):
        m = m[7:]
    return m


# (session, model) -> [timestamps]
stamps = defaultdict(list)

db = sqlite3.connect(f'file:{REPO}/.crush/crush.db?mode=ro&immutable=1', uri=True)
last = {}
for sid, model, created in db.execute(
        "SELECT session_id, model, created_at FROM messages WHERE role='assistant' ORDER BY created_at"):
    if model:
        last[sid] = model
    m = canon(model or last.get(sid))
    if m and created:
        stamps[('crush', sid, m)].append(dt.datetime.fromtimestamp(created, dt.timezone.utc))
db.close()

db = sqlite3.connect(f'file:{HOME}/.local/share/opencode/opencode.db?mode=ro&immutable=1', uri=True)
scope = {r[0] for r in db.execute("SELECT id FROM session WHERE project_id=?", (OC_PROJECT,))}
for sid, data in db.execute("SELECT session_id, data FROM message"):
    if sid not in scope:
        continue
    try:
        d = json.loads(data)
    except Exception:
        continue
    if d.get('role') != 'assistant':
        continue
    m = canon(d.get('modelID'))
    t = d.get('time') or {}
    ms = t.get('created') if isinstance(t, dict) else None
    if m and ms:
        stamps[('opencode', sid, m)].append(dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc))
db.close()

for dpath in glob.glob(f'{HOME}/.claude/projects/*duktape-c3*'):
    for f in glob.glob(f'{dpath}/*.jsonl'):
        sid = os.path.basename(f)[:-6]
        for ln in open(f, errors='replace'):
            if '"assistant"' not in ln:
                continue
            try:
                e = json.loads(ln)
            except Exception:
                continue
            if e.get('type') != 'assistant':
                continue
            m = canon((e.get('message') or {}).get('model'))
            ts = e.get('timestamp')
            if not m or m == '<synthetic>' or not ts:
                continue
            try:
                x = dt.datetime.fromisoformat(ts.replace('Z', '+00:00'))
            except Exception:
                continue
            stamps[('claude-code', sid, m)].append(x)

# ---- build gap-split active windows --------------------------------------
GAP = dt.timedelta(minutes=GAP_MINUTES)
PAD = dt.timedelta(minutes=PAD_MINUTES)
windows = []          # (start, end, model, harness)
for (harness, sid, model), ts in stamps.items():
    ts.sort()
    s = p = ts[0]
    for x in ts[1:]:
        if x - p > GAP:
            windows.append((s, p + PAD, model, harness))
            s = x
        p = x
    windows.append((s, p + PAD, model, harness))

print(f'active windows: {len(windows)} (was {len(stamps)} whole-session spans)')
longest = max(windows, key=lambda w: w[1] - w[0])
print(f'longest window now: {(longest[1]-longest[0])} ({longest[2]})')

# ---- re-attribute span / nearest_span commits ----------------------------
log = json.load(open(f'{OUT}/commit_log.json'))


def P(s):
    if not s:
        return None
    s = s.replace('Z', '+00:00')
    try:
        x = dt.datetime.fromisoformat(s)
        return x if x.tzinfo else x.replace(tzinfo=dt.timezone.utc)
    except Exception:
        return None


changed = Counter()
moved = []
for c in log['commits']:
    a = c['attribution']
    if a.get('method') not in ('span', 'nearest_span', 'unresolved'):
        continue                     # never override trailer/invocation
    t = P(c.get('author_date'))
    if not t:
        continue
    hits = [(w[2], w[3]) for w in windows if w[0] <= t <= w[1]]
    before = a.get('model')
    if not hits:
        a['method'] = 'unresolved'
        a['model'] = None
        a['vendor'] = None
        a['harness'] = None
        a['candidates'] = None
        a['confidence'] = 0.0
        a['attribution_quality'] = 'none'
        a['span_note'] = 'no active session window contains this commit'
    else:
        cnt = Counter(hits)
        tot = sum(cnt.values())
        (bm, bh), n = cnt.most_common(1)[0]
        a['model'] = bm
        a['harness'] = bh
        a['method'] = 'span'
        a['candidates'] = [{'model': m, 'harness': h, 'weight': round(v / tot, 3)}
                           for (m, h), v in cnt.most_common()]
        a['model_ambiguous'] = len(cnt) > 1
        a['confidence'] = 0.6 if len(cnt) == 1 else 0.4
        a['attribution_quality'] = 'low'
        a['span_note'] = 'gap-split active window'
    if before != a.get('model'):
        changed[f'{before} -> {a.get("model")}'] += 1
        moved.append((c['short_sha'], c['author_date'][:10], before, a.get('model')))

log['quality_counts'] = dict(Counter(c['attribution'].get('attribution_quality')
                                     for c in log['commits']))
log['method_counts'] = dict(Counter(c['attribution'].get('method') for c in log['commits']))
log.setdefault('known_limitations', []).append(
    f'Session spans are gap-split at {GAP_MINUTES} min idle; a resumed session no longer '
    'claims the days it was dormant.')
json.dump(log, open(f'{OUT}/commit_log.json', 'w'), indent=1, default=str)

print(f'\nreattributed {sum(changed.values())} commits')
for k, v in changed.most_common(15):
    print(f'   {v:4}  {k}')
print('\nsample moves:')
for m in moved[:10]:
    print('   ', m)
