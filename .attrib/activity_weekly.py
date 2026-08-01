#!/usr/bin/env python3
"""Per-week assistant-message counts per model, for the effort timeline.

session_activity.json only keeps first_seen/last_seen per model, which cannot
drive a time series. This re-reads the three stores and buckets every assistant
message into its ISO week, so the effort chart can show when each model was
actually working rather than only that it worked at some point.

Message count, not tokens: it is the one unit all three harnesses record
identically per message, and it tracks "was this model busy this week" without
being skewed by one model's verbosity.
"""
import json, sqlite3, os, glob, datetime as dt
from collections import defaultdict, Counter

REPO = '/Users/rtomasi/cousas/duktape-c3'
OUT = REPO + '/.attrib'
HOME = os.path.expanduser('~')
OC_PROJECT = '43ec93a49c9da24ec1679d7b5580bc8b83f9ab0f'


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


def week(d):
    return (d - dt.timedelta(days=d.weekday())).isoformat()


by_week = defaultdict(Counter)          # week -> model -> messages


def note(model, when):
    c = canon(model)
    if c and when:
        by_week[week(when.date())][c] += 1


# ------------------------------------------------------------------ crush ---
db = sqlite3.connect(f'file:{REPO}/.crush/crush.db?mode=ro&immutable=1', uri=True)
last = {}
for sid, model, created in db.execute(
        "SELECT session_id, model, created_at FROM messages "
        "WHERE role='assistant' ORDER BY created_at"):
    if model:
        last[sid] = model
    if created:
        note(model or last.get(sid),
             dt.datetime.fromtimestamp(created, dt.timezone.utc))
db.close()

# --------------------------------------------------------------- opencode ---
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
    t = d.get('time') or {}
    ms = t.get('created') if isinstance(t, dict) else None
    if ms:
        note(d.get('modelID'), dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc))
db.close()

# ----------------------------------------------------------------- claude ---
for dpath in glob.glob(f'{HOME}/.claude/projects/*duktape-c3*'):
    for f in glob.glob(f'{dpath}/*.jsonl'):
        for ln in open(f, errors='replace'):
            if '"assistant"' not in ln:
                continue
            try:
                e = json.loads(ln)
            except Exception:
                continue
            if e.get('type') != 'assistant':
                continue
            m = (e.get('message') or {}).get('model')
            ts = e.get('timestamp')
            if not m or m == '<synthetic>' or not ts:
                continue
            try:
                note(m, dt.datetime.fromisoformat(ts.replace('Z', '+00:00')))
            except ValueError:
                pass

# Pi is a harness, not a model, and it kept no session store. There is nothing
# to plot on a per-model activity chart, so no estimate is synthesized here.
estimated = {}

weeks = sorted(by_week)
totals = Counter()
for w in weeks:
    totals.update(by_week[w])

doc = {
    'note': ('Assistant messages per ISO week per model, across Crush, OpenCode and '
             'Claude Code. Drives the effort timeline. Claude Code transcripts only '
             'start 2026-06-30, so Claude models are undercounted before that date. '
             'Pi is a harness with no session store and is absent from this series.'),
    'estimated': estimated,
    'weeks': weeks,
    'by_week': {w: dict(by_week[w]) for w in weeks},
    'totals': dict(totals.most_common()),
}
json.dump(doc, open(f'{OUT}/activity_weekly.json', 'w'), indent=1)

print(f'{len(weeks)} weeks, {len(totals)} models, {sum(totals.values()):,} messages')
print(f'range: {weeks[0]} .. {weeks[-1]}\n')
for m, n in totals.most_common(10):
    active = sum(1 for w in weeks if by_week[w].get(m))
    print(f'  {m:26} {n:7,} msgs over {active:2} weeks')
