#!/usr/bin/env python3
"""Final stage: join commit log against harness evidence -> commit_log.json"""
import json, re, os, difflib, collections
from datetime import datetime, timezone, timedelta

D = os.path.dirname(os.path.abspath(__file__))
P = lambda n: os.path.join(D, n)

commits = json.load(open(P('commits.json')))
ev_files = ['evidence_crush.json', 'evidence_opencode.json', 'evidence_claude.json']

invocations, spans = [], []
for f in ev_files:
    d = json.load(open(P(f)))
    h = d['harness']
    for e in d['events']:
        e = dict(e); e['harness'] = h
        (invocations if e['kind'] == 'commit_invocation' else spans).append(e)

# ---------- time ----------
def ts(s):
    if not s: return None
    s = s.strip()
    if s.endswith('Z'): s = s[:-1] + '+00:00'
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None: dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)

# ---------- model normalization ----------
def canon(raw):
    """-> (canonical_id, vendor, local)"""
    if not raw: return None, None, False
    s = raw.strip()
    low = s.lower()
    # strip provider path prefixes
    if '/' in low:
        low = low.split('/')[-1]
    low = low.replace(' ', '-')
    local = False

    # anthropic claude family
    if low.startswith('claude'):
        m = low
        m = re.sub(r'-\d{8}$', '', m)              # date suffix
        m = re.sub(r'^claude-', '', m)
        # family-version: opus-4-8 -> opus-4.8
        m = re.sub(r'(\d)-(\d)', r'\1.\2', m)
        return 'claude-' + m, 'anthropic', False

    v = None
    if low.startswith('minimax'): v = 'minimax'
    elif low.startswith('mimo') or low.startswith('xiaomi-mimo'): v = 'xiaomi'
    elif low.startswith('deepseek'): v = 'deepseek'
    elif low.startswith('kimi') or low.startswith('k3') or low.startswith('coding-kimi') or low.startswith('moonshot'): v = 'moonshot'
    elif low.startswith('coding-minimax'): v = 'minimax'
    elif low.startswith('qwen') or low.startswith('qwopus'): v = 'alibaba'
    elif low.startswith('gemini') or low.startswith('gemma'): v = 'google'
    elif low.startswith('gpt'): v = 'openai'
    elif low.startswith('glm'): v = 'zhipu'
    elif low.startswith('mistral') or low.startswith('codestral'): v = 'mistralai'
    elif low.startswith('lfm'): v = 'liquidai'; local = True
    elif low.startswith('north-mini'): v = 'unknown'
    elif low.startswith('laguna'): v = 'unknown'
    elif low.startswith('big-pickle'): v = 'unknown'
    elif low.startswith('new-skill'): v = 'unknown'
    else: v = 'unknown'

    if low.startswith('xiaomi-mimo'): low = low[len('xiaomi-'):]
    if low.startswith('coding-'): low = low[len('coding-'):]
    # gemma-4-12b-qat / qwen3.6-27b -> keep, these are open-weight local families
    if v in ('google',) and low.startswith('gemma'): local = True
    if v == 'alibaba' and re.search(r'\d+b', low): local = True
    if low.startswith('qwopus'): local = True
    return low, v, local

# ---------- subject normalization ----------
def norm(s):
    s = (s or '').strip()
    s = re.sub(r'\s+', ' ', s)
    s = s.rstrip('.')
    return s.casefold()

# ---------- category ----------
PREFIX_MAP = {'feat': 'feature', 'feature': 'feature', 'fix': 'bugfix', 'bugfix': 'bugfix',
              'perf': 'perf', 'refactor': 'refactor', 'test': 'test', 'tests': 'test',
              'docs': 'docs', 'doc': 'docs', 'build': 'build', 'ci': 'build',
              'chore': 'chore', 'style': 'chore', 'revert': 'chore'}
PREFIX_RE = re.compile(r'^([a-zA-Z]+)(\([^)]*\))?!?:\s*(.+)$', re.S)

KEYWORDS = [
    ('bugfix', r'\b(fix(es|ed|ing)?|bug|crash|regression|segfault|correct(ly|s|ed)?|repair|broken|wrong|leak|uaf|use-after-free)\b'),
    ('perf', r'\b(perf|performance|optimi[sz](e|es|ed|ation)|speed ?up|faster|inline|fusion|benchmark|memory usage|reduce allocation)\b'),
    ('test', r'\b(test|tests|test262|rosetta|coverage|suite|harness|golden)\b'),
    ('docs', r'\b(docs?|documentation|readme|backlog|changelog|progress|plan|notes)\b'),
    ('refactor', r'\b(refactor|cleanup|clean up|rename|restructure|extract|simplify|dedupe|de-duplicate|move|split)\b'),
    ('build', r'\b(build|makefile|justfile|ci|script|tooling|compile flags|packaging)\b'),
    ('feature', r'\b(add|implement|support|introduce|new|enable|port)\b'),
    ('chore', r'\b(bump|version|format|housekeeping|wip|misc)\b'),
]

def area_of(files):
    counts = collections.Counter()
    for f in files:
        p = f['path']
        parts = p.split('/')
        if len(parts) == 1:
            key = 'root'
        elif parts[0] in ('src', 'test', 'tests', 'scripts', 'cli', 'libregexp', 'benchmarks',
                          'plans', 'docs', 'test262_runner', 'test_vm_runner', 'out', 'lib'):
            key = '/'.join(parts[:2]) if len(parts) > 1 else parts[0]
            if key.endswith('.c3') or key.endswith('.py') or '.' in parts[1]:
                key = parts[0]
        else:
            key = parts[0]
        w = (f.get('added') or 0) + (f.get('deleted') or 0) + 1
        counts[key] += w
    if not counts: return None
    for k, _ in counts.most_common():
        if k != 'root':
            return k
    return None

def path_category(files):
    if not files: return None
    counts = collections.Counter()
    for f in files:
        p = f['path'].lower()
        w = (f.get('added') or 0) + (f.get('deleted') or 0) + 1
        if p.startswith('test') or '/test' in p or p.startswith('tests'):
            counts['test'] += w
        elif p.endswith('.md') or p.startswith('plans/') or p.startswith('docs/'):
            counts['docs'] += w
        elif p.startswith('scripts/') or p in ('justfile', 'makefile', 'project.json') or p.startswith('.github'):
            counts['build'] += w
        elif f.get('is_source'):
            counts['feature'] += w
        else:
            counts['chore'] += w
    return counts.most_common(1)[0][0]

def categorize(c):
    subj = c['subject'] or ''
    if c['is_merge'] and not c['files']:
        return 'merge', 'prefix'
    m = PREFIX_RE.match(subj)
    if m and m.group(1).lower() in PREFIX_MAP:
        return PREFIX_MAP[m.group(1).lower()], 'prefix'
    low = subj.lower()
    if c['is_merge']:
        return 'merge', 'keyword'
    for cat, pat in KEYWORDS:
        if re.search(pat, low):
            return cat, 'keyword'
    pc = path_category(c['files'])
    if pc: return pc, 'paths'
    return 'chore', 'paths'

def summarize(c):
    subj = (c['subject'] or '').strip()
    m = PREFIX_RE.match(subj)
    if m and m.group(1).lower() in PREFIX_MAP:
        subj = m.group(3).strip()
    subj = re.sub(r'\s+', ' ', subj).strip()
    if len(subj) > 140:
        subj = subj[:137].rstrip() + '...'
    return subj

# ---------- index invocations ----------
inv_by_norm = collections.defaultdict(list)
inv_all = []
for e in invocations:
    n = norm(e.get('subject'))
    if not n: continue
    e['_n'] = n
    e['_ts'] = ts(e.get('ts'))
    inv_by_norm[n].append(e)
    inv_all.append(e)

norm_keys = list(inv_by_norm.keys())

spans_p = []
for s in spans:
    a, b = ts(s.get('start_ts')), ts(s.get('end_ts'))
    if not a or not b: continue
    if b < a: a, b = b, a
    spans_p.append((a, b, s))
spans_p.sort(key=lambda x: x[0])

TWELVE = timedelta(hours=12)
SIX = timedelta(hours=6)

model_reg = {}
def reg(raw, harness):
    cid, vend, loc = canon(raw)
    if cid is None: return None, None, None
    r = model_reg.setdefault(cid, {'vendor': vend, 'harnesses': set(), 'commits': 0, 'local': loc})
    if harness: r['harnesses'].add(harness)
    if loc: r['local'] = True
    return cid, vend, loc

out_commits = []
method_counts = collections.Counter()
match_kind_counts = collections.Counter()

for c in commits:
    ad = ts(c['author_date'])
    attr = None

    # 1) trailer
    if c.get('trailer_model') or c.get('trailer_harness'):
        raw = c.get('trailer_model')
        cid, vend, loc = reg(raw, c.get('trailer_harness'))
        attr = {'model': cid, 'model_raw': raw, 'vendor': vend,
                'harness': c.get('trailer_harness'), 'method': 'trailer',
                'confidence': 1.0, 'candidates': None, 'evidence': None}
        if loc: attr['local'] = True

    # 2) invocation
    if attr is None:
        n = norm(c['subject'])
        cands, kind = [], None
        if n and n in inv_by_norm:
            cands = inv_by_norm[n]; kind = 'exact'
        if not cands and n and len(n) >= 25:
            pm = [e for k, lst in inv_by_norm.items() if len(k) >= 25 and (k.startswith(n[:25]) and (k.startswith(n) or n.startswith(k))) for e in lst]
            if not pm:
                pm = [e for k, lst in inv_by_norm.items()
                      if min(len(k), len(n)) >= 25 and k[:25] == n[:25] for e in lst]
            if pm: cands, kind = pm, 'prefix'
        if not cands and n:
            best = difflib.get_close_matches(n, norm_keys, n=5, cutoff=0.92)
            pm = []
            for k in best:
                if difflib.SequenceMatcher(None, n, k).ratio() >= 0.92:
                    pm.extend(inv_by_norm[k])
            if pm: cands, kind = pm, 'ratio'

        if cands and ad:
            near = [(abs(e['_ts'] - ad), e) for e in cands if e['_ts'] and abs(e['_ts'] - ad) <= TWELVE]
            if near:
                near.sort(key=lambda x: x[0])
                bestd = near[0][0]
                tied = [e for d, e in near if d == bestd]
                models = {canon(e['model'])[0] for e in tied}
                if len(models) == 1:
                    e = tied[0]
                    raw = e.get('model_raw') or e.get('model')
                    cid, vend, loc = reg(raw, e['harness'])
                    attr = {'model': cid, 'model_raw': raw, 'vendor': vend,
                            'harness': e['harness'], 'method': 'invocation',
                            'confidence': 0.95, 'candidates': None,
                            'evidence': {'session_id': e.get('session_id'), 'ts': e.get('ts'),
                                         'match': kind}}
                    if loc: attr['local'] = True
                    match_kind_counts[kind] += 1
                # else: ambiguous -> fall through to span

    # 3) span
    if attr is None and ad:
        containing = [s for a, b, s in spans_p if a <= ad <= b]
        pairs = []
        seen = set()
        for s in containing:
            cid, vend, loc = canon(s['model'])
            key = (cid, s['harness'])
            if key in seen: continue
            seen.add(key)
            pairs.append((cid, vend, loc, s))
        if len(pairs) == 1:
            cid, vend, loc, s = pairs[0]
            reg(s.get('model_raw') or s['model'], s['harness'])
            attr = {'model': cid, 'model_raw': s.get('model_raw') or s['model'], 'vendor': vend,
                    'harness': s['harness'], 'method': 'span', 'confidence': 0.6,
                    'candidates': None,
                    'evidence': {'session_id': s.get('session_id'), 'ts': s.get('start_ts')}}
            if loc: attr['local'] = True
        elif len(pairs) > 1:
            w = 1.0 / len(pairs)
            cl = [{'model': cid, 'harness': s['harness'], 'weight': w} for cid, vend, loc, s in pairs]
            cid, vend, loc, s = pairs[0]
            for cid2, vend2, loc2, s2 in pairs:
                reg(s2.get('model_raw') or s2['model'], s2['harness'])
            attr = {'model': cid, 'model_raw': s.get('model_raw') or s['model'], 'vendor': vend,
                    'harness': s['harness'], 'method': 'span', 'confidence': 0.4,
                    'candidates': cl,
                    'evidence': {'session_id': s.get('session_id'), 'ts': s.get('start_ts')}}
            if loc: attr['local'] = True

    # 4) nearest span
    if attr is None and ad:
        best = None
        for a, b, s in spans_p:
            mid = a + (b - a) / 2
            d = abs(mid - ad)
            if d <= SIX and (best is None or d < best[0]):
                best = (d, s)
        if best:
            s = best[1]
            cid, vend, loc = canon(s['model'])
            reg(s.get('model_raw') or s['model'], s['harness'])
            attr = {'model': cid, 'model_raw': s.get('model_raw') or s['model'], 'vendor': vend,
                    'harness': s['harness'], 'method': 'nearest_span', 'confidence': 0.3,
                    'candidates': None,
                    'evidence': {'session_id': s.get('session_id'), 'ts': s.get('start_ts')}}
            if loc: attr['local'] = True

    # 5) unresolved
    if attr is None:
        attr = {'model': None, 'model_raw': None, 'vendor': None, 'harness': None,
                'method': 'unresolved', 'confidence': 0.0, 'candidates': None, 'evidence': None}

    method_counts[attr['method']] += 1
    if attr['model']:
        model_reg[attr['model']]['commits'] += 1

    cat, csrc = categorize(c)
    out_commits.append({
        'sha': c['sha'], 'short_sha': c['short_sha'],
        'author_date': c['author_date'], 'commit_date': c['commit_date'],
        'is_merge': c['is_merge'], 'on_head': c.get('on_head'),
        'subject': c['subject'], 'summary': summarize(c),
        'category': cat, 'category_source': csrc, 'area': area_of(c['files']),
        'files': c['files'],
        'insertions_total': c['insertions_total'], 'deletions_total': c['deletions_total'],
        'insertions_source': c['insertions_source'], 'deletions_source': c['deletions_source'],
        'attribution': attr,
    })

out_commits.sort(key=lambda x: (ts(x['author_date']), x['sha']))

harness_stats = collections.defaultdict(lambda: {'commits': 0, 'models': set(), 'methods': collections.Counter()})
for c in out_commits:
    h = c['attribution']['harness'] or 'unknown'
    hs = harness_stats[h]
    hs['commits'] += 1
    if c['attribution']['model']: hs['models'].add(c['attribution']['model'])
    hs['methods'][c['attribution']['method']] += 1
for h in ('claude-code', 'crush', 'opencode', 'unknown'):
    harness_stats[h]

doc = {
    'generated_at': datetime.now(timezone.utc).isoformat(),
    'repo': 'duktape-c3',
    'commit_count': len(out_commits),
    'models': {k: {'vendor': v['vendor'], 'harnesses': sorted(v['harnesses']),
                   'commits': v['commits'], **({'local': True} if v['local'] else {})}
               for k, v in sorted(model_reg.items(), key=lambda kv: -kv[1]['commits'])},
    'harnesses': {k: {'commits': v['commits'], 'models': sorted(v['models']),
                      'methods': dict(v['methods'])}
                  for k, v in sorted(harness_stats.items(), key=lambda kv: -kv[1]['commits'])},
    'commits': out_commits,
}

with open(P('commit_log.json'), 'w') as f:
    json.dump(doc, f, indent=1)

print('methods', dict(method_counts))
print('match kinds', dict(match_kind_counts))
print('categories', dict(collections.Counter(c['category'] for c in out_commits)))
print('cat_source', dict(collections.Counter(c['category_source'] for c in out_commits)))
print('harness', {k: v['commits'] for k, v in doc['harnesses'].items()})
print('top models', [(k, v['commits']) for k, v in list(doc['models'].items())[:15]])
print('areas', collections.Counter(c['area'] for c in out_commits).most_common(12))
print('count', len(out_commits))
