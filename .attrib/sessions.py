#!/usr/bin/env python3
"""Session-level effort per model, independent of whether work was committed.

The commit/blame views structurally cannot see a model that ran but never landed
a commit -- north-mini-code burned 601 messages and shows up nowhere in them.
This view counts EFFORT (sessions, assistant messages, tokens, wall-clock, cost)
straight from the three harness stores, so exploratory and abandoned work is
visible alongside the work that shipped.

Sources (all read-only):
  crush     .crush/crush.db          messages.model/provider, created_at SECONDS
  opencode  ~/.local/share/opencode/opencode.db  message.data JSON, ms epoch,
            scoped to the duktape-c3 project id
  claude    ~/.claude/projects/*duktape-c3*/*.jsonl   message.model + message.usage

Wall-clock is summed per session as (last - first assistant message), which
undercounts a session left idle and overcounts nothing; it is a duration floor,
not a billing figure. Cost is only available from the harness's own accounting
(crush sessions, opencode sessions) -- Claude transcripts carry tokens but no
cost, so cost is reported as null there rather than invented from a price table.
"""
import json, sqlite3, os, glob, datetime as dt
from collections import defaultdict, Counter

REPO = '/Users/rtomasi/cousas/duktape-c3'
OUT = REPO + '/.attrib'
HOME = os.path.expanduser('~')
OC_PROJECT = '43ec93a49c9da24ec1679d7b5580bc8b83f9ab0f'


def ro(path):
    return sqlite3.connect(f'file:{path}?mode=ro&immutable=1', uri=True)


def blank():
    return {'sessions': set(), 'messages': 0, 'tokens_in': 0, 'tokens_out': 0,
            'cost': 0.0, 'cost_known': False, 'first': None, 'last': None,
            'seconds': 0.0, 'harnesses': set()}


agg = defaultdict(blank)          # canonical model -> stats
raw_names = defaultdict(set)


def canon(m):
    """Canonicalize a raw model string; mirrors the commit_log normalization."""
    if not m:
        return None
    m = m.strip().split('/')[-1].lower()
    m = m.replace('claude-opus-4-8', 'claude-opus-4.8').replace('claude-opus-4-7', 'claude-opus-4.7')
    m = m.replace('claude-opus-4-6', 'claude-opus-4.6').replace('claude-sonnet-4-6', 'claude-sonnet-4.6')
    m = m.replace('claude-haiku-4-5-20251001', 'claude-haiku-4.5')
    m = m.replace('xiaomi-mimo-', 'mimo-')
    for pre in ('coding-',):
        if m.startswith(pre):
            m = m[len(pre):]
    return m


def note(model, harness, session, ts, tin=0, tout=0, cost=None):
    c = canon(model)
    if not c:
        return
    a = agg[c]
    raw_names[c].add(model)
    a['sessions'].add((harness, session))
    a['messages'] += 1
    a['tokens_in'] += tin or 0
    a['tokens_out'] += tout or 0
    a['harnesses'].add(harness)
    if cost:
        a['cost'] += cost
        a['cost_known'] = True
    if ts:
        if a['first'] is None or ts < a['first']:
            a['first'] = ts
        if a['last'] is None or ts > a['last']:
            a['last'] = ts


# per-session first/last, to sum wall-clock without letting one long gap dominate
span = defaultdict(lambda: [None, None, None])   # (harness,session,model) -> [min,max,model]


def span_note(model, harness, session, ts):
    c = canon(model)
    if not c or ts is None:
        return
    k = (harness, session, c)
    s = span[k]
    if s[0] is None or ts < s[0]:
        s[0] = ts
    if s[1] is None or ts > s[1]:
        s[1] = ts
    s[2] = c


# ---------------------------------------------------------------- crush ----
db = ro(f'{REPO}/.crush/crush.db')
cur = db.execute("SELECT session_id, role, model, provider, created_at FROM messages")
last_model = {}
for sid, role, model, provider, created in cur:
    if role != 'assistant':
        continue
    if model:
        last_model[sid] = model
    m = model or last_model.get(sid)
    ts = dt.datetime.fromtimestamp(created, dt.timezone.utc) if created else None
    note(m, 'crush', sid, ts)
    span_note(m, 'crush', sid, ts)
# crush tracks tokens+cost at session granularity
for sid, ptok, ctok, cost in db.execute(
        "SELECT id, prompt_tokens, completion_tokens, cost FROM sessions"):
    m = last_model.get(sid)
    c = canon(m)
    if not c:
        continue
    agg[c]['tokens_in'] += ptok or 0
    agg[c]['tokens_out'] += ctok or 0
    if cost:
        agg[c]['cost'] += cost
        agg[c]['cost_known'] = True
db.close()

# ------------------------------------------------------------- opencode ----
db = ro(f'{HOME}/.local/share/opencode/opencode.db')
sess_scope = {r[0] for r in db.execute(
    "SELECT id FROM session WHERE project_id=?", (OC_PROJECT,))}
for sid, data in db.execute("SELECT session_id, data FROM message"):
    if sid not in sess_scope:
        continue
    try:
        d = json.loads(data)
    except Exception:
        continue
    if d.get('role') != 'assistant':
        continue
    m = d.get('modelID')
    t = d.get('time')
    ms = (t or {}).get('created') if isinstance(t, dict) else d.get('time_created')
    ts = dt.datetime.fromtimestamp(ms / 1000, dt.timezone.utc) if ms else None
    tok = d.get('tokens') or {}
    note(m, 'opencode', sid, ts,
         tok.get('input') or 0, tok.get('output') or 0, d.get('cost'))
    span_note(m, 'opencode', sid, ts)
db.close()

# --------------------------------------------------------------- claude ----
for d in glob.glob(f'{HOME}/.claude/projects/*duktape-c3*'):
    for f in glob.glob(f'{d}/*.jsonl'):
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
            msg = e.get('message') or {}
            m = msg.get('model')
            if not m or m == '<synthetic>':
                continue
            u = msg.get('usage') or {}
            ts = None
            if e.get('timestamp'):
                try:
                    ts = dt.datetime.fromisoformat(e['timestamp'].replace('Z', '+00:00'))
                except Exception:
                    pass
            note(m, 'claude-code', sid, ts,
                 (u.get('input_tokens') or 0) + (u.get('cache_read_input_tokens') or 0)
                 + (u.get('cache_creation_input_tokens') or 0),
                 u.get('output_tokens') or 0, None)
            span_note(m, 'claude-code', sid, ts)

for (_h, _s, c), (a, b, _m) in span.items():
    if a and b:
        agg[c]['seconds'] += (b - a).total_seconds()

# ------------------------------------------------------------------ join ---
commit_side = {}
try:
    tot = json.load(open(f'{OUT}/line_totals.json'))
    commit_side = {r['model']: r for r in tot['by_model']}
except Exception:
    pass

rows = []
for c, a in agg.items():
    cs = commit_side.get(c, {})
    rows.append({
        'model': c,
        'raw_names': sorted(raw_names[c]),
        'harnesses': sorted(a['harnesses']),
        'sessions': len(a['sessions']),
        'assistant_messages': a['messages'],
        'tokens_in': a['tokens_in'],
        'tokens_out': a['tokens_out'],
        'cost_usd': round(a['cost'], 2) if a['cost_known'] else None,
        'active_hours': round(a['seconds'] / 3600, 2),
        'first_seen': a['first'].isoformat() if a['first'] else None,
        'last_seen': a['last'].isoformat() if a['last'] else None,
        # commit-side, for the effort-vs-output comparison
        'commits': cs.get('commits', 0),
        'lines_written': cs.get('lines_written', 0),
        'lines_surviving': cs.get('lines_surviving', 0),
        'committed': bool(cs.get('commits')),
    })
rows.sort(key=lambda r: -r['assistant_messages'])

doc = {
    'note': ('Effort per model measured from harness session stores, independent of commits. '
             'Includes models that ran but never landed a commit. active_hours sums per-session '
             '(last-first) assistant timestamps and is a floor, not billed time. cost_usd is the '
             "harness's own accounting; null where the store does not record cost (Claude Code)."),
    'totals': {
        'models': len(rows),
        'models_with_commits': sum(1 for r in rows if r['committed']),
        'models_without_commits': sum(1 for r in rows if not r['committed']),
        'assistant_messages': sum(r['assistant_messages'] for r in rows),
        'sessions': sum(r['sessions'] for r in rows),
        'tokens_in': sum(r['tokens_in'] for r in rows),
        'tokens_out': sum(r['tokens_out'] for r in rows),
        'cost_usd_known': round(sum(r['cost_usd'] or 0 for r in rows), 2),
    },
    'by_model': rows,
}
json.dump(doc, open(f'{OUT}/session_activity.json', 'w'), indent=1)

T = doc['totals']
print(f"models {T['models']} ({T['models_without_commits']} never committed) | "
      f"sessions {T['sessions']:,} | msgs {T['assistant_messages']:,} | "
      f"out-tokens {T['tokens_out']:,} | known cost ${T['cost_usd_known']:,.2f}\n")
print(f"{'model':30} {'sess':>5} {'msgs':>7} {'hours':>7} {'commits':>8} {'written':>8}")
for r in rows[:26]:
    print(f"{r['model']:30} {r['sessions']:5} {r['assistant_messages']:7} "
          f"{r['active_hours']:7.1f} {r['commits']:8} {r['lines_written']:8,}")
print('\n--- ran but never committed ---')
for r in rows:
    if not r['committed'] and r['assistant_messages'] >= 5:
        print(f"  {r['model']:28} {r['sessions']:3} sess {r['assistant_messages']:5} msgs "
              f"{r['active_hours']:6.1f}h  {','.join(r['harnesses'])}")
