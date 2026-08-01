#!/usr/bin/env python3
"""Label the residual unattributed work as Pi.

Rationale (user's call): Pi is the one harness with no local session store on
this machine, so its work can carry neither a commit trailer nor a transcript.
Anything that survived every other attribution path -- no trailer, no recoverable
`git commit` invocation, and no active session window in Crush, OpenCode, or
Claude Code -- is by elimination the harness we cannot see.

This is inference from absence, not evidence, so the rows keep
attribution_quality 'none' and gain `inferred_by_elimination: true`. Charts that
filter on quality still exclude them; charts that group by harness now show Pi
rather than a blank.

Two exclusions, because "unattributed" is not the same as "Pi":
  - the vendored libregexp import (9,936 lines landed in one commit) is
    third-party code and is credited to no model at all;
  - merge commits, which carry no authorship of their own.
"""
import json
from collections import Counter

OUT = '/Users/rtomasi/cousas/duktape-c3/.attrib'
VENDOR_IMPORT = 'bede535'

log = json.load(open(f'{OUT}/commit_log.json'))

labeled = skipped = 0
for c in log['commits']:
    a = c['attribution']
    if a.get('harness') or a.get('model'):
        continue
    if c['short_sha'].startswith(VENDOR_IMPORT):
        a['vendor_import'] = True
        a['span_note'] = 'third-party libregexp import; not model-authored'
        skipped += 1
        continue
    if c.get('is_merge'):
        skipped += 1
        continue
    a['harness'] = 'pi'
    a['model'] = 'pi (unidentified)'
    a['vendor'] = 'pi'
    a['method'] = 'elimination'
    a['attribution_quality'] = 'none'
    a['inferred_by_elimination'] = True
    a['span_note'] = ('no trailer, no commit invocation, and no active session in the '
                      'Crush/OpenCode/Claude Code stores; Pi kept no local store')
    labeled += 1

log['quality_counts'] = dict(Counter(c['attribution'].get('attribution_quality')
                                     for c in log['commits']))
log['method_counts'] = dict(Counter(c['attribution'].get('method') for c in log['commits']))
log.setdefault('known_limitations', []).append(
    'Commits with no trailer, no invocation match, and no session window are labeled '
    'harness "pi" by elimination (Pi kept no local session store). This is inference '
    'from absence: those rows keep attribution_quality "none".')

json.dump(log, open(f'{OUT}/commit_log.json', 'w'), indent=1, default=str)

head = [c for c in log['commits'] if c.get('on_head')]
pi = [c for c in head if c['attribution'].get('harness') == 'pi']
print(f'labeled {labeled} commits as pi ({skipped} skipped: vendor import + merges)')
print(f'on HEAD: {len(pi)} pi commits, '
      f'{sum(c["insertions_source"] for c in pi):,} source lines written')
print('by month:', dict(sorted(Counter(c['author_date'][:7] for c in pi).items())))
