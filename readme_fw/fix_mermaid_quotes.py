#!/usr/bin/env python3
"""Replace " with #quot; inside Mermaid node/edge label spans.

["..."] and |"..."| are the two label delimiters in Mermaid flowcharts.
Unescaped inner double quotes break the parser; #quot; is the documented escape.
"""
import sys


def fix_label_span(s, open_seq, close_seq):
    result = []
    i = 0
    while i < len(s):
        if s[i:i + len(open_seq)] == open_seq:
            j = s.find(close_seq, i + len(open_seq))
            if j == -1:
                result.append(s[i:])
                break
            content = s[i + len(open_seq):j].replace('"', '#quot;')
            result.append(open_seq + content + close_seq)
            i = j + len(close_seq)
        else:
            result.append(s[i])
            i += 1
    return ''.join(result)


def fix_line(line):
    line = fix_label_span(line, '["', '"]')
    line = fix_label_span(line, '|"', '"|')
    return line


text = open(sys.argv[1]).read()
sys.stdout.write(''.join(fix_line(l) for l in text.splitlines(keepends=True)))
