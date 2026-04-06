#!/usr/bin/env python3
"""Convert fam3.S (GNU as syntax) to fam3.fam2 (fam2 grammar).

Instructions pass through as-is (fam2 supports all RV32I + li/mv/j/ret/beqz/bnez).
Data directives (.ascii, .byte, .zero) convert to hex passthrough bytes.
Labels and comments pass through unchanged.

Usage: python3 tools/emit_fam2.py src/fam3.S > src/fam3.fam2
"""

import sys
import re


def parse_byte_val(s):
    """Parse a single byte value (decimal or 0xHEX) to int."""
    s = s.strip()
    if s.startswith('0x') or s.startswith('0X'):
        return int(s, 16)
    return int(s)


def string_to_hex(s):
    """Convert the contents of a .ascii string literal to byte values."""
    result = []
    i = 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            c = s[i + 1]
            if c == 'n':
                result.append(0x0A)
            elif c == 't':
                result.append(0x09)
            elif c == 'r':
                result.append(0x0D)
            elif c == '0':
                result.append(0x00)
            elif c == '\\':
                result.append(0x5C)
            elif c == '"':
                result.append(0x22)
            else:
                result.append(ord(c))
            i += 2
        else:
            result.append(ord(s[i]))
            i += 1
    return result


def fmt_hex(byte_list):
    """Format a list of byte values as a hex string."""
    return ' '.join(f'{b:02X}' for b in byte_list)


def convert_directive(stmt):
    """Convert a single GNU as directive to hex bytes. Returns hex string or None."""
    stmt = stmt.strip()

    # .ascii "..."
    m = re.match(r'\.ascii\s+"(.*)"', stmt)
    if m:
        return fmt_hex(string_to_hex(m.group(1)))

    # .zero N
    m = re.match(r'\.zero\s+(\d+)', stmt)
    if m:
        n = int(m.group(1))
        return fmt_hex([0] * n)

    # .byte v1, v2, ...
    m = re.match(r'\.byte\s+(.*)', stmt)
    if m:
        vals = [parse_byte_val(v) for v in m.group(1).split(',')]
        return fmt_hex(vals)

    return None


def split_statements(code):
    """Split a code portion by semicolons, respecting quoted strings."""
    parts = []
    current = []
    in_string = False
    for c in code:
        if c == '"':
            in_string = not in_string
            current.append(c)
        elif c == ';' and not in_string:
            parts.append(''.join(current))
            current = []
        else:
            current.append(c)
    if current:
        parts.append(''.join(current))
    return [p.strip() for p in parts if p.strip()]


def convert_line(line):
    """Convert a single line from fam3.S to fam2 format."""
    stripped = line.rstrip()

    # Pure blank line
    if stripped.strip() == '':
        return stripped

    # Pure comment line (possibly indented)
    if stripped.lstrip().startswith('#'):
        return stripped

    # Split off trailing comment (careful not to split inside strings)
    code_part = stripped
    comment_part = ''
    in_string = False
    for i, c in enumerate(stripped):
        if c == '"':
            in_string = not in_string
        elif c == '#' and not in_string:
            code_part = stripped[:i].rstrip()
            comment_part = '  ' + stripped[i:]
            break

    # Determine indentation
    indent = ''
    for c in code_part:
        if c in (' ', '\t'):
            indent += c
        else:
            break

    # Split by semicolons (for multi-directive lines like .ascii "x"; .zero 3; .byte 1,2)
    stmts = split_statements(code_part)

    # Check if ALL statements are directives
    hex_parts = []
    all_directives = True
    for stmt in stmts:
        h = convert_directive(stmt)
        if h is not None:
            hex_parts.append(h)
        else:
            all_directives = False
            break

    if all_directives and hex_parts:
        return indent + '  '.join(hex_parts) + comment_part

    # Not all directives — pass through as-is (instruction, label, etc.)
    return stripped


def main():
    input_file = sys.argv[1] if len(sys.argv) > 1 else 'src/fam3.S'

    with open(input_file) as f:
        lines = f.readlines()

    header = (
        "# fam3.fam2 -- fam2-grammar source for the fourth-stage bootstrap assembler.\n"
        "# Converted from src/fam3.S. Data tables use hex passthrough;\n"
        "# all instructions use fam2 mnemonics and labels.\n"
        "#\n"
        "# Built by: run bin/fam2 src/fam3.fam2 > bin/fam3\n"
        "# Regenerate: python3 tools/emit_fam2.py src/fam3.S > src/fam3.fam2\n"
    )
    print(header)

    for line in lines:
        print(convert_line(line))


if __name__ == '__main__':
    main()
