#!/usr/bin/env python3
"""
Extract full git commit log with metadata and changed files.
"""
import json
import subprocess
import re
from pathlib import Path
from collections import defaultdict

def run_git(args, text=True):
    """Run git command and return output."""
    result = subprocess.run(
        ['git'] + args,
        cwd='/Users/rtomasi/cousas/duktape-c3',
        capture_output=True,
        text=text
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {args} failed: {result.stderr}")
    return result.stdout

def get_head_commits():
    """Get set of commits reachable from HEAD."""
    output = run_git(['rev-list', 'HEAD'])
    return set(line.strip() for line in output.split('\n') if line.strip())

def parse_trailers(body):
    """
    Extract trailer lines from commit body.
    Handles literal \\n escapes by normalizing them first.
    Returns (trailer_raw, trailer_model, trailer_harness).
    """
    # Normalize literal \n escapes to real newlines
    body_normalized = body.replace('\\n', '\n')

    trailer_raw = []
    trailer_model = None
    trailer_harness = None

    lines = body_normalized.split('\n')

    for line in lines:
        line = line.rstrip()
        # Trailer lines typically have format: Key: Value or Key-Name: Value
        if not line or ': ' not in line:
            continue

        key, _, value = line.partition(': ')
        key = key.strip()
        value = value.strip()

        # Check for Co-Authored-By (case-insensitive)
        if key.lower() == 'co-authored-by':
            trailer_raw.append(line)
            # Parse model from Co-Authored-By line
            # Format: "Claude Opus 5 <noreply@anthropic.com>" or similar
            if '<noreply@anthropic.com>' in value:
                # Extract the model name (everything before <)
                model_part = value.split('<')[0].strip()
                if model_part and not model_part[0].isupper():
                    # Skip if it looks like prose (lowercase start)
                    pass
                elif model_part:
                    trailer_model = model_part
                    trailer_harness = 'claude-code'
        elif key.lower() == 'assisted-by':
            trailer_raw.append(line)
            # Format: "Crush:MiniMax-M3" or similar
            if 'crush' in value.lower():
                trailer_harness = 'crush'
                # Extract model if present after colon
                if ':' in value:
                    model_part = value.split(':', 1)[1].strip()
                    if model_part:
                        trailer_model = model_part
        elif key == 'Claude-Session' or 'claude.ai/code' in line:
            trailer_raw.append(line)
            if not trailer_harness:
                trailer_harness = 'claude-code'

    # Additional check for claude-code markers in body text
    if 'Claude-Session:' in body or 'claude.ai/code' in body:
        if not trailer_harness:
            trailer_harness = 'claude-code'

    # Check for crush markers
    if 'Generated with Crush' in body:
        if not trailer_harness:
            trailer_harness = 'crush'

    return (trailer_raw, trailer_model, trailer_harness)

def is_source_file(path):
    """
    Check if a path is a source file.
    Excludes: test/, tests/, test262/, benchmarks/, plans/, docs/,
    test262_results/, .worktrees/, out/, build/, node_modules/,
    quickjs/, duktape/, and certain extensions.
    """
    p = Path(path)
    parts = p.parts

    # Check excluded directories
    excluded_dirs = {
        'test', 'tests', 'test262', 'benchmarks', 'plans', 'docs',
        'test262_results', '.worktrees', 'out', 'build', 'node_modules',
        'quickjs', 'duktape'
    }

    if any(part in excluded_dirs for part in parts):
        return False

    # Check excluded extensions
    excluded_exts = {'.md', '.expected', '.json', '.txt', '.lock'}
    if p.suffix.lower() in excluded_exts:
        return False

    # Check for source extensions
    source_exts = {'.c3', '.c', '.h', '.sh', '.py'}
    if p.suffix.lower() in source_exts:
        return True

    # .js only if under src/, cli/, or scripts/
    if p.suffix.lower() == '.js':
        for part in parts:
            if part in ('src', 'cli', 'scripts'):
                return True
        return False

    return False

def get_commit_files(sha):
    """Get numstat for a commit."""
    output = run_git(['show', '--numstat', '--format=', sha])
    files = []
    insertions_total = 0
    deletions_total = 0
    insertions_source = 0
    deletions_source = 0

    for line in output.strip().split('\n'):
        if not line.strip():
            continue

        parts = line.split('\t', 2)
        if len(parts) < 3:
            continue

        added_str, deleted_str, path = parts[0], parts[1], parts[2]

        # Handle renames (a => b format) - use final path
        if ' => ' in path:
            path = path.split(' => ')[1]

        # Handle binary files (- for counts)
        try:
            added = int(added_str) if added_str != '-' else 0
            deleted = int(deleted_str) if deleted_str != '-' else 0
        except ValueError:
            added = 0
            deleted = 0

        is_src = is_source_file(path)

        files.append({
            'path': path,
            'added': added,
            'deleted': deleted,
            'is_source': is_src
        })

        insertions_total += added
        deletions_total += deleted
        if is_src:
            insertions_source += added
            deletions_source += deleted

    return files, insertions_total, deletions_total, insertions_source, deletions_source

def extract_commits():
    """Extract all commits from git log."""
    # Get commits reachable from HEAD
    head_commits = get_head_commits()

    # Extract commit metadata with custom separator
    sep_record = '\x1e'  # Record separator
    sep_field = '\x1f'   # Field separator
    fmt = f'%H{sep_field}%an{sep_field}%ae{sep_field}%aI{sep_field}%cI{sep_field}%P{sep_field}%s{sep_field}%b{sep_record}'

    output = run_git(['log', '--all', '--format=' + fmt])

    commits = []

    for record in output.split(sep_record):
        if not record.strip():
            continue

        fields = record.split(sep_field, 7)
        if len(fields) < 8:
            continue

        sha, author_name, author_email, author_date, commit_date, parents_str, subject, body = fields

        sha = sha.strip()
        short_sha = sha[:7]
        author_name = author_name.strip()
        author_email = author_email.strip()
        author_date = author_date.strip()
        commit_date = commit_date.strip()
        subject = subject.strip()
        body = body.strip()

        parents = [p.strip() for p in parents_str.split() if p.strip()]
        is_merge = len(parents) > 1
        on_head = sha in head_commits

        # Parse trailers
        trailer_raw, trailer_model, trailer_harness = parse_trailers(body)

        # Get file changes
        files, ins_total, dels_total, ins_src, dels_src = get_commit_files(sha)

        commit = {
            'sha': sha,
            'short_sha': short_sha,
            'author_name': author_name,
            'author_email': author_email,
            'author_date': author_date,
            'commit_date': commit_date,
            'parents': parents,
            'is_merge': is_merge,
            'subject': subject,
            'body': body,
            'files': files,
            'insertions_total': ins_total,
            'deletions_total': dels_total,
            'insertions_source': ins_src,
            'deletions_source': dels_src,
            'trailer_raw': trailer_raw,
            'trailer_model': trailer_model,
            'trailer_harness': trailer_harness,
            'on_head': on_head
        }

        commits.append(commit)

    # Sort by author_date (oldest first)
    commits.sort(key=lambda c: c['author_date'])

    return commits

def main():
    print("Extracting commits...")
    commits = extract_commits()

    # Write to JSON
    output_path = Path('/Users/rtomasi/cousas/duktape-c3/.attrib/commits.json')
    with open(output_path, 'w') as f:
        json.dump(commits, f, indent=2)

    # Count trailers
    with_trailer = sum(1 for c in commits if c['trailer_harness'] is not None)
    without_trailer = len(commits) - with_trailer

    trailer_kinds = defaultdict(int)
    for c in commits:
        if c['trailer_harness']:
            trailer_kinds[c['trailer_harness']] += 1

    result = {
        'file': str(output_path),
        'commit_count': len(commits),
        'with_trailer': with_trailer,
        'without_trailer': without_trailer,
        'trailer_kinds': dict(trailer_kinds),
        'notes': f"Extracted {len(commits)} commits from git log --all; ordered by author_date oldest-first"
    }

    print(json.dumps(result, indent=2))
    return result

if __name__ == '__main__':
    main()
