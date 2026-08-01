#!/usr/bin/env python3
"""Extract human prose turns from all three harness stores, for decision-point mining.

We want the moments where the human changed the direction of the work. Slash
commands, tool results, system reminders and one-word acks are noise; what counts
is prose the person typed. This pulls every such turn with enough context
(timestamp, session, the assistant's following reply head) for a judging pass.
"""
import json, sqlite3, os, glob, re, datetime as dt

REPO = '/Users/rtomasi/cousas/duktape-c3'
OUT = REPO + '/.attrib'
HOME = os.path.expanduser('~')
OC_PROJECT = '43ec93a49c9da24ec1679d7b5580bc8b83f9ab0f'

NOISE = re.compile(
    r'<local-command|<command-name|<command-message|<command-args|<system-reminder|'
    r'<local-command-stdout|Caveat:|\[Request interrupted|tool_result|'
    r'^\s*(ok|okay|yes|no|y|n|go|go ahead|continue|thanks|ty|sure|do it|yep|nice|good)\s*[.!]?\s*$',
    re.I | re.M)

# Turns that look like a directive rather than a status question. Not used to
# filter (we keep everything and let the judges decide) but recorded as a hint.
DIRECTIVE = re.compile(
    r"\b(don'?t|do not|never|always|instead|actually|no[,.]|stop|revert|undo|"
    r"rather than|prefer|must|should|need to|lets |let's |we want|i want|"
    r"rewrite|redo|scrap|drop |remove |switch to|use |avoid)\b", re.I)
BUGWORD = re.compile(
    r"\b(bug|broken|regress|crash|segfault|leak|corrupt|wrong|fails?|failing|"
    r"stale|silent|uaf|use-after-free|double free|hang|deadlock|race)\b", re.I)


def clean(t):
    if not isinstance(t, str):
        return ''
    t = t.strip()
    return t


rows = []


def add(harness, session, ts, text, model=None):
    text = clean(text)
    if len(text) < 25 or NOISE.search(text):
        return
    rows.append({
        'harness': harness, 'session': session,
        'ts': ts.isoformat() if hasattr(ts, 'isoformat') else ts,
        'text': text[:4000],
        'chars': len(text),
        'is_directive': bool(DIRECTIVE.search(text)),
        'mentions_bug': bool(BUGWORD.search(text)),
        'model_context': model,
    })


# ------------------------------------------------------------------ crush ---
db = sqlite3.connect(f'file:{REPO}/.crush/crush.db?mode=ro&immutable=1', uri=True)
last_model = {}
for sid, role, parts, model, created in db.execute(
        "SELECT session_id, role, parts, model, created_at FROM messages ORDER BY created_at"):
    if role == 'assistant' and model:
        last_model[sid] = model
        continue
    if role != 'user':
        continue
    try:
        p = json.loads(parts)
    except Exception:
        continue
    txt = ' '.join(
        (x.get('data') or {}).get('text', '')
        for x in p if isinstance(x, dict) and x.get('type') == 'text')
    ts = dt.datetime.fromtimestamp(created, dt.timezone.utc) if created else None
    add('crush', sid, ts, txt, last_model.get(sid))
db.close()

# --------------------------------------------------------------- opencode ---
db = sqlite3.connect(f'file:{HOME}/.local/share/opencode/opencode.db?mode=ro&immutable=1', uri=True)
scope = {r[0] for r in db.execute("SELECT id FROM session WHERE project_id=?", (OC_PROJECT,))}
user_msgs = {}
for mid, sid, data in db.execute("SELECT id, session_id, data FROM message"):
    if sid not in scope:
        continue
    try:
        d = json.loads(data)
    except Exception:
        continue
    if d.get('role') == 'user':
        t = d.get('time') or {}
        user_msgs[mid] = (sid, (t.get('created') if isinstance(t, dict) else None))
for mid, sid, data in db.execute("SELECT message_id, session_id, data FROM part"):
    if mid not in user_msgs:
        continue
    try:
        d = json.loads(data)
    except Exception:
        continue
    if d.get('type') != 'text':
        continue
    ms = user_msgs[mid][1]
    ts = dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc) if ms else None
    add('opencode', sid, ts, d.get('text') or '')
db.close()

# ----------------------------------------------------------------- claude ---
for d in glob.glob(f'{HOME}/.claude/projects/*duktape-c3*'):
    for f in glob.glob(f'{d}/*.jsonl'):
        sid = os.path.basename(f)[:-6]
        for ln in open(f, errors='replace'):
            if '"type":"user"' not in ln:
                continue
            try:
                e = json.loads(ln)
            except Exception:
                continue
            if e.get('type') != 'user':
                continue
            m = e.get('message') or {}
            c = m.get('content')
            if isinstance(c, list):
                c = ' '.join(x.get('text', '') for x in c
                             if isinstance(x, dict) and x.get('type') == 'text')
            add('claude-code', sid, e.get('timestamp', '')[:19], c)

rows.sort(key=lambda r: r['ts'] or '')
json.dump({'count': len(rows), 'turns': rows}, open(f'{OUT}/human_turns.json', 'w'), indent=1)

from collections import Counter
print('total human turns:', len(rows))
print('by harness:', dict(Counter(r['harness'] for r in rows)))
print('directive-ish:', sum(1 for r in rows if r['is_directive']))
print('bug-mentioning:', sum(1 for r in rows if r['mentions_bug']))
print('substantial (>=120 chars):', sum(1 for r in rows if r['chars'] >= 120))
