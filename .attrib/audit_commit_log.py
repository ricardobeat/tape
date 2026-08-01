#!/usr/bin/env python3
import json, subprocess, random, collections, os, sys, re

REPO = '/Users/rtomasi/cousas/duktape-c3'
P = os.path.join(REPO, '.attrib/commit_log.json')

def git(*a):
    return subprocess.run(['git', '-C', REPO] + list(a), capture_output=True, text=True)

checks = []
problems = []
def add(name, passed, detail):
    checks.append({'name': name, 'passed': passed, 'detail': detail})
    if not passed:
        problems.append(f'{name}: {detail}')

# 8. parse + schema
raw = open(P).read()
try:
    d = json.loads(raw)
    parsed = True
except Exception as e:
    print(json.dumps({'ok': False, 'checks': [], 'problems': [f'JSON parse failed: {e}'], 'verdict': 'FAIL'}))
    sys.exit(0)

EXPECT_TOP = {'generated_at', 'repo', 'commit_count', 'models', 'harnesses', 'commits'}
top = set(d.keys())
add('8_json_schema', parsed and top == EXPECT_TOP,
    f'parsed=True top_keys={sorted(top)} missing={sorted(EXPECT_TOP-top)} extra={sorted(top-EXPECT_TOP)}')

commits = d['commits']
n = len(commits)

# 1. counts
all_count = int(git('rev-list', '--all', '--count').stdout.strip())
head_count = int(git('rev-list', 'HEAD', '--count').stdout.strip())
on_head = sum(1 for c in commits if c.get('on_head'))
c1 = (n == all_count) and (on_head == head_count) and (d['commit_count'] == n)
add('1_row_count', c1,
    f'json_rows={n} declared_commit_count={d["commit_count"]} git_all={all_count} '
    f'json_on_head={on_head} git_head={head_count}')

json_shas = set(c['sha'] for c in commits)
git_all_shas = set(git('rev-list', '--all').stdout.split())
missing = git_all_shas - json_shas
extra = json_shas - git_all_shas
if missing or extra:
    ms = sorted(missing)[:10]
    det = []
    for s in ms:
        subj = git('show', '-s', '--format=%H %s', s).stdout.strip()
        det.append(subj)
    add('1b_sha_set_diff', False,
        f'in_git_not_json={len(missing)} in_json_not_git={len(extra)}; missing_examples={det}')
else:
    add('1b_sha_set_diff', True, 'sha sets identical')

# 2. sha validity
hexre = re.compile(r'^[0-9a-f]{40}$')
dupes = [s for s, k in collections.Counter(c['sha'] for c in commits).items() if k > 1]
badfmt = [c['sha'] for c in commits if not hexre.match(c.get('sha') or '')]
# existence via cat-file --batch-check
inp = '\n'.join(sorted(json_shas)) + '\n'
r = subprocess.run(['git', '-C', REPO, 'cat-file', '--batch-check'], input=inp,
                   capture_output=True, text=True)
nonexist = [l.split()[0] for l in r.stdout.splitlines() if 'missing' in l]
c2 = not dupes and not badfmt and not nonexist
add('2_sha_unique_hex_exists', c2,
    f'unique={len(json_shas)}/{n} dupes={len(dupes)}{dupes[:5]} bad_format={len(badfmt)}{badfmt[:5]} '
    f'nonexistent={len(nonexist)}{nonexist[:5]}')

# 3. category
ALLOWED_CAT = {'feature', 'bugfix', 'perf', 'refactor', 'test', 'docs', 'build', 'chore', 'merge'}
cats = collections.Counter(c.get('category') for c in commits)
nullcat = cats.get(None, 0)
badcat = {k: v for k, v in cats.items() if k not in ALLOWED_CAT}
top_share = max(cats.values()) / n
c3 = (nullcat == 0) and not badcat and top_share < 0.95
add('3_category', c3,
    f'distribution={dict(cats.most_common())} null={nullcat} out_of_set={badcat} '
    f'top_bucket_share={top_share:.3f}')

# 4. attribution
ALLOWED_M = {'trailer', 'invocation', 'span', 'nearest_span', 'unresolved'}
mm = collections.Counter()
noattr = 0
badm = collections.Counter()
badconf = []
for c in commits:
    a = c.get('attribution')
    if not isinstance(a, dict):
        noattr += 1
        continue
    m = a.get('method')
    mm[m] += 1
    if m not in ALLOWED_M:
        badm[m] += 1
    cf = a.get('confidence')
    if not isinstance(cf, (int, float)) or not (0.0 <= cf <= 1.0):
        badconf.append((c['sha'], cf))
c4 = noattr == 0 and not badm and not badconf
add('4_attribution', c4,
    f'methods={dict(mm)} missing_attr={noattr} bad_method={dict(badm)} '
    f'bad_confidence={len(badconf)}{badconf[:5]}')

# 5. source <= total
viol = []
for c in commits:
    if c['insertions_source'] > c['insertions_total'] or c['deletions_source'] > c['deletions_total']:
        viol.append((c['sha'], c['insertions_source'], c['insertions_total'],
                     c['deletions_source'], c['deletions_total']))
add('5_source_le_total', not viol,
    f'violations={len(viol)} examples={viol[:5]}')

# also check totals vs sum of files
sumviol = []
for c in commits:
    ai = sum(f['added'] or 0 for f in c['files'])
    ad = sum(f['deleted'] or 0 for f in c['files'])
    if ai != c['insertions_total'] or ad != c['deletions_total']:
        sumviol.append((c['sha'], ai, c['insertions_total'], ad, c['deletions_total']))
add('5b_totals_match_files', not sumviol, f'mismatches={len(sumviol)} examples={sumviol[:5]}')

# 6. spot check 15 random
random.seed(20260731)
sample = random.sample(commits, 15)
mismatches = []
for c in sample:
    sha = c['sha']
    r = git('show', '--numstat', '--format=%H%n%s', sha)
    lines = r.stdout.split('\n')
    if len(lines) < 2:
        mismatches.append((sha, 'git show empty'))
        continue
    gsha = lines[0].strip()
    gsubj = lines[1].strip()
    added = deleted = 0
    nf = 0
    for l in lines[2:]:
        l = l.strip()
        if not l:
            continue
        parts = l.split('\t')
        if len(parts) != 3:
            continue
        nf += 1
        if parts[0] != '-':
            added += int(parts[0])
        if parts[1] != '-':
            deleted += int(parts[1])
    errs = []
    if gsha != sha: errs.append(f'sha {gsha}')
    if gsubj != (c['subject'] or '').strip(): errs.append(f'subject git={gsubj!r} json={c["subject"]!r}')
    if nf != len(c['files']): errs.append(f'filecount git={nf} json={len(c["files"])}')
    if added != c['insertions_total']: errs.append(f'added git={added} json={c["insertions_total"]}')
    if deleted != c['deletions_total']: errs.append(f'deleted git={deleted} json={c["deletions_total"]}')
    if errs:
        mismatches.append((sha, '; '.join(errs)))
add('6_spot_check_15', not mismatches,
    f'sampled=15 mismatched={len(mismatches)} details={mismatches[:8]}')

# 7. summary
JUNK = ['Co-Authored-By', 'Generated with', 'claude.ai']
toolong = []
empty = []
junky = []
for c in commits:
    s = c.get('summary')
    if not s or not s.strip():
        empty.append(c['sha']); continue
    if len(s) > 140:
        toolong.append((c['sha'], len(s)))
    for j in JUNK:
        if j.lower() in s.lower():
            junky.append((c['sha'], j)); break
c7 = not toolong and not empty and not junky
add('7_summary', c7,
    f'empty={len(empty)}{empty[:3]} over_140={len(toolong)}{toolong[:5]} '
    f'trailer_junk={len(junky)}{junky[:5]}')

ok = all(c['passed'] for c in checks)
failed = [c['name'] for c in checks if not c['passed']]
verdict = 'PASS - no structural problems found' if ok else f'FAIL - {len(failed)} check(s) failed: {failed}'
print(json.dumps({'ok': ok, 'checks': checks, 'problems': problems, 'verdict': verdict}, indent=1))
