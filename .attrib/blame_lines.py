#!/usr/bin/env python3
"""Attribute SURVIVING lines of the final source tree to models.

This is deliberately not a rollup of insertions_source from the commit log: in a
repo with this much churn most authored lines were later rewritten, so only
`git blame` on HEAD says who wrote the code that actually still exists.

Method: git blame --line-porcelain per file, mapping each surviving line to its
last-touching commit, then joining that sha to the attribution in commit_log.json.

Notes on fidelity:
  -w   ignore whitespace-only changes, so a reindent does not steal authorship
  -M   detect moves within a file
  -C   detect moves/copies between files in the same commit
  Blame credits the LAST commit to touch a line, which is the standard and honest
  reading of "who wrote the code that is here now".

libregexp/ is a vendored third-party import (9,936 lines landed in one commit,
bede535b "add libregexp"). It is tracked separately and excluded from model
totals by default, since crediting it to whichever model ran the import would be
wrong. Later genuine edits to those files still show up under 'libregexp_edits'.
"""
import json, subprocess, sys, os
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

REPO = '/Users/rtomasi/cousas/duktape-c3'
OUT = REPO + '/.attrib'

log = json.load(open(f'{OUT}/commit_log.json'))
ATTR = {c['sha']: c for c in log['commits']}

VENDORED_PREFIXES = ('libregexp/',)
VENDOR_IMPORT_SHA_PREFIX = 'bede535b'


def source_files():
    out = subprocess.run(
        ['git', '-C', REPO, 'ls-files', '*.c3', '*.c', '*.h', '*.sh', '*.py'],
        capture_output=True, text=True, check=True).stdout.split('\n')
    return [f for f in out if f.strip()]


def blame(path):
    """Return list of (sha, is_blank) for each surviving line of path."""
    try:
        r = subprocess.run(
            ['git', '-C', REPO, 'blame', '--line-porcelain', '-w', '-M', '-C', 'HEAD', '--', path],
            capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            return path, None, (r.stderr or '')[:200]
    except subprocess.TimeoutExpired:
        return path, None, 'timeout'

    lines = []
    sha = None
    for ln in r.stdout.split('\n'):
        if not ln:
            continue
        if ln[0] == '\t':
            # the actual source line follows the header block
            lines.append((sha, ln[1:].strip() == ''))
        elif ' ' in ln and len(ln.split(' ')[0]) == 40 and all(
                ch in '0123456789abcdef' for ch in ln.split(' ')[0]):
            sha = ln.split(' ')[0]
    return path, lines, None


def main():
    files = source_files()
    print(f'blaming {len(files)} files...', file=sys.stderr)

    results = {}
    errors = {}
    with ThreadPoolExecutor(max_workers=8) as ex:
        for path, lines, err in ex.map(blame, files):
            if err:
                errors[path] = err
            else:
                results[path] = lines

    per_model = Counter()          # non-blank, non-vendored surviving lines
    per_model_blank = Counter()
    per_harness = Counter()
    per_vendor = Counter()
    per_quality = Counter()
    per_area = defaultdict(Counter)
    per_file = {}
    vendored = Counter()
    vendor_import_lines = 0
    unknown_sha = Counter()
    total_lines = 0
    total_code = 0

    for path, lines in results.items():
        is_vendored = path.startswith(VENDORED_PREFIXES)
        fc = Counter()
        for sha, blank in lines:
            total_lines += 1
            if not blank:
                total_code += 1

            c = ATTR.get(sha)
            if c is None:
                unknown_sha[sha[:8]] += 1
                model = None
                harness = vendorname = quality = None
            else:
                a = c['attribution']
                model = a.get('model')
                harness = a.get('harness')
                vendorname = a.get('vendor')
                quality = a.get('attribution_quality')

            if is_vendored:
                if sha and sha.startswith(VENDOR_IMPORT_SHA_PREFIX):
                    if not blank:
                        vendor_import_lines += 1
                    continue
                # a genuine later edit to a vendored file
                if not blank:
                    vendored[model or 'unknown'] += 1
                continue

            key = model or 'unattributed'
            if blank:
                per_model_blank[key] += 1
                continue
            per_model[key] += 1
            per_harness[harness or 'unknown'] += 1
            per_vendor[vendorname or 'unknown'] += 1
            per_quality[quality or 'none'] += 1
            per_area[(path.split('/')[0] if '/' in path else '.')][key] += 1
            fc[key] += 1
        per_file[path] = dict(fc)

    doc = {
        'generated_from': 'git blame HEAD -w -M -C',
        'note': ('Surviving lines only: each line credited to the LAST commit that touched it. '
                 'Blank lines counted separately and excluded from the model totals.'),
        'totals': {
            'files_blamed': len(results),
            'files_failed': len(errors),
            'lines_total_all_files': total_lines,
            'lines_nonblank_all_files': total_code,
            'lines_attributed_nonblank': sum(per_model.values()),
            'lines_blank_excluded': sum(per_model_blank.values()),
            'vendored_import_lines_excluded': vendor_import_lines,
            'vendored_later_edits': sum(vendored.values()),
        },
        'by_model': dict(per_model.most_common()),
        'by_harness': dict(per_harness.most_common()),
        'by_vendor': dict(per_vendor.most_common()),
        'by_attribution_quality': dict(per_quality),
        'by_area': {k: dict(v.most_common()) for k, v in per_area.items()},
        'vendored_libregexp_later_edits_by_model': dict(vendored.most_common()),
        'unknown_shas': dict(unknown_sha.most_common(10)),
        'per_file': per_file,
        'errors': errors,
    }
    json.dump(doc, open(f'{OUT}/line_attribution.json', 'w'), indent=1)

    T = sum(per_model.values())
    print(f'\nfiles {len(results)} ok, {len(errors)} failed')
    print(f'surviving non-blank attributable lines: {T}')
    print(f'vendored libregexp import excluded: {vendor_import_lines}')
    print('\n-- by model --')
    for k, v in per_model.most_common(20):
        print(f'  {k:28} {v:7}  {100*v/T:5.1f}%')
    print('\n-- by harness --')
    for k, v in per_harness.most_common():
        print(f'  {k:14} {v:7}  {100*v/T:5.1f}%')
    print('\n-- by attribution quality --')
    for k, v in per_quality.most_common():
        print(f'  {k:8} {v:7}  {100*v/T:5.1f}%')
    if unknown_sha:
        print(f'\nunknown shas (not in commit_log): {sum(unknown_sha.values())} lines')


if __name__ == '__main__':
    main()
