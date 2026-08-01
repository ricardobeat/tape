#!/usr/bin/env python3
"""Per-model token accounting, corrected.

Three problems with the naive pass this replaces:

 1. Claude Code's usage block counts cache reads as input. Summing
    input+cache_read+cache_creation gave claude-opus-4.8 4.06 BILLION input
    tokens -- that is the same context re-read every turn, not work done. We
    therefore report:
       fresh_in  = input_tokens + cache_creation_input_tokens  (actually processed)
       cache_in  = cache_read_input_tokens                     (re-read, ~free)
    and use OUTPUT tokens as the comparable "produced" figure across harnesses.

 2. Crush stores tokens per SESSION, not per message, so a session was credited
    entirely to its last model. Only 46/1641 sessions used more than one model,
    but we now split a multi-model session's tokens across its models in
    proportion to each one's assistant-message count instead of winner-take-all.

 3. OpenCode tokens live in message.data.tokens.{input,output,reasoning,cache}
    (41,376 rows have them) but the earlier pass read the wrong key path, so 10
    models showed messages with zero tokens.

Output tokens are the honest cross-harness comparable: every store records them
the same way, and they measure what the model actually generated.
"""
import json, sqlite3, os, glob, datetime as dt
from collections import defaultdict, Counter

REPO = '/Users/rtomasi/cousas/duktape-c3'
OUT = REPO + '/.attrib'
HOME = os.path.expanduser('~')
OC_PROJECT = '43ec93a49c9da24ec1679d7b5580bc8b83f9ab0f'


def ro(p):
    return sqlite3.connect(f'file:{p}?mode=ro&immutable=1', uri=True)


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


T = defaultdict(lambda: {'out': 0, 'fresh_in': 0, 'cache_in': 0, 'reasoning': 0,
                         'msgs': 0, 'cost': 0.0, 'cost_known': False,
                         'harnesses': set(), 'source': set()})

# ------------------------------------------------------------------ crush ---
# Tokens are per-session; split across the models that actually spoke in it.
db = ro(f'{REPO}/.crush/crush.db')
sess_models = defaultdict(Counter)
for sid, model in db.execute("SELECT session_id, model FROM messages WHERE role='assistant'"):
    c = canon(model)
    if c:
        sess_models[sid][c] += 1
for sid, m in sess_models.items():
    for mod, n in m.items():
        T[mod]['msgs'] += n
        T[mod]['harnesses'].add('crush')

for sid, ptok, ctok, cost in db.execute(
        "SELECT id, prompt_tokens, completion_tokens, cost FROM sessions"):
    mods = sess_models.get(sid)
    if not mods:
        continue
    tot = sum(mods.values())
    for mod, n in mods.items():
        w = n / tot
        T[mod]['fresh_in'] += int((ptok or 0) * w)
        T[mod]['out'] += int((ctok or 0) * w)
        T[mod]['source'].add('crush:session-prorated')
        if cost:
            T[mod]['cost'] += cost * w
            T[mod]['cost_known'] = True
db.close()

# --------------------------------------------------------------- opencode ---
db = ro(f'{HOME}/.local/share/opencode/opencode.db')
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
    c = canon(d.get('modelID'))
    if not c:
        continue
    tk = d.get('tokens') or {}
    cache = tk.get('cache') or {}
    T[c]['msgs'] += 1
    T[c]['out'] += tk.get('output') or 0
    T[c]['fresh_in'] += (tk.get('input') or 0) + (cache.get('write') or 0)
    T[c]['cache_in'] += cache.get('read') or 0
    T[c]['reasoning'] += tk.get('reasoning') or 0
    T[c]['harnesses'].add('opencode')
    T[c]['source'].add('opencode:per-message')
    if d.get('cost'):
        T[c]['cost'] += d['cost']
        T[c]['cost_known'] = True
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
            msg = e.get('message') or {}
            c = canon(msg.get('model'))
            if not c or c == '<synthetic>':
                continue
            u = msg.get('usage') or {}
            T[c]['msgs'] += 1
            T[c]['out'] += u.get('output_tokens') or 0
            T[c]['fresh_in'] += (u.get('input_tokens') or 0) + \
                                (u.get('cache_creation_input_tokens') or 0)
            T[c]['cache_in'] += u.get('cache_read_input_tokens') or 0
            T[c]['harnesses'].add('claude-code')
            T[c]['source'].add('claude:per-message')

# ------------------------------------------------------------------ join ----
tot = json.load(open(f'{OUT}/line_totals.json'))
by_model = {r['model']: r for r in tot['by_model']}

rows = []
for m, v in T.items():
    lt = by_model.get(m, {})
    written = lt.get('lines_written', 0)
    rows.append({
        'model': m,
        'tokens_out': v['out'],
        'tokens_fresh_in': v['fresh_in'],
        'tokens_cache_in': v['cache_in'],
        'tokens_reasoning': v['reasoning'],
        'messages': v['msgs'],
        'cost_usd': round(v['cost'], 2) if v['cost_known'] else None,
        'harnesses': sorted(v['harnesses']),
        'accounting': sorted(v['source']),
        'out_per_msg': round(v['out'] / v['msgs']) if v['msgs'] else 0,
        'lines_written': written,
        'lines_surviving': lt.get('lines_surviving', 0),
        # how many output tokens went into each source line that still exists
        'tokens_per_surviving_line': (
            round(v['out'] / lt['lines_surviving'], 1)
            if lt.get('lines_surviving') else None),
        'tokens_per_written_line': (
            round(v['out'] / written, 1) if written else None),
    })
rows.sort(key=lambda r: -r['tokens_out'])

doc = {
    'note': ('Output tokens are the cross-harness comparable: all three stores record them '
             'identically. Input is split into fresh (processed) vs cache (re-read) because '
             'Claude Code counts cache reads as input, which inflates naive input sums by ~100x. '
             'Crush records tokens per session, so multi-model sessions (46 of 1641) are '
             'prorated by assistant-message share rather than credited to one model.'),
    'totals': {
        'tokens_out': sum(r['tokens_out'] for r in rows),
        'tokens_fresh_in': sum(r['tokens_fresh_in'] for r in rows),
        'tokens_cache_in': sum(r['tokens_cache_in'] for r in rows),
        'cost_usd_known': round(sum(r['cost_usd'] or 0 for r in rows), 2),
        'models': len(rows),
    },
    'by_model': rows,
}
json.dump(doc, open(f'{OUT}/token_totals.json', 'w'), indent=1)

D = doc['totals']
print(f"out {D['tokens_out']:,} | fresh-in {D['tokens_fresh_in']:,} | "
      f"cache-in {D['tokens_cache_in']:,} | cost ${D['cost_usd_known']:,.2f}\n")
print(f"{'model':28} {'out tok':>12} {'/msg':>7} {'written':>9} {'tok/line':>9} {'cost':>8}")
for r in rows[:20]:
    c = f"${r['cost_usd']:.0f}" if r['cost_usd'] else '—'
    tpl = r['tokens_per_written_line']
    print(f"{r['model']:28} {r['tokens_out']:12,} {r['out_per_msg']:7} "
          f"{r['lines_written']:9,} {(tpl if tpl else '—'):>9} {c:>8}")
zero = [r['model'] for r in rows if r['messages'] and not r['tokens_out']]
print('\nstill zero-token models:', zero or 'none')
