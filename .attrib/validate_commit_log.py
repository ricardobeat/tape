#!/usr/bin/env python3
"""Adversarial cross-validation of commit_log.json. Read-only; writes only validation_report.json."""
import json, re, os, collections, difflib, random, subprocess
from datetime import datetime, timezone, timedelta

D = os.path.dirname(os.path.abspath(__file__))
P = lambda n: os.path.join(D, n)
REPO = os.path.dirname(D)

doc = json.load(open(P('commit_log.json')))
commits = doc['commits']
by_sha = {c['sha']: c for c in commits}

ev = {}
invocations, spans = [], []
for f in ['evidence_crush.json', 'evidence_opencode.json', 'evidence_claude.json']:
    d = json.load(open(P(f)))
    h = d['harness']
    for e in d['events']:
        e = dict(e); e['harness'] = h
        (invocations if e['kind'] == 'commit_invocation' else spans).append(e)


def ts(s):
    if not s: return None
    s = s.strip()
    if s.endswith('Z'): s = s[:-1] + '+00:00'
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None: dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def canon(raw):
    if not raw: return None, None, False
    s = raw.strip(); low = s.lower()
    if '/' in low: low = low.split('/')[-1]
    low = low.replace(' ', '-')
    if low.startswith('claude'):
        m = re.sub(r'-\d{8}$', '', low)
        m = re.sub(r'^claude-', '', m)
        m = re.sub(r'(\d)-(\d)', r'\1.\2', m)
        return 'claude-' + m, 'anthropic', False
    return low, None, False


def norm(s):
    s = (s or '').strip()
    s = re.sub(r'\s+', ' ', s)
    return s.rstrip('.').casefold()


inv_by_norm = collections.defaultdict(list)
for e in invocations:
    n = norm(e.get('subject'))
    if not n: continue
    e['_n'] = n; e['_ts'] = ts(e.get('ts'))
    inv_by_norm[n].append(e)
norm_keys = list(inv_by_norm.keys())
TWELVE = timedelta(hours=12)


def evidence_match(subject, ad):
    """Replicate the matcher: returns (list_of_tied_events, kind) or (None, None)."""
    n = norm(subject)
    cands, kind = [], None
    if n and n in inv_by_norm:
        cands, kind = inv_by_norm[n], 'exact'
    if not cands and n and len(n) >= 25:
        pm = [e for k, lst in inv_by_norm.items()
              if len(k) >= 25 and k.startswith(n[:25]) and (k.startswith(n) or n.startswith(k))
              for e in lst]
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
    if not (cands and ad): return None, None
    near = [(abs(e['_ts'] - ad), e) for e in cands if e['_ts'] and abs(e['_ts'] - ad) <= TWELVE]
    if not near: return None, None
    near.sort(key=lambda x: x[0])
    bestd = near[0][0]
    tied = [e for d, e in near if d == bestd]
    return tied, kind


checks = []
problems = []


def add(name, passed, detail):
    checks.append({'name': name, 'passed': passed, 'detail': detail})


# ---------- CHECK 1: trailer vs evidence ----------
tr = [c for c in commits if c['attribution']['method'] == 'trailer']
agree = disagree = 0
harness_agree = harness_dis = 0
overlap = 0
dis_examples = []
for c in tr:
    ad = ts(c['author_date'])
    tied, kind = evidence_match(c['subject'], ad)
    if not tied: continue
    overlap += 1
    models = {canon(e.get('model_raw') or e.get('model'))[0] for e in tied}
    tm = c['attribution']['model']
    harnesses = {e['harness'] for e in tied}
    if tm in models: agree += 1
    else:
        disagree += 1
        if len(dis_examples) < 15:
            dis_examples.append({'sha': c['short_sha'], 'subject': c['subject'][:70],
                                 'trailer_model': tm, 'evidence_models': sorted(models),
                                 'match_kind': kind,
                                 'gap_s': min(abs((e['_ts'] - ad).total_seconds()) for e in tied)})
    if c['attribution']['harness'] in harnesses: harness_agree += 1
    else: harness_dis += 1
rate = agree / overlap if overlap else None
hrate = harness_agree / overlap if overlap else None
add('trailer_vs_evidence_agreement', bool(rate is not None and rate >= 0.95),
    {'trailer_commits': len(tr), 'with_evidence_match': overlap,
     'model_agree': agree, 'model_disagree': disagree,
     'model_agreement_rate': round(rate, 4) if rate is not None else None,
     'harness_agreement_rate': round(hrate, 4) if hrate is not None else None,
     'disagreement_examples': dis_examples})
if rate is not None and rate < 0.95:
    problems.append(f'trailer-vs-evidence model agreement only {rate:.1%} over {overlap} commits')

# unique-subject subset (stronger: exact match only)
agree_x = dis_x = ov_x = 0
for c in tr:
    ad = ts(c['author_date'])
    n = norm(c['subject'])
    if n not in inv_by_norm: continue
    tied, kind = evidence_match(c['subject'], ad)
    if not tied or kind != 'exact': continue
    ov_x += 1
    models = {canon(e.get('model_raw') or e.get('model'))[0] for e in tied}
    if c['attribution']['model'] in models: agree_x += 1
    else: dis_x += 1
add('trailer_vs_evidence_exact_subject_only', bool(ov_x and agree_x / ov_x >= 0.95),
    {'n': ov_x, 'agree': agree_x, 'disagree': dis_x,
     'rate': round(agree_x / ov_x, 4) if ov_x else None})

# ---------- CHECK 2: 12 random invocation commits, verified with git show ----------
inv = [c for c in commits if c['attribution']['method'] == 'invocation']
random.seed(20260731)
sample = random.sample(inv, min(12, len(inv)))
samp_out = []
bad2 = 0
for c in sample:
    r = subprocess.run(['git', '-C', REPO, 'show', '-s', '--format=%s%x00%aI%x00%cI', c['sha']],
                       capture_output=True, text=True)
    if r.returncode != 0:
        samp_out.append({'sha': c['short_sha'], 'error': 'git show failed: ' + r.stderr.strip()[:120]})
        bad2 += 1
        continue
    gsubj, gaid, gcid = r.stdout.strip().split('\0')
    evd = c['attribution']['evidence'] or {}
    ev_ts = ts(evd.get('ts'))
    ad = ts(gaid)
    gap = (ev_ts - ad).total_seconds() if ev_ts else None
    # find the actual evidence event
    matched = [e for e in invocations
               if e.get('session_id') == evd.get('session_id') and e.get('ts') == evd.get('ts')]
    ev_subj = matched[0].get('subject') if matched else None
    subj_ok = gsubj == c['subject']
    ev_subj_ok = ev_subj is not None and norm(ev_subj) == norm(gsubj)
    gap_ok = gap is not None and abs(gap) <= 12 * 3600
    ok = subj_ok and ev_subj_ok and gap_ok
    if not ok: bad2 += 1
    samp_out.append({'sha': c['short_sha'], 'git_subject': gsubj,
                     'log_subject_matches_git': subj_ok,
                     'evidence_subject': (ev_subj or '')[:90],
                     'evidence_subject_matches_git': ev_subj_ok,
                     'match_kind': evd.get('match'),
                     'model': c['attribution']['model'], 'harness': c['attribution']['harness'],
                     'gap_seconds_evidence_minus_commit': round(gap) if gap is not None else None,
                     'gap_sane': gap_ok, 'ok': ok})
add('manual_spotcheck_12_invocation_commits', bad2 == 0,
    {'sampled': len(sample), 'failures': bad2, 'samples': samp_out})
if bad2: problems.append(f'{bad2}/{len(sample)} spot-checked invocation commits failed verification')

# ---------- CHECK 3: time travel ----------
# 3a: evidence ts after commit date by > 1h
tt = []
for c in commits:
    evd = c['attribution'].get('evidence') or {}
    e_ts = ts(evd.get('ts'))
    if not e_ts: continue
    cd = ts(c['commit_date']) or ts(c['author_date'])
    delta = (e_ts - cd).total_seconds()
    if delta > 3600:
        tt.append({'sha': c['short_sha'], 'method': c['attribution']['method'],
                   'model': c['attribution']['model'], 'hours_after': round(delta / 3600, 2),
                   'commit_date': c['commit_date'], 'evidence_ts': evd.get('ts')})
tt.sort(key=lambda x: -x['hours_after'])
add('no_evidence_ts_after_commit_gt_1h', len(tt) == 0,
    {'violations': len(tt), 'by_method': dict(collections.Counter(x['method'] for x in tt)),
     'worst': tt[:10], 'note': 'span/nearest_span use span START ts, so a start after the commit is a real ordering violation'})
if tt: problems.append(f'{len(tt)} attributions have evidence ts >1h AFTER the commit date')

# 3b: model first-seen in evidence vs earliest commit attributed
first_seen = {}
for e in invocations + spans:
    cid = canon(e.get('model_raw') or e.get('model'))[0]
    if not cid: continue
    t = ts(e.get('ts') or e.get('start_ts'))
    if not t: continue
    if cid not in first_seen or t < first_seen[cid]: first_seen[cid] = t
last_seen = {}
for e in invocations + spans:
    cid = canon(e.get('model_raw') or e.get('model'))[0]
    if not cid: continue
    t = ts(e.get('end_ts') or e.get('ts'))
    if not t: continue
    if cid not in last_seen or t > last_seen[cid]: last_seen[cid] = t

model_first_commit = {}
model_last_commit = {}
for c in commits:
    m = c['attribution']['model']
    if not m: continue
    t = ts(c['author_date'])
    if m not in model_first_commit or t < model_first_commit[m]: model_first_commit[m] = t
    if m not in model_last_commit or t > model_last_commit[m]: model_last_commit[m] = t

anachronism = []
for m, t in sorted(model_first_commit.items()):
    fs = first_seen.get(m)
    if fs is None:
        anachronism.append({'model': m, 'issue': 'model never appears in any evidence file',
                            'first_commit': t.isoformat(),
                            'commits': doc['models'].get(m, {}).get('commits')})
    elif (fs - t).total_seconds() > 3600:
        anachronism.append({'model': m, 'issue': 'commit predates model first-seen in evidence',
                            'first_commit': t.isoformat(), 'evidence_first_seen': fs.isoformat(),
                            'days_before': round((fs - t).total_seconds() / 86400, 2),
                            'commits': doc['models'].get(m, {}).get('commits')})
after_last = []
for m, t in sorted(model_last_commit.items()):
    ls = last_seen.get(m)
    if ls and (t - ls).total_seconds() > 3600:
        after_last.append({'model': m, 'last_commit': t.isoformat(),
                           'evidence_last_seen': ls.isoformat(),
                           'days_after': round((t - ls).total_seconds() / 86400, 2),
                           'commits': doc['models'].get(m, {}).get('commits')})
add('model_existence_window', len(anachronism) == 0,
    {'anachronisms': anachronism,
     'commits_after_model_last_seen': after_last})
if anachronism:
    problems.append(f'{len(anachronism)} models attributed to commits outside their evidence existence window')

# ---------- CHECK 4: harness has a session overlapping the commit date ----------
harness_days = collections.defaultdict(set)
harness_sessions = collections.defaultdict(list)
for e in invocations + spans:
    h = e['harness']
    a = ts(e.get('start_ts') or e.get('ts'))
    b = ts(e.get('end_ts') or e.get('ts'))
    if not a: continue
    if not b: b = a
    harness_sessions[h].append((a, b))
    d = a.date()
    while d <= b.date():
        harness_days[h].add(d)
        d += timedelta(days=1)

no_overlap = []
for c in commits:
    h = c['attribution']['harness']
    if not h: continue
    ad = ts(c['author_date'])
    if ad.date() in harness_days[h]: continue
    # allow +-1 day tolerance
    if (ad.date() - timedelta(days=1)) in harness_days[h] or (ad.date() + timedelta(days=1)) in harness_days[h]:
        continue
    no_overlap.append({'sha': c['short_sha'], 'date': c['author_date'], 'harness': h,
                       'model': c['attribution']['model'], 'method': c['attribution']['method']})
add('harness_has_session_on_commit_date', len(no_overlap) == 0,
    {'violations': len(no_overlap),
     'by_harness': dict(collections.Counter(x['harness'] for x in no_overlap)),
     'by_method': dict(collections.Counter(x['method'] for x in no_overlap)),
     'examples': no_overlap[:15],
     'harness_active_ranges': {h: {'first': min(a for a, b in v).isoformat(),
                                   'last': max(b for a, b in v).isoformat(),
                                   'active_days': len(harness_days[h])}
                               for h, v in harness_sessions.items()}})
if no_overlap:
    problems.append(f'{len(no_overlap)} commits attributed to a harness with no session within +-1 day')

# ---------- CHECK 5: monthly distribution ----------
per_month_model = collections.defaultdict(collections.Counter)
per_month_harness = collections.defaultdict(collections.Counter)
per_month_method = collections.defaultdict(collections.Counter)
for c in commits:
    mo = c['author_date'][:7]
    per_month_model[mo][c['attribution']['model'] or 'UNRESOLVED'] += 1
    per_month_harness[mo][c['attribution']['harness'] or 'UNRESOLVED'] += 1
    per_month_method[mo][c['attribution']['method']] += 1

# harness evidence months
harness_months = collections.defaultdict(set)
for h, v in harness_sessions.items():
    for a, b in v:
        harness_months[h].add(a.strftime('%Y-%m'))
        harness_months[h].add(b.strftime('%Y-%m'))
smells = []
for mo, cnt in sorted(per_month_harness.items()):
    for h, n in cnt.items():
        if h == 'UNRESOLVED': continue
        if mo not in harness_months[h]:
            smells.append(f'{n} {h} commits in {mo} but {h} store has no session in that month')
model_months = collections.defaultdict(set)
for e in invocations + spans:
    cid = canon(e.get('model_raw') or e.get('model'))[0]
    a = ts(e.get('start_ts') or e.get('ts')); b = ts(e.get('end_ts') or e.get('ts')) or a
    if not a: continue
    model_months[cid].add(a.strftime('%Y-%m')); model_months[cid].add(b.strftime('%Y-%m'))
for mo, cnt in sorted(per_month_model.items()):
    for m, n in cnt.items():
        if m == 'UNRESOLVED': continue
        if mo not in model_months[m]:
            smells.append(f'{n} {m} commits in {mo} but model has no evidence session in that month')

add('monthly_distribution', len(smells) == 0,
    {'commits_per_month': {mo: sum(c.values()) for mo, c in sorted(per_month_harness.items())},
     'harness_per_month': {mo: dict(c.most_common()) for mo, c in sorted(per_month_harness.items())},
     'method_per_month': {mo: dict(c.most_common()) for mo, c in sorted(per_month_method.items())},
     'model_per_month': {mo: dict(c.most_common()) for mo, c in sorted(per_month_model.items())},
     'smells': smells})
problems.extend(smells)

# ---------- extra: recompute whole attribution independence sanity ----------
method_counts = collections.Counter(c['attribution']['method'] for c in commits)
conf = collections.Counter(c['attribution']['confidence'] for c in commits)
low_conf = sum(n for k, n in conf.items() if k <= 0.6)
add('method_mix', True,
    {'methods': dict(method_counts),
     'confidence_hist': {str(k): v for k, v in sorted(conf.items())},
     'share_confidence_le_0.6': round(low_conf / len(commits), 4),
     'note': 'span/nearest_span/unresolved are heuristic, not evidence-backed'})

ok = all(c['passed'] for c in checks)
report = {'ok': ok, 'checks': checks, 'problems': problems,
          'verdict': ''}
with open(P('validation_report.json'), 'w') as f:
    json.dump(report, f, indent=1)
print(json.dumps({'ok': ok, 'summary': [(c['name'], c['passed']) for c in checks],
                  'n_problems': len(problems)}, indent=1))
