#!/usr/bin/env python3
"""
Index Crush harness session store to extract evidence linking models to commits.
"""

import sqlite3
import json
import re
from datetime import datetime
from collections import defaultdict

DB_PATH = '/Users/rtomasi/cousas/duktape-c3/.crush/crush.db'
OUTPUT_PATH = '/Users/rtomasi/cousas/duktape-c3/.attrib/evidence_crush.json'

def unescape_json_string(s):
    """Unescape JSON string literals with \\n and \\" sequences."""
    # Handle the escaped sequences: \\" -> " and \\n -> newline
    s = s.replace('\\"', '"')
    s = s.replace('\\n', '\n')
    return s

def extract_commit_message(command_str):
    """
    Extract commit message from git commit command.
    Handles forms:
      git commit -m "..." or -m '...'
      git commit -m "$(cat <<'EOF' ... EOF)"
    Returns tuple: (subject_line, full_message_head_300chars) or None if not extractable
    """

    # Pattern 1: -m "$(cat <<'EOF' ... EOF)" - the most common form in this codebase
    # This pattern captures from -m " to the closing ")"
    match = re.search(r'-m\s+"?\$\(cat\s+<<[\'"]?EOF[\'"]?\s*\n(.*?)\nEOF\s*\)"', command_str, re.DOTALL)
    if match:
        msg = match.group(1)
        lines = msg.split('\n')
        subject = lines[0].strip()
        head = msg[:300]
        return (subject, head)

    # Pattern 2: Simpler variant without command substitution - -m "..."
    # Must be careful not to match the heredoc above
    if '$(cat <<' not in command_str:
        # Simple quoted message
        match = re.search(r'-m\s+["\']([^"\']*)["\']', command_str, re.DOTALL)
        if match:
            msg = match.group(1)
            msg = unescape_json_string(msg)
            lines = msg.split('\n')
            subject = lines[0].strip()
            head = msg[:300]
            return (subject, head)

    return None

def get_previous_assistant_model(session_id, msg_index, cursor):
    """Get the model from the most recent assistant message before msg_index in the session."""
    # We need to fetch all messages for the session in order
    # This is inefficient but necessary for correctness
    return None  # Will handle via session-wide scan

def parse_messages_for_session(session_id, cursor):
    """
    Parse all messages in a session, tracking model carryover and extracting commits.
    Returns: (commit_events, session_spans)
    """
    cursor.execute("""
        SELECT id, role, model, provider, created_at, parts
        FROM messages
        WHERE session_id = ?
        ORDER BY created_at ASC
    """, (session_id,))

    rows = cursor.fetchall()
    commit_events = []
    session_spans = defaultdict(lambda: {'model': None, 'provider': None, 'first_ts': None, 'last_ts': None, 'msg_count': 0})

    last_assistant_model = {}  # (provider, model) -> model

    for msg_id, role, model, provider, created_at, parts_str in rows:
        ts_iso = datetime.utcfromtimestamp(created_at).isoformat() + 'Z'

        try:
            parts = json.loads(parts_str)
        except:
            continue

        # Track assistant messages for model carryover
        if role == 'assistant' and model and provider:
            last_assistant_model[(provider, model)] = (model, provider)
            # Track session span
            key = (model, provider)
            if session_spans[key]['first_ts'] is None:
                session_spans[key]['first_ts'] = ts_iso
            session_spans[key]['last_ts'] = ts_iso
            session_spans[key]['model'] = model
            session_spans[key]['provider'] = provider
            session_spans[key]['msg_count'] += 1

        # Look for git commit in parts
        for part in parts:
            if part.get('type') == 'tool_call':
                tool_data = part.get('data', {})
                if tool_data.get('name') == 'bash':
                    input_str = tool_data.get('input', '')
                    try:
                        input_obj = json.loads(input_str)
                        command = input_obj.get('command', '')
                    except:
                        command = input_str

                    if 'git commit' in command:
                        result = extract_commit_message(command)
                        if result:
                            subject, head = result

                            # Determine model
                            event_model = model
                            model_source = 'row'

                            if not event_model:
                                # Carry forward from most recent assistant in this session
                                # Find by looking backward in the parsed messages
                                for prev_role, prev_model, prev_provider, _, _ in reversed([(r, m, p, c, parts_str) for id, r, m, p, c, parts_str in rows[:rows.index((msg_id, role, model, provider, created_at, parts_str))]]):
                                    if prev_role == 'assistant' and prev_model:
                                        event_model = prev_model
                                        model_source = 'carried'
                                        provider = prev_provider
                                        break

                            commit_events.append({
                                'kind': 'commit_invocation',
                                'session_id': session_id,
                                'model': event_model,
                                'provider': provider,
                                'ts': ts_iso,
                                'subject': subject,
                                'full_message_head': head,
                                'model_source': model_source
                            })

    return commit_events, session_spans

def main():
    db = sqlite3.connect(f'file:{DB_PATH}?mode=ro&immutable=1', uri=True)
    cursor = db.cursor()

    # Get all sessions
    cursor.execute("SELECT id FROM sessions ORDER BY created_at ASC")
    session_ids = [row[0] for row in cursor.fetchall()]

    all_events = []
    model_stats = defaultdict(int)
    time_range = {'min': None, 'max': None}
    commit_count = 0

    # Process each session
    for session_id in session_ids:
        commit_events, session_spans = parse_messages_for_session(session_id, cursor)

        # Add commit events
        for event in commit_events:
            all_events.append(event)
            model_stats[f"{event['provider']}:{event['model']}"] += 1
            commit_count += 1

            # Update time range
            if time_range['min'] is None or event['ts'] < time_range['min']:
                time_range['min'] = event['ts']
            if time_range['max'] is None or event['ts'] > time_range['max']:
                time_range['max'] = event['ts']

        # Add session span events
        for (model, provider), span_data in session_spans.items():
            all_events.append({
                'kind': 'session_span',
                'session_id': session_id,
                'model': model,
                'provider': provider,
                'start_ts': span_data['first_ts'],
                'end_ts': span_data['last_ts'],
                'msg_count': span_data['msg_count']
            })

            # Update time range
            if span_data['first_ts']:
                if time_range['min'] is None or span_data['first_ts'] < time_range['min']:
                    time_range['min'] = span_data['first_ts']
            if span_data['last_ts']:
                if time_range['max'] is None or span_data['last_ts'] > time_range['max']:
                    time_range['max'] = span_data['last_ts']

    db.close()

    # Write output
    output = {
        'harness': 'crush',
        'events': all_events
    }

    with open(OUTPUT_PATH, 'w') as f:
        json.dump(output, f, indent=2)

    # Verify output
    with open(OUTPUT_PATH, 'r') as f:
        verify = json.load(f)

    distinct_models = len(set(e['model'] for e in all_events if 'model' in e and e['model']))

    print(f"✓ Written to {OUTPUT_PATH}")
    print(f"  Total events: {len(all_events)}")
    print(f"  Commit invocations: {commit_count}")
    print(f"  Distinct models: {distinct_models}")
    print(f"  Time range: {time_range['min']} to {time_range['max']}")
    print(f"  Model breakdown: {dict(model_stats)}")

if __name__ == '__main__':
    main()
