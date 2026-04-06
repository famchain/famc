#!/usr/bin/env python3
"""Format assembly source to the famc tab convention.

Convention:
  - Labels at column 0 (no indent), optional  # comment after space
  - Instructions: TAB mnemonic TAB operands TAB TAB # comment
  - Pure comment lines: # at column 0
  - Hex data lines: TAB hex bytes TAB TAB # comment
  - Blank lines preserved
  - Section dividers (# ===...) preserved at column 0

Usage: python3 tools/fmt_asm.py < input.S > output.S
       python3 tools/fmt_asm.py file.S  (in-place)
"""

import sys
import re


def is_hex_byte(tok):
    """Check if token is a 2-char hex byte."""
    return len(tok) == 2 and all(c in '0123456789ABCDEFabcdef' for c in tok)


def format_line(line):
    """Format a single line to the tab convention."""
    stripped = line.rstrip()

    # Blank line
    if stripped == '':
        return ''

    # Split code and comment (careful with strings)
    code = stripped
    comment = ''
    in_string = False
    for i, c in enumerate(stripped):
        if c == '"':
            in_string = not in_string
        elif c == '#' and not in_string:
            code = stripped[:i].rstrip()
            comment = stripped[i:]
            break

    # Pure comment line (no code before #)
    if code == '' and comment:
        return comment

    # Label line: starts with non-whitespace, contains ':'
    code_stripped = code.strip()

    if code_stripped and not code_stripped[0].isspace():
        m = re.match(r'^(\w+:)(.*)', code_stripped)
        if m:
            label = m.group(1)
            rest = m.group(2).strip()
            if rest:
                # Label with trailing instruction (unusual, keep on one line)
                return label + ' ' + rest + ('\t\t' + comment if comment else '')
            elif comment:
                return label + ' ' + comment
            else:
                return label

    # Instruction or hex data line
    if not code_stripped:
        # Whitespace-only line with comment
        return comment if comment else ''

    # Parse: mnemonic/first-token + operands
    tokens = code_stripped.split(None, 1)
    mnemonic = tokens[0]
    operands = tokens[1] if len(tokens) > 1 else ''

    # Clean up operand spacing: normalize to single spaces after commas
    if operands:
        operands = re.sub(r'\s*,\s*', ', ', operands)

    # Check if this is a hex data line (first token is hex byte)
    if is_hex_byte(mnemonic):
        # Hex data line: rejoin all tokens, keep spacing
        hex_part = code_stripped
        if comment:
            return '\t' + hex_part + '\t\t' + comment
        return '\t' + hex_part

    # Regular instruction
    if operands and comment:
        return '\t' + mnemonic + '\t' + operands + '\t\t' + comment
    elif operands:
        return '\t' + mnemonic + '\t' + operands
    elif comment:
        return '\t' + mnemonic + '\t\t' + comment
    else:
        return '\t' + mnemonic


def main():
    if len(sys.argv) > 1 and sys.argv[1] != '-':
        filename = sys.argv[1]
        with open(filename) as f:
            lines = f.readlines()
        inplace = '--check' not in sys.argv
    else:
        lines = sys.stdin.readlines()
        inplace = False

    out = []
    for line in lines:
        out.append(format_line(line))

    result = '\n'.join(out)
    if not result.endswith('\n'):
        result += '\n'

    if inplace and len(sys.argv) > 1 and sys.argv[1] != '-':
        with open(filename, 'w') as f:
            f.write(result)
    else:
        sys.stdout.write(result)


if __name__ == '__main__':
    main()
