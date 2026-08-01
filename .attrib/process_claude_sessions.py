#!/usr/bin/env python3
"""
Index Claude Code session transcripts into evidence_claude.json.
Process JSONL files from all duktape-c3 project directories.
"""

import json
import os
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Any, Set
import re

# Find all duktape-c3 project directories
PROJECTS_BASE = Path("/Users/rtomasi/.claude/projects")
PROJECT_DIRS = sorted([
    d for d in PROJECTS_BASE.iterdir()
    if d.is_dir() and "duktape-c3" in d.name
])

OUTPUT_FILE = Path("/Users/rtomasi/cousas/duktape-c3/.attrib/evidence_claude.json")

# Normalized model names (map aliases to canonical names, keep raw value)
MODEL_ALIASES = {
    'opus': 'claude-opus-5',
    'sonnet': 'claude-sonnet-4-8',
    'haiku': 'claude-haiku-4-5',
}


def normalize_model(raw_model: str) -> tuple[str, str]:
    """Return (normalized_name, raw_value)."""
    if not raw_model or raw_model == '<synthetic>':
        return None, raw_model

    normalized = MODEL_ALIASES.get(raw_model, raw_model)
    return normalized, raw_model


def extract_commit_message(command: str) -> tuple[str, str]:
    """
    Extract commit message from git commit command.
    Returns (subject, full_message_head).
    Handles: -m "text", $(cat <<'EOF' ... EOF)
    """
    # Handle heredoc: -m "$(cat <<'EOF'\n...\nEOF)"
    # The heredoc content is everything between <<'EOF'\n and \nEOF
    m = re.search(r'-m\s+"[^"]*<<[\'"]EOF[\'"](.+?)(EOF|$)', command, re.DOTALL)
    if m:
        full = m.group(1).strip()
        subject = full.split('\n')[0] if '\n' in full else full
        return subject, full

    # Handle simple -m "message" or -m 'message'
    m = re.search(r'-m\s+["\']([^"\']*)["\']', command)
    if m:
        full = m.group(1)
        subject = full.split('\n')[0] if '\n' in full else full
        return subject, full

    return None, None


def process_jsonl_file(filepath: Path) -> Dict[str, Any]:
    """
    Process a single JSONL file and extract session spans and commit invocations.
    Returns {'session_spans': [...], 'commits': [...]}
    """
    session_data: Dict[str, Dict] = {}  # session_id -> {model, timestamps, msg_count}
    commits = []

    try:
        with open(filepath, 'r') as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue

                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    print(f"Warning: Failed to parse JSON at {filepath.name}:{line_num}")
                    continue

                if event.get('type') != 'assistant':
                    continue

                session_id = event.get('sessionId') or event.get('session_id')
                if not session_id:
                    continue

                timestamp = event.get('timestamp')
                if not timestamp:
                    continue

                model_raw = event.get('message', {}).get('model')
                if not model_raw:
                    continue

                model_norm, model_raw_val = normalize_model(model_raw)
                if model_norm is None:
                    continue

                # Track session spans
                if session_id not in session_data:
                    session_data[session_id] = {
                        'model': model_norm,
                        'model_raw': model_raw_val,
                        'timestamps': [],
                        'msg_count': 0
                    }

                session_data[session_id]['timestamps'].append(timestamp)
                session_data[session_id]['msg_count'] += 1

                # Extract commit invocations
                content = event.get('message', {}).get('content', [])
                for item in content:
                    if item.get('type') == 'tool_use' and item.get('name') == 'Bash':
                        command = item.get('input', {}).get('command', '')
                        if 'git commit' in command:
                            subject, full_msg = extract_commit_message(command)
                            if subject:
                                commits.append({
                                    'kind': 'commit_invocation',
                                    'session_id': session_id,
                                    'model': model_norm,
                                    'model_raw': model_raw_val,
                                    'ts': timestamp,
                                    'subject': subject,
                                    'full_message_head': full_msg[:200] if full_msg else None,
                                    'model_source': 'message'
                                })

    except Exception as e:
        print(f"Error processing {filepath}: {e}")

    # Convert session data to session_span events
    session_spans = []
    for session_id, data in session_data.items():
        if data['timestamps']:
            timestamps = sorted(data['timestamps'])
            session_spans.append({
                'kind': 'session_span',
                'session_id': session_id,
                'model': data['model'],
                'model_raw': data['model_raw'],
                'provider': 'anthropic',
                'start_ts': timestamps[0],
                'end_ts': timestamps[-1],
                'msg_count': data['msg_count']
            })

    return {
        'session_spans': session_spans,
        'commits': commits
    }


def main():
    print(f"Found {len(PROJECT_DIRS)} project directories:")
    for d in PROJECT_DIRS:
        print(f"  {d.name}")

    all_events = []
    all_models = set()
    all_sessions = set()
    commit_count = 0

    for project_dir in PROJECT_DIRS:
        jsonl_files = sorted(project_dir.glob('*.jsonl'))
        print(f"\nProcessing {project_dir.name}: {len(jsonl_files)} files")

        for jsonl_file in jsonl_files:
            result = process_jsonl_file(jsonl_file)

            for span in result['session_spans']:
                all_events.append(span)
                all_models.add(span['model'])
                all_sessions.add(span['session_id'])

            for commit in result['commits']:
                all_events.append(commit)
                commit_count += 1
                all_models.add(commit['model'])
                all_sessions.add(commit['session_id'])

    # Sort events by timestamp
    all_events.sort(key=lambda x: x.get('ts') or x.get('start_ts', ''))

    # Calculate time range
    ts_values = []
    for event in all_events:
        if event.get('ts'):
            ts_values.append(event['ts'])
        elif event.get('start_ts'):
            ts_values.append(event['start_ts'])
        if event.get('end_ts'):
            ts_values.append(event['end_ts'])

    time_range = None
    if ts_values:
        ts_values.sort()
        time_range = f"{ts_values[0]} to {ts_values[-1]}"

    # Build model breakdown
    model_breakdown = {}
    for event in all_events:
        model = event.get('model')
        if model:
            model_breakdown[model] = model_breakdown.get(model, 0) + 1

    # Write output
    output = {
        "harness": "claude-code",
        "events": all_events
    }

    with open(OUTPUT_FILE, 'w') as f:
        json.dump(output, f, indent=2)

    print(f"\nWrote {OUTPUT_FILE}")
    print(f"Total events: {len(all_events)}")
    print(f"Commit invocations: {commit_count}")
    print(f"Distinct models: {len(all_models)}")
    print(f"Distinct sessions: {len(all_sessions)}")
    print(f"Time range: {time_range}")
    print(f"Model breakdown: {model_breakdown}")

    # Validate output
    with open(OUTPUT_FILE, 'r') as f:
        data = json.load(f)
        assert data['harness'] == 'claude-code'
        assert len(data['events']) == len(all_events)

    print("\nValidation: OK")

    return {
        'file': str(OUTPUT_FILE),
        'event_count': len(all_events),
        'commit_events': commit_count,
        'distinct_models': len(all_models),
        'time_range': time_range,
        'model_breakdown': model_breakdown,
        'notes': f"Processed {len(PROJECT_DIRS)} project directories with {sum(len(list(d.glob('*.jsonl'))) for d in PROJECT_DIRS)} JSONL files"
    }


if __name__ == '__main__':
    result = main()
    print(json.dumps(result, indent=2))
