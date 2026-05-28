#!/usr/bin/env python3
"""Convert TVal field accesses to method calls for NaN-boxing migration.

Round 2: improved regex that handles comments and complex expressions.
"""

import re
import sys

def convert_field_reads(s):
    """Convert .field read accesses in an expression to method calls."""
    # .number (read) → .get_number()
    s = re.sub(r'(\w[\w.\[\]]*?)\.number\b(?![=(])', r'\1.get_number()', s)
    # .boolean (read) → .get_boolean()
    s = re.sub(r'(\w[\w.\[\]]*?)\.boolean\b(?![=(])', r'\1.get_boolean()', s)
    # .fastint (read) → .get_fastint()
    s = re.sub(r'(\w[\w.\[\]]*?)\.fastint\b(?![=(])', r'\1.get_fastint()', s)
    # .pointer (read) → .get_heapptr()
    s = re.sub(r'(\w[\w.\[\]]*?)\.pointer\b(?![=(])', r'\1.get_heapptr()', s)
    # .tag == TAG → .is_tag()
    tag_map = {
        'UNDEFINED': 'is_undefined', 'NULL_VAL': 'is_null',
        'BOOLEAN': 'is_boolean', 'NUMBER': 'is_number',
        'FASTINT': 'is_fastint', 'STRING': 'is_string',
        'OBJECT': 'is_object', 'BUFFER': 'is_buffer',
        'POINTER': 'is_pointer', 'LIGHTFUNC': 'is_lightfunc',
    }
    for tag_name, method in tag_map.items():
        s = re.sub(r'(\w[\w.\[\]]*?)\.tag\s*==\s*' + tag_name + r'\b', r'\1.' + method + '()', s)
        s = re.sub(r'(\w[\w.\[\]]*?)\.tag\s*!=\s*' + tag_name + r'\b', r'!\1.' + method + '()', s)
    return s

def convert_single_statement(stmt):
    """Convert a single statement (no semicolons) from field access to method calls."""
    # Write patterns first - use (?<!=)=(?!=) to match single = only, not == or !=
    stmt = re.sub(r'(\w[\w.\[\]]*?)\.number\s*(?<!=)=(?!=)\s*(.+)', lambda m: f'{m.group(1)}.set_number({convert_field_reads(m.group(2).strip())})', stmt)
    stmt = re.sub(r'(\w[\w.\[\]]*?)\.boolean\s*(?<!=)=(?!=)\s*(.+)', lambda m: f'{m.group(1)}.set_boolean({convert_field_reads(m.group(2).strip())})', stmt)
    stmt = re.sub(r'(\w[\w.\[\]]*?)\.fastint\s*(?<!=)=(?!=)\s*(.+)', lambda m: f'{m.group(1)}.set_fastint({convert_field_reads(m.group(2).strip())})', stmt)
    stmt = re.sub(r'(\w[\w.\[\]]*?)\.pointer\s*(?<!=)=(?!=)\s*(.+)', lambda m: f'{m.group(1)}.set_object({convert_field_reads(m.group(2).strip())})', stmt)
    
    # Tag assignments (after writes, so tag=value patterns are already consumed)
    tag_map_write = {
        'UNDEFINED': 'set_undefined()', 'NULL_VAL': 'set_null()',
        'BOOLEAN': 'set_boolean(false)  // TODO', 'FASTINT': 'set_fastint(0)  // TODO',
        'NUMBER': 'set_number(0.0)  // TODO', 'STRING': 'set_string(null)  // TODO',
        'OBJECT': 'set_object(null)  // TODO', 'BUFFER': 'set_buffer(null)  // TODO',
        'POINTER': 'set_pointer(null)  // TODO', 'LIGHTFUNC': 'set_lightfunc(null)  // TODO',
    }
    for tag_name, setter in tag_map_write.items():
        stmt = re.sub(r'(\w[\w.\[\]]*?)\.tag\s*=\s*' + tag_name + r'\b', rf'\1.{setter}', stmt)
    
    # Read conversions (after writes)
    stmt = convert_field_reads(stmt)
    return stmt
    # .tag == TAG → .is_tag()
    tag_map = {
        'UNDEFINED': 'is_undefined', 'NULL_VAL': 'is_null',
        'BOOLEAN': 'is_boolean', 'NUMBER': 'is_number',
        'FASTINT': 'is_fastint', 'STRING': 'is_string',
        'OBJECT': 'is_object', 'BUFFER': 'is_buffer',
        'POINTER': 'is_pointer', 'LIGHTFUNC': 'is_lightfunc',
    }
    for tag_name, method in tag_map.items():
        s = re.sub(r'(\w[\w.\[\]]*?)\.tag\s*==\s*' + tag_name + r'\b', r'\1.' + method + '()', s)
        s = re.sub(r'(\w[\w.\[\]]*?)\.tag\s*!=\s*' + tag_name + r'\b', r'!\1.' + method + '()', s)
    return s

def convert_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    
    lines = content.split('\n')
    result = []
    i = 0
    changes = 0
    
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        
        # Skip lines in types.c3 (already converted)
        if 'types.c3' in filepath:
            result.append(line)
            i += 1
            continue
        
        # --- Two-line patterns: tag + value assignment ---
        if i + 1 < len(lines):
            next_line = lines[i + 1]
            next_stripped = next_line.strip()
            
            # Match: <indent><var>.tag = <TAG>;
            tag_match = re.match(r'^(\s*)(\w[\w.\[\]]*?)\.tag\s*=\s*(\w+)\s*;(\s*//.*)?$', line)
            if tag_match:
                indent = tag_match.group(1)
                var = tag_match.group(2)
                tag_name = tag_match.group(3)
                comment = tag_match.group(4) or ''
                
                tag_to_field_setter = {
                    'UNDEFINED': ('.pointer', 'null', 'set_undefined'),
                    'NULL_VAL': ('.pointer', 'null', 'set_null'),
                    'BOOLEAN': ('.boolean', None, 'set_boolean'),
                    'FASTINT': ('.fastint', None, 'set_fastint'),
                    'NUMBER': ('.number', None, 'set_number'),
                    'STRING': ('.pointer', None, 'set_string'),
                    'OBJECT': ('.pointer', None, 'set_object'),
                    'BUFFER': ('.pointer', None, 'set_buffer'),
                    'POINTER': ('.pointer', None, 'set_pointer'),
                    'LIGHTFUNC': ('.pointer', None, 'set_lightfunc'),
                }
                
                if tag_name in tag_to_field_setter:
                    field_name, expected_val, setter = tag_to_field_setter[tag_name]
                    
                    # For UNDEFINED/NULL_VAL, next line must be .pointer = null
                    if expected_val is not None:
                        pat = r'^\s*' + re.escape(var) + re.escape(field_name) + r'\s*=\s*' + re.escape(expected_val) + r'\s*;'
                        if re.match(pat, next_stripped):
                            result.append(f'{indent}{var}.{setter}();{comment}')
                            i += 2
                            changes += 1
                            continue
                    else:
                        # For other tags, match: <var><field> = <value>;
                        # The value can be anything up to the semicolon (may include parens)
                        pat = r'^\s*' + re.escape(var) + re.escape(field_name) + r'\s*=\s*(.+?)\s*;(\s*//.*)?$'
                        m2 = re.match(pat, next_stripped)
                        if m2:
                            val = m2.group(1).strip()
                            next_comment = m2.group(2) or ''
                            # Apply single-line field read conversions to the value
                            val = convert_field_reads(val)
                            result.append(f'{indent}{var}.{setter}({val});{next_comment}')
                            i += 2
                            changes += 1
                            continue
        
        # --- Single-line conversions ---
        
        # Process same-line compound statements by splitting on ;
        # e.g., "ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return;"
        if ';' in stripped and '.tag' in line and ('.pointer' in line or '.number' in line or '.boolean' in line or '.fastint' in line):
            parts = line.split(';')
            processed_parts = []
            for part in parts:
                part = convert_single_statement(part)
                processed_parts.append(part)
            line = ';'.join(processed_parts)
        else:
            # switch (var.tag) → switch (var.get_tag())
            line = re.sub(r'switch\s*\((\w[\w.\[\]]*?)\.tag\)', r'switch (\1.get_tag())', line)
            
            # Tag comparisons
            tag_map = {
                'UNDEFINED': 'is_undefined', 'NULL_VAL': 'is_null',
                'BOOLEAN': 'is_boolean', 'NUMBER': 'is_number',
                'FASTINT': 'is_fastint', 'STRING': 'is_string',
                'OBJECT': 'is_object', 'BUFFER': 'is_buffer',
                'POINTER': 'is_pointer', 'LIGHTFUNC': 'is_lightfunc',
            }
            for tag_name, method in tag_map.items():
                line = re.sub(r'(\w[\w.\[\]]*?)\.tag\s*==\s*' + tag_name + r'\b', r'\1.' + method + '()', line)
                line = re.sub(r'(\w[\w.\[\]]*?)\.tag\s*!=\s*' + tag_name + r'\b', r'!\1.' + method + '()', line)
            
            # var.tag == var.tag
            line = re.sub(r'(\w[\w.\[\]]*?)\.tag\s*==\s*(\w[\w.\[\]]*?)\.tag\b', r'\1.get_tag() == \2.get_tag()', line)
            line = re.sub(r'(\w[\w.\[\]]*?)\.tag\s*!=\s*(\w[\w.\[\]]*?)\.tag\b', r'\1.get_tag() != \2.get_tag()', line)
            
            # Write patterns (BEFORE reads) - use (?<!=)=(?!=) to match single = only
            line = re.sub(
                r'(\w[\w.\[\]]*?)\.number\s*(?<!=)=(?!=)\s*(.+)',
                lambda m: f'{m.group(1)}.set_number({convert_field_reads(m.group(2).rstrip(";").strip())});',
                line
            )
            line = re.sub(
                r'(\w[\w.\[\]]*?)\.boolean\s*(?<!=)=(?!=)\s*(.+)',
                lambda m: f'{m.group(1)}.set_boolean({convert_field_reads(m.group(2).rstrip(";").strip())});',
                line
            )
            line = re.sub(
                r'(\w[\w.\[\]]*?)\.fastint\s*(?<!=)=(?!=)\s*(.+)',
                lambda m: f'{m.group(1)}.set_fastint({convert_field_reads(m.group(2).rstrip(";").strip())});',
                line
            )
            line = re.sub(
                r'(\w[\w.\[\]]*?)\.pointer\s*(?<!=)=(?!=)\s*(.+)',
                lambda m: f'{m.group(1)}.set_object({convert_field_reads(m.group(2).rstrip(";").strip())});',
                line
            )
            
            # Standalone tag assignments
            tag_only_match = re.match(r'^(\s*)(\w[\w.\[\]]*?)\.tag\s*=\s*(\w+)\s*;(\s*//.*)?$', line)
            if tag_only_match:
                indent = tag_only_match.group(1)
                var = tag_only_match.group(2)
                tag_name = tag_only_match.group(3)
                comment = tag_only_match.group(4) or ''
                setter_map = {
                    'UNDEFINED': 'set_undefined()', 'NULL_VAL': 'set_null()',
                    'BOOLEAN': 'set_boolean(false)  // TODO: verify value',
                    'FASTINT': 'set_fastint(0)  // TODO: verify value',
                    'NUMBER': 'set_number(0.0)  // TODO: verify value',
                    'STRING': 'set_string(null)  // TODO: verify value',
                    'OBJECT': 'set_object(null)  // TODO: verify value',
                    'BUFFER': 'set_buffer(null)  // TODO: verify value',
                    'POINTER': 'set_pointer(null)  // TODO: verify value',
                    'LIGHTFUNC': 'set_lightfunc(null)  // TODO: verify value',
                }
                if tag_name in setter_map:
                    line = f'{indent}{var}.{setter_map[tag_name]};{comment}'
                    changes += 1
            
            # Read conversions (AFTER writes)
            line = convert_field_reads(line)
        
        result.append(line)
        i += 1
    
    with open(filepath, 'w') as f:
        f.write('\n'.join(result))
    
    return changes

if __name__ == '__main__':
    total = 0
    for filepath in sys.argv[1:]:
        n = convert_file(filepath)
        print(f'{filepath}: {n} two-line patterns converted')
        total += n
    print(f'Total: {total} two-line patterns converted')
