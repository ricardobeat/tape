#!/usr/bin/env python3
"""
Index OpenCode harness session store for evidence extraction.
Extracts commit invocations and session spans from the opencode.db.
"""

import sqlite3
import json
import re
from datetime import datetime
from typing import Optional, Dict, List, Any, Tuple

DB_PATH = '/Users/rtomasi/.local/share/opencode/opencode.db'
PROJECT_ID = '43ec93a49c9da24ec1679d7b5580bc8b83f9ab0f'
MAIN_WORKTREE = '/Users/rtomasi/cousas/duktape-c3'

def ms_to_iso(ms: int) -> str:
    """Convert milliseconds since epoch to ISO 8601 string."""
    if ms is None:
        return None
    return datetime.utcfromtimestamp(ms / 1000).isoformat() + 'Z'

def parse_commit_message(command: str) -> Optional[Tuple[str, str]]:
    """
    Extract commit message from git commit command.
    Returns (subject, full_message) or None if not a commit command.
    Handles: -m "...", -m '...', and heredoc forms.
    """
    if 'git commit' not in command:
        return None

    # Try -m "..." form
    match = re.search(r'-m\s+"([^"]*)"', command)
    if match:
        msg = match.group(1)
        # Unescape common escapes
        msg = msg.replace('\\n', '\n')
        return (msg.split('\n')[0], msg)

    # Try -m '...' form
    match = re.search(r"-m\s+'([^']*)'", command)
    if match:
        msg = match.group(1)
        msg = msg.replace('\\n', '\n')
        return (msg.split('\n')[0], msg)

    # Try heredoc form: $(cat <<'EOF' ... EOF)
    match = re.search(r"\$\(cat <<'EOF'\s*(.*?)\s*EOF\s*\)", command, re.DOTALL)
    if match:
        msg = match.group(1).strip()
        return (msg.split('\n')[0], msg)

    return None

def get_directory_filter(cursor, project_id: str) -> List[str]:
    """Get list of directories to filter sessions."""
    directories = [MAIN_WORKTREE]

    # Get sandboxes from project
    cursor.execute("SELECT sandboxes FROM project WHERE id = ?", (project_id,))
    result = cursor.fetchone()
    if result and result[0]:
        try:
            sandboxes = json.loads(result[0])
            directories.extend(sandboxes)
        except:
            pass

    return directories

def session_in_scope(session: Dict[str, Any], directories: List[str]) -> bool:
    """Check if session is in scope for this project."""
    session_dir = session.get('directory', '')
    session_path = session.get('path', '')

    for directory in directories:
        if session_dir == directory or session_path == directory:
            return True
        # Check if it's under the directory (for .worktrees subdirs)
        if session_dir and session_dir.startswith(directory + '/'):
            return True
        if session_path and session_path.startswith(directory + '/'):
            return True

    return False

def main():
    """Main indexing function."""
    conn = sqlite3.connect(f'file:{DB_PATH}?mode=ro&immutable=1', uri=True)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    # Get directory filter
    directories = get_directory_filter(cursor, PROJECT_ID)

    # Get all sessions for this project
    cursor.execute("""
        SELECT id, project_id, directory, path, title, model, agent,
               time_created, time_updated
        FROM session
        WHERE project_id = ?
    """, (PROJECT_ID,))

    all_sessions = cursor.fetchall()
    sessions = []
    for row in all_sessions:
        session = dict(row)
        if session_in_scope(session, directories):
            sessions.append(session)

    total_sessions = len(all_sessions)
    scoped_sessions = len(sessions)
    session_ids = {s['id'] for s in sessions}

    print(f"Total sessions: {total_sessions}, Scoped to this project: {scoped_sessions}")

    # Collect events
    events = []
    models_seen = set()
    commit_count = 0

    # (A) COMMIT_INVOCATION events
    # Get all parts that are bash/shell tools with git commit commands
    cursor.execute("""
        SELECT p.id, p.message_id, p.session_id, p.time_created, p.data,
               m.data as message_data, s.model as session_model
        FROM part p
        JOIN message m ON p.message_id = m.id
        JOIN session s ON p.session_id = s.id
        WHERE p.session_id IN ({})
          AND p.data IS NOT NULL
    """.format(','.join('?' * len(session_ids))), tuple(session_ids))

    parts = cursor.fetchall()
    for part in parts:
        try:
            part_data = json.loads(part['data'])
            msg_data = json.loads(part['message_data'])
        except:
            continue

        # Check if this is a bash/shell tool
        tool_name = part_data.get('tool', '')
        if tool_name not in ['bash', 'shell', 'Bash']:
            continue

        # Get the command from input
        tool_input = part_data.get('state', {}).get('input', {})
        command = tool_input.get('command', '') if isinstance(tool_input, dict) else ''

        # Check if it's a commit command
        msg_result = parse_commit_message(command)
        if not msg_result:
            continue

        subject, full_message = msg_result

        # Get model and provider
        model = msg_data.get('modelID', None)
        provider = msg_data.get('providerID', None)
        model_source = 'message'

        if not model:
            model = part['session_model']
            model_source = 'session'

        if model:
            models_seen.add(model)

        ts = ms_to_iso(part['time_created'])

        event = {
            'kind': 'commit_invocation',
            'session_id': part['session_id'],
            'model': model,
            'provider': provider,
            'ts': ts,
            'subject': subject,
            'full_message_head': full_message[:200] if full_message else '',
            'model_source': model_source
        }
        events.append(event)
        commit_count += 1

    print(f"Found {commit_count} commit invocations")

    # (B) SESSION_SPAN events - per session per (modelID, providerID)
    cursor.execute("""
        SELECT m.session_id, m.data, m.time_created
        FROM message m
        WHERE m.session_id IN ({})
          AND m.data IS NOT NULL
        ORDER BY m.session_id, m.time_created
    """.format(','.join('?' * len(session_ids))), tuple(session_ids))

    messages = cursor.fetchall()

    # Group by session and (model, provider)
    session_spans = {}  # (session_id, model, provider) -> (start_ts, end_ts, count)

    for msg in messages:
        try:
            msg_data = json.loads(msg['data'])
        except:
            continue

        role = msg_data.get('role', '')
        if role != 'assistant':
            continue

        model = msg_data.get('modelID', None)
        provider = msg_data.get('providerID', None)

        key = (msg['session_id'], model, provider)
        ts = msg['time_created']

        if key not in session_spans:
            session_spans[key] = [ts, ts, 1]
        else:
            session_spans[key][1] = max(session_spans[key][1], ts)
            session_spans[key][2] += 1

    # Create SESSION_SPAN events
    for (session_id, model, provider), (start_ms, end_ms, count) in session_spans.items():
        if model:
            models_seen.add(model)

        event = {
            'kind': 'session_span',
            'session_id': session_id,
            'model': model,
            'provider': provider,
            'start_ts': ms_to_iso(start_ms),
            'end_ts': ms_to_iso(end_ms),
            'msg_count': count
        }
        events.append(event)

    print(f"Found {len(session_spans)} session spans")

    # Build model breakdown
    model_breakdown = {}
    for event in events:
        if event['kind'] == 'commit_invocation':
            model = event['model']
            if model not in model_breakdown:
                model_breakdown[model] = {'commits': 0, 'spans': 0}
            model_breakdown[model]['commits'] += 1
        elif event['kind'] == 'session_span':
            model = event['model']
            if model not in model_breakdown:
                model_breakdown[model] = {'commits': 0, 'spans': 0}
            model_breakdown[model]['spans'] += 1

    # Get time range
    time_range = None
    if events:
        all_times = []
        for event in events:
            if 'ts' in event and event['ts']:
                all_times.append(event['ts'])
            if 'start_ts' in event and event['start_ts']:
                all_times.append(event['start_ts'])
            if 'end_ts' in event and event['end_ts']:
                all_times.append(event['end_ts'])
        if all_times:
            all_times.sort()
            time_range = f"{all_times[0]}/{all_times[-1]}"

    # Build output
    output = {
        'harness': 'opencode',
        'events': events
    }

    # Write output
    output_file = '/Users/rtomasi/cousas/duktape-c3/.attrib/evidence_opencode.json'
    with open(output_file, 'w') as f:
        json.dump(output, f, indent=2)

    print(f"\nWrote {len(events)} events to {output_file}")

    # Verify output is valid JSON
    with open(output_file, 'r') as f:
        verify = json.load(f)

    assert verify['harness'] == 'opencode'
    assert len(verify['events']) == len(events)
    print(f"Verified output: {len(verify['events'])} events in valid JSON")

    # Summary
    summary = {
        'file': output_file,
        'event_count': len(events),
        'distinct_models': len(models_seen),
        'commit_events': commit_count,
        'time_range': time_range,
        'model_breakdown': model_breakdown,
        'notes': f"Indexed {scoped_sessions}/{total_sessions} sessions in scope for project {PROJECT_ID}"
    }

    print("\n=== SUMMARY ===")
    print(json.dumps(summary, indent=2))

    conn.close()
    return summary

if __name__ == '__main__':
    main()
