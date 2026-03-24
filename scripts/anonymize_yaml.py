#!/usr/bin/env python3
"""Anonymize YAML: replace all scalar values and comments with placeholders.

Preserves: key names, structure, indentation, |/> markers, ${...} refs, class names.
Replaces:  values, comments, multiline content with hashed placeholders.
Keeps _secret_ markers visible.

Usage: python3 scripts/anonymize_yaml.py file1.yml file2.yml ...
"""
import re, sys, hashlib

def _hash(s):
    return hashlib.md5(s.encode()).hexdigest()[:8]

def anonymize(text):
    result = []
    for line in text.splitlines(True):
        stripped = line.strip()
        # Comment line
        if stripped.startswith('#'):
            if '_secret_' in stripped:
                result.append(re.sub(r'(_secret_:).*', r'\1 REDACTED_' + _hash(stripped), line))
            else:
                indent = len(line) - len(line.lstrip())
                result.append(' ' * indent + '# comment_' + _hash(stripped) + '\n')
            continue
        # Key: value line
        m = re.match(r'^(\s*[\'\"]?[^\'\"\s:]+[\'\"]?\s*:)(.*)', line)
        if m:
            key_part = m.group(1)
            val_part = m.group(2)
            secret_m = re.search(r'(\s*#.*_secret_:)(.*)', val_part)
            if secret_m:
                val_part = val_part[:secret_m.start()]
                comment = secret_m.group(1) + ' REDACTED_' + _hash(secret_m.group(2))
            else:
                comment = ''
            val = val_part.strip()
            if not val or val in ('|', '>', '|+', '|-', '>+', '>-'):
                result.append(key_part + val_part + comment + '\n')
            elif val.startswith('${'):
                result.append(key_part + val_part + comment + '\n')
            else:
                result.append(key_part + ' VAL_' + _hash(val) + comment + '\n')
            continue
        # List item
        lm = re.match(r'^(\s*- )(.*)', line)
        if lm:
            val = lm.group(2).strip()
            if val.startswith('${') or re.match(r'^[a-zA-Z_][\w.-]*$', val):
                result.append(line)
            else:
                result.append(lm.group(1) + 'ITEM_' + _hash(val) + '\n')
            continue
        # Continuation lines (multiline values)
        if stripped and not stripped.startswith('-'):
            indent = len(line) - len(line.lstrip())
            result.append(' ' * indent + 'CONT_' + _hash(stripped) + '\n')
            continue
        result.append(line)
    return ''.join(result)

for path in sys.argv[1:]:
    with open(path) as f:
        print(f'--- {path} ---')
        print(anonymize(f.read()))
