#!/usr/bin/env python3
"""
migrate_to_secret_classes.py

Migrates secrets from reclass node/class files into dedicated
reclass/classes/secret/ files, then imports those classes back into the
original files.

For each scanned YAML file the script:
  1. Identifies _param._secret keys (or nested keys) whose name matches the
     secret pattern (password, token, key, …).
  2. Optionally asks the operator to confirm or rename each secret key.
  3. Creates (or updates) a corresponding file under reclass/classes/secret/.
  4. Removes those entries from the original file, replacing nested values
     with ${_param:_secret:key} reclass references.
  5. Adds the new secret class to the original file's `classes:` list.

Legacy _param top-level keys matching the secret pattern are also extracted.
Bare _secret blocks (old format) are migrated to _param._secret.

Usage:
  .tmp/relenv/bin/python3 scripts/migrate_to_secret_classes.py [OPTIONS] [FILE...]

Options:
  --dry-run           Show what would change without writing any file.
  --no-interactive    Skip prompts and accept all suggested key names.
  --one-by-one        Prompt for each secret individually instead of the
                      default batch review in $EDITOR.
  --key KEY           Also treat KEY as a secret (repeatable).
  --scan-dir DIR      Directory to scan (default: reclass/, excl. classes/secret/).
  --secret-dir DIR    Target directory for secret classes
                      (default: reclass/classes/secret/).

Interactive modes:
  By default (without --no-interactive), the script collects all candidates
  and opens $EDITOR with a review table.  You can rename keys, or delete /
  comment out lines to skip candidates that are not actual secrets.

  Use --one-by-one for the legacy prompt-per-secret behaviour (type 'skip'
  or '-' to refuse a candidate).

If FILE arguments are given, only those files are processed.
"""
import sys
import os

# If the current interpreter lacks PyYAML, try to re-exec with one that has
# it — relenv first (canonical for this project), then system pythons.
try:
    import yaml as _yaml_check  # noqa: F401
except ImportError:
    _script = os.path.abspath(__file__)
    _repo_root = os.path.dirname(os.path.dirname(_script))
    _candidates = [
        os.path.join(_repo_root, '.tmp', 'relenv', 'bin', 'python3'),
        'python3', 'python',
    ]
    for _py in _candidates:
        _py_abs = os.path.abspath(_py) if os.sep in _py else _py
        if _py_abs == os.path.abspath(sys.executable):
            continue
        try:
            import subprocess
            subprocess.check_call([_py, '-c', 'import yaml'], stderr=subprocess.DEVNULL)
            os.execv(_py if os.sep not in _py else os.path.abspath(_py),
                      [_py] + sys.argv)
        except (subprocess.CalledProcessError, FileNotFoundError, OSError):
            pass
    sys.exit(
        "ERROR: PyYAML not found.\n"
        "Run `make relenv` first, then:\n"
        "  .tmp/relenv/bin/python3 scripts/migrate_to_secret_classes.py\n"
        "Or install PyYAML: pip install pyyaml"
    )

import argparse
import copy
import re
import yaml


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
PARAM_NS  = '_param'    # reclass scalar_parameters namespace
SECRET_NS = '_secret'   # sub-key of _param for secrets (_param._secret)
# Full reclass reference: ${_param:_secret:key}
# Legacy: _param keys at top level (not under _secret) are also scanned.

SECRET_PATTERN = re.compile(
    r'(?i)(password|passwd|secret|credential|\bauth\b|\bkey|\bcontents\b)',
)

# Sentinel returned by prompt_fn to indicate "skip this candidate (not a secret)".
SKIP_MARKER = '!skip'


# ---------------------------------------------------------------------------
# Pure helpers — easy to unit-test
# ---------------------------------------------------------------------------
def is_reclass_reference(value):
    """Return True if *value* is a reclass interpolation like ``${…}``."""
    return isinstance(value, str) and value.startswith('${') and value.endswith('}')


def is_secret_key(key, extra_keys=()):
    """Return True if *key* matches the secret pattern or is in extra_keys."""
    return bool(SECRET_PATTERN.search(str(key))) or str(key) in extra_keys


def unique_key(base, reserved):
    """
    Return *base* if it is not in *reserved*, otherwise *base_2*, *base_3*, …
    Does NOT mutate *reserved*.
    """
    key = base
    n = 2
    while key in reserved:
        key = f"{base}_{n}"
        n += 1
    return key


def collect_all_secrets(parameters, extra_keys=(), prompt_fn=None):
    """
    Walk *parameters* and collect every secret key, regardless of nesting.

    Two sources are handled:

      _secret / _param blocks (direct secret namespace):
        Keys matching the secret pattern are extracted directly.
        Legacy _param is scanned too so existing files are migrated.

      Deeper nesting (e.g. parameters.myapp.admin_password):
        A flat _secret key is generated from the full path
        (myapp_admin_password) and the original value is replaced with a
        ${_secret:myapp_admin_password} reclass reference.

    Clash detection uses a shared *reserved* set (all known non-secret keys
    + keys already assigned in this run).

    Parameters
    ----------
    parameters : dict
        The top-level ``parameters`` mapping from a reclass YAML file.
    extra_keys : iterable
        Additional key names to treat as secrets unconditionally.
    prompt_fn : callable or None
        Signature: ``prompt_fn(suggested: str, description: str) -> str``
        Returns the user's raw input (empty string → accept *suggested*).
        When *None*, suggested names are accepted without prompting.

    Returns
    -------
    direct_secrets   : dict   {final_key: value}  keys moved to secret class
    direct_remaining : dict   {key: value}         non-secret keys that stay
    nested_secrets   : list   [(path_tuple, value, final_key)]
    """
    parameters = parameters or {}

    # Secrets live under _param._secret (all keys are secrets).
    # Legacy: _param top-level keys matching the pattern are also extracted.
    param_block  = parameters.get(PARAM_NS, {}) or {}
    secret_block = param_block.get(SECRET_NS, {}) if isinstance(param_block, dict) else {}
    secret_block = secret_block or {}
    # Legacy _param keys (not _secret sub-dict) matching the pattern
    legacy_keys = {k: v for k, v in param_block.items()
                   if k != SECRET_NS and is_secret_key(k, extra_keys)
                   and not is_reclass_reference(v)}

    raw_secrets = dict(legacy_keys)
    raw_secrets.update(secret_block)  # _param._secret wins on clash
    # Non-secret _param keys (excluding _secret sub-dict) are kept as-is.
    direct_remaining = {k: v for k, v in param_block.items()
                        if k != SECRET_NS and not is_secret_key(k, extra_keys)}
    # Also handle bare _secret at top level (old format) for migration.
    bare_secret = parameters.get(SECRET_NS, {}) or {}
    if bare_secret and isinstance(bare_secret, dict):
        raw_secrets.update(bare_secret)  # bare _secret wins on clash

    # *reserved* starts with non-secret keys (they stay in place).
    reserved = set(direct_remaining.keys())

    # Process direct secrets FIRST so their names take priority over
    # any auto-generated key from nested paths.
    direct_secrets = {}
    for k, v in raw_secrets.items():
        desc = f"_param._secret.{k}  (direct)"
        final = _resolve_key(k, reserved, desc, prompt_fn)
        if final is not None:
            direct_secrets[final] = v

    nested_secrets = []

    def walk(d, path):
        for k, v in d.items():
            current_path = path + (str(k),)
            if isinstance(v, dict):
                walk(v, current_path)
            elif isinstance(v, (list, dict)):
                continue  # lists/dicts are not scalar secrets
            elif is_secret_key(k, extra_keys) and not is_reclass_reference(v):
                desc = f"parameters.{'.'.join(current_path)}"
                final = _resolve_key('.'.join(current_path), reserved, desc, prompt_fn)
                if final is not None:
                    nested_secrets.append((current_path, v, final))

    for k, v in parameters.items():
        if k in (PARAM_NS, SECRET_NS):
            continue
        if isinstance(v, dict):
            walk(v, (str(k),))
        elif isinstance(v, list):
            continue  # lists are not scalar secrets
        elif is_secret_key(k, extra_keys) and not is_reclass_reference(v):
            desc = f"parameters.{k}"
            final = _resolve_key(str(k), reserved, desc, prompt_fn)
            if final is not None:
                nested_secrets.append(((str(k),), v, final))

    return direct_secrets, direct_remaining, nested_secrets


def _resolve_key(suggested, reserved, description, prompt_fn):
    """
    Determine the final key name:
      - call *prompt_fn* for user input (if provided),
      - de-duplicate against *reserved*,
      - add the chosen key to *reserved*.

    Returns *None* when the operator chooses to skip this candidate.
    """
    if prompt_fn is not None:
        raw = prompt_fn(suggested, description)
        if raw == SKIP_MARKER:
            return None
        base = raw.strip() if raw.strip() else suggested
    else:
        base = suggested

    final = unique_key(base, reserved)
    if final != base:
        print(f"    '{base}' is already taken -> using '{final}'")
    reserved.add(final)
    return final


def apply_nested_replacements(parameters, nested_secrets):
    """
    Return a deep copy of *parameters* where each nested secret value has
    been replaced with a ``${_param:_secret:key}`` reclass reference.
    """
    updated = copy.deepcopy(parameters)
    for path, _value, key in nested_secrets:
        node = updated
        for p in path[:-1]:
            node = node[p]
        node[path[-1]] = f'${{_param:_secret:{key}}}'
    return updated


def secret_class_path(source_file, repo_root, secret_dir):
    """
    Mirror the full reclass-relative path under *secret_dir* to avoid
    clashes between identically named node and class files.

      reclass/nodes/myhost.yml     -> <secret_dir>/nodes/myhost.yml
      reclass/classes/foo/bar.yml  -> <secret_dir>/classes/foo/bar.yml
    """
    rel = os.path.relpath(source_file, os.path.join(repo_root, 'reclass'))
    return os.path.join(secret_dir, rel)


def secret_class_name(source_file, repo_root, secret_dir):
    """Return the reclass class name for the secret class file."""
    target = secret_class_path(source_file, repo_root, secret_dir)
    rel = os.path.relpath(target, os.path.join(repo_root, 'reclass', 'classes'))
    rel = re.sub(r'\.ya?ml$', '', rel)
    return rel.replace(os.sep, '.')


# ---------------------------------------------------------------------------
# Secret-comment helpers
# ---------------------------------------------------------------------------
SECRET_COMMENT_MARKER = '_secret_'


def extract_secret_comments(filepath):
    """
    Read *filepath* as raw text and return ``_secret_`` comment strings
    associated with a YAML key path.

    Two forms are recognised:

    1. **Standalone comment** on its own line::

           # _secret_: the_password
           some_key: value

       → associated with the full path of the first YAML key that follows.

    2. **Inline comment** at the end of a ``key: value`` line::

           db_password: mypass  # _secret_: the real password

       → associated with the full path of the key on the same line.

    Returns
    -------
    list of (comment_str, path_tuple_or_None)
        *path_tuple* is the full YAML path from the file root (e.g.
        ``('parameters', 'myapp', 'password')``), or ``None`` when no
        YAML key could be determined (e.g. comment at end of file).
    """
    with open(filepath) as f:
        lines = f.readlines()

    _key_re = re.compile(r'''^\s*['"]?([^'"\s:]+)['"]?\s*:''')
    # Match an inline comment containing the marker.
    _inline_re = re.compile(r'(#[^#]*''' + SECRET_COMMENT_MARKER + r'.*)')

    results = []
    pending = []  # standalone comments waiting for a key
    context = []  # [(indent, key)] for tracking YAML path

    for line in lines:
        stripped = line.strip()

        # --- standalone comment line ---
        if stripped.startswith('#') and SECRET_COMMENT_MARKER in stripped:
            pending.append(stripped)
            continue

        # --- parse YAML key line ---
        km = _key_re.match(line)
        if not km:
            # blank / normal comment / list item — skip for pending
            if pending and (not stripped or stripped.startswith('#')):
                continue
            continue

        indent = len(line) - len(line.lstrip())
        key = km.group(1)

        # Update context stack
        while context and context[-1][0] >= indent:
            context.pop()
        path = tuple(k for _, k in context) + (key,)
        context.append((indent, key))

        # Flush any pending standalone comments → associate with this path.
        if pending:
            for c in pending:
                results.append((c, path))
            pending = []

        # --- inline comment on a key: value line ---
        if SECRET_COMMENT_MARKER in line:
            im = _inline_re.search(line)
            if im:
                results.append((im.group(1).strip(), path))

    # Standalone comments at end of file with no following key.
    for c in pending:
        results.append((c, None))

    return results


def inject_comments_into_yaml(yaml_text, secret_comments):
    """
    Insert each ``(comment, key)`` pair from *secret_comments* right
    before the matching key line inside *yaml_text*.

    Comments whose *key* is ``None`` or not found are appended at the
    end of the ``_secret:`` block.

    Returns the modified YAML text.
    """
    if not secret_comments:
        return yaml_text

    _key_re = re.compile(r'''^\s*['"]?([^'"\s:]+)['"]?\s*:''')

    lines = yaml_text.splitlines(True)

    # Group comments by target key, preserving order.
    by_key = {}       # key -> [comment, ...]
    orphans = []      # comments with no target key
    for comment, key in secret_comments:
        if key is None:
            orphans.append(comment)
        else:
            by_key.setdefault(key, []).append(comment)

    result = []
    used_keys = set()
    for line in lines:
        m = _key_re.match(line)
        if m:
            k = m.group(1)
            if k in by_key and k not in used_keys:
                indent = len(line) - len(line.lstrip())
                for c in by_key[k]:
                    result.append(' ' * indent + c + '\n')
                used_keys.add(k)
        result.append(line)

    # Unmatched keyed comments + orphans → append after _secret: block.
    remaining = []
    for k, comments in by_key.items():
        if k not in used_keys:
            remaining.extend(comments)
    remaining.extend(orphans)

    if remaining:
        # Find _secret: line to match its child indent.
        indent = 6  # fallback
        for line in lines:
            if line.lstrip().startswith(f'{SECRET_NS}:'):
                indent = len(line) - len(line.lstrip()) + 2
                break
        for c in remaining:
            result.append(' ' * indent + c + '\n')

    return ''.join(result)


# ---------------------------------------------------------------------------
# In-place source file editing (preserves formatting and key order)
# ---------------------------------------------------------------------------
_YAML_KEY_RE = re.compile(r'^(\s*)([\'\"]?)([^\'\"\s:]+)\2\s*:(.*)')


def update_source_file_text(source_text, direct_remaining_keys,
                            nested_replacements, cls_name):
    """
    Apply surgical edits to *source_text*, preserving structure, comments,
    and key order.

    - Remove the ``_param._secret`` block (all keys extracted).
    - Remove the bare ``_secret`` block (old format).
    - Remove legacy ``_param`` keys that are NOT in *direct_remaining_keys*.
    - Replace nested secret values with ``${_param:_secret:…}`` references.
    - Remove ``_secret_`` comment lines (standalone and inline).
    - Clean up empty ``_param`` / ``parameters`` blocks.
    - Add *cls_name* to the ``classes:`` list.
    """
    lines = source_text.splitlines(True)
    result = []
    context = []            # [(indent, key)] for tracking YAML path
    skip_deeper_than = -1   # when >= 0, skip lines indented deeper

    for line in lines:
        stripped = line.strip()

        # --- Inside a removed block: skip deeper lines ---
        if skip_deeper_than >= 0:
            if not stripped or stripped.startswith('#'):
                continue  # blank / comment inside removed block
            current_indent = len(line) - len(line.lstrip())
            if current_indent > skip_deeper_than:
                continue  # still inside the removed block
            skip_deeper_than = -1
            # Fall through to process this line normally

        # --- Standalone _secret_ comment → remove ---
        if stripped.startswith('#') and SECRET_COMMENT_MARKER in stripped:
            continue

        # --- Blank / regular comment / list item → keep ---
        if not stripped or stripped.startswith('#') or stripped.startswith('- '):
            result.append(line)
            continue

        # --- Parse YAML key: value ---
        m = _YAML_KEY_RE.match(line)
        if not m:
            result.append(line)
            continue

        indent = len(m.group(1))
        key = m.group(3)

        # Update context stack
        while context and context[-1][0] >= indent:
            context.pop()
        path = tuple(k for _, k in context) + (key,)
        context.append((indent, key))

        # --- Remove _param._secret block ---
        if path == ('parameters', PARAM_NS, SECRET_NS):
            skip_deeper_than = indent
            continue

        # --- Remove bare _secret block (old format) ---
        if path == ('parameters', SECRET_NS):
            skip_deeper_than = indent
            continue

        # --- _param children: keep only direct_remaining keys ---
        if (len(path) == 3 and path[:2] == ('parameters', PARAM_NS)
                and key != SECRET_NS and key not in direct_remaining_keys):
            skip_deeper_than = indent
            continue

        # --- Nested secret value → replace with reference ---
        params_path = path[1:] if path[0] == 'parameters' else path
        if params_path in nested_replacements:
            ref = nested_replacements[params_path]
            key_part = line[:m.start(4)]
            result.append(f'{key_part} {ref}\n')
            # If the value was a block scalar (| or >), skip continuation lines.
            value_stripped = m.group(4).strip()
            if value_stripped and value_stripped[0] in ('|', '>'):
                skip_deeper_than = indent
            continue

        # --- Strip inline _secret_ comment ---
        if SECRET_COMMENT_MARKER in line:
            inline_m = re.search(r'\s+#.*' + SECRET_COMMENT_MARKER + r'.*$', line)
            if inline_m:
                result.append(line[:inline_m.start()] + '\n')
                continue

        result.append(line)

    text = ''.join(result)

    # Remove _param: if it has no remaining children.
    if not direct_remaining_keys:
        text = _remove_empty_block(text, PARAM_NS)

    # Remove parameters: if it became empty.
    text = _remove_empty_block(text, 'parameters')

    # Add class import.
    text = _add_class_import(text, cls_name)

    return text


def _remove_empty_block(text, key_name):
    """Remove a YAML block whose only children are blank/comment lines."""
    lines = text.splitlines(True)
    result = []
    i = 0
    while i < len(lines):
        m = _YAML_KEY_RE.match(lines[i])
        if m and m.group(3) == key_name:
            base_indent = len(m.group(1))
            j = i + 1
            has_children = False
            while j < len(lines):
                s = lines[j].strip()
                if not s or s.startswith('#'):
                    j += 1
                    continue
                if (len(lines[j]) - len(lines[j].lstrip())) > base_indent:
                    has_children = True
                break
            if not has_children:
                # Skip this empty block header + trailing blanks.
                i += 1
                while i < len(lines) and not lines[i].strip():
                    i += 1
                continue
        result.append(lines[i])
        i += 1
    return ''.join(result)


def _add_class_import(text, cls_name):
    """Append *cls_name* to the ``classes:`` list, creating it if needed."""
    if cls_name in text:
        return text

    lines = text.splitlines(True)
    in_classes = False
    last_item_idx = -1
    item_indent = 2

    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == 'classes:':
            in_classes = True
            continue
        if in_classes:
            if stripped.startswith('- '):
                last_item_idx = i
                item_indent = len(line) - len(line.lstrip())
            elif stripped and not stripped.startswith('#'):
                in_classes = False

    if last_item_idx >= 0:
        lines.insert(last_item_idx + 1, f'{" " * item_indent}- {cls_name}\n')
    else:
        lines.insert(0, f'classes:\n- {cls_name}\n')

    return ''.join(lines)


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------
def load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f) or {}


class _LiteralDumper(yaml.SafeDumper):
    """YAML dumper that renders multi-line strings with ``|`` block style."""
    pass


def _str_representer(dumper, data):
    if '\n' in data:
        return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='|')
    return dumper.represent_scalar('tag:yaml.org,2002:str', data)


_LiteralDumper.add_representer(str, _str_representer)


def dump_yaml(data):
    return yaml.dump(data, Dumper=_LiteralDumper,
                     default_flow_style=False, allow_unicode=True)


def write_or_print(path, content, dry_run, label):
    if dry_run:
        print(f"[DRY-RUN] Would write {label}: {path}")
        print('---')
        print(content.rstrip())
        print('---')
    else:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            f.write(content)
        print(f"  written: {path}")


def tty_prompt(suggested, description):
    """
    Prompt the operator via /dev/tty for a _param._secret key name.
    Returns the raw answer (empty string = accept *suggested*).
    Returns SKIP_MARKER if the operator types 'skip' or '-'.
    Falls back silently to '' if /dev/tty is unavailable.
    """
    print(f"  {description}")
    while True:
        sys.stdout.write(f"    _param._secret key [{suggested}] (or 'skip'): ")
        sys.stdout.flush()
        try:
            with open('/dev/tty') as tty:
                answer = tty.readline().rstrip('\n').strip()
        except OSError:
            return ''
        if answer.lower() in ('skip', '!skip', '-'):
            return SKIP_MARKER
        if answer == '' or re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*$', answer):
            return answer
        print("    Invalid: use letters, digits, underscores "
              "(start with letter or _), or 'skip' to skip.")


# ---------------------------------------------------------------------------
# Batch review helpers
# ---------------------------------------------------------------------------
def collect_candidates_for_file(source_file, repo_root, secret_dir, extra_keys):
    """
    Collect candidate secrets from *source_file* without prompting.

    Returns a list of ``(description, suggested_key)`` tuples that match the
    format used by :func:`collect_all_secrets` so they can be mapped back.
    """
    source_file = os.path.abspath(source_file)
    if source_file.startswith(os.path.abspath(secret_dir) + os.sep):
        return []
    data = load_yaml(source_file)
    if not isinstance(data, dict):
        return []
    parameters = data.get('parameters', {}) or {}

    # Keys with inline _secret_ comments are forced secrets.
    sc = extract_secret_comments(source_file)
    all_extra = list(extra_keys) + [p[-1] for _, p in sc if p is not None]

    if not has_any_secrets(parameters, all_extra):
        return []

    candidates = []
    param_block = parameters.get(PARAM_NS, {}) or {}
    secret_block = (param_block.get(SECRET_NS, {})
                    if isinstance(param_block, dict) else {})
    secret_block = secret_block or {}
    legacy_keys = {k: v for k, v in param_block.items()
                   if k != SECRET_NS and is_secret_key(k, all_extra)
                   and not is_reclass_reference(v)}
    raw_secrets = dict(legacy_keys)
    raw_secrets.update(secret_block)
    bare_secret = parameters.get(SECRET_NS, {}) or {}
    if bare_secret and isinstance(bare_secret, dict):
        raw_secrets.update(bare_secret)

    for k in raw_secrets:
        candidates.append((f"_param._secret.{k}  (direct)", k))

    def walk(d, path):
        for k, v in d.items():
            current_path = path + (str(k),)
            if isinstance(v, dict):
                walk(v, current_path)
            elif isinstance(v, (list, dict)):
                continue
            elif is_secret_key(k, all_extra) and not is_reclass_reference(v):
                desc = f"parameters.{'.'.join(current_path)}"
                suggested = '.'.join(current_path)
                candidates.append((desc, suggested))

    for k, v in parameters.items():
        if k in (PARAM_NS, SECRET_NS):
            continue
        if isinstance(v, dict):
            walk(v, (str(k),))
        elif isinstance(v, list):
            continue
        elif is_secret_key(k, all_extra) and not is_reclass_reference(v):
            candidates.append((f"parameters.{k}", str(k)))

    return candidates


def batch_review(all_candidates_by_file, repo_root):
    """
    Open ``$EDITOR`` with all candidates for batch review.

    Parameters
    ----------
    all_candidates_by_file : list of (filepath, [(desc, suggested), …])
    repo_root : str

    Returns
    -------
    dict : ``{filepath: {description: final_key_or_SKIP_MARKER}}``
        Entries that the operator deleted or commented out map to
        :data:`SKIP_MARKER`.
    """
    import tempfile
    import subprocess as _sp

    lines = [
        "# Secret migration review — edit this file, then save and close.",
        "#",
        "# Each non-comment line describes one candidate secret:",
        "#   description | key_name",
        "# grouped under the source file (## header).",
        "#",
        "# Actions:",
        "#   ACCEPT as-is : leave the line unchanged",
        "#   RENAME       : edit the key name (after the |)",
        "#   SKIP         : delete the line or prefix with #",
        "#",
        "",
    ]

    for filepath, candidates in all_candidates_by_file:
        rel = os.path.relpath(filepath, repo_root)
        lines.append(f"## {rel}")
        for desc, suggested in candidates:
            lines.append(f"{desc} | {suggested}")
        lines.append("")

    content = '\n'.join(lines)

    editor = os.environ.get('EDITOR', os.environ.get('VISUAL', 'vi'))

    with tempfile.NamedTemporaryFile(
            mode='w', suffix='.txt', prefix='secret_migration_',
            delete=False) as f:
        f.write(content)
        tmppath = f.name

    try:
        _sp.check_call([editor, tmppath])
        with open(tmppath) as f:
            edited = f.read()
    finally:
        os.unlink(tmppath)

    # ---- parse the edited file ----
    # Build a lookup: rel_path -> abs_path
    abs_by_rel = {}
    # Build default (everything skipped) and original suggested names
    original_suggested = {}   # (filepath, desc) -> suggested
    decisions = {}            # filepath -> {desc: key}
    for filepath, candidates in all_candidates_by_file:
        rel = os.path.relpath(filepath, repo_root)
        abs_by_rel[rel] = filepath
        decisions[filepath] = {}
        for desc, suggested in candidates:
            decisions[filepath][desc] = SKIP_MARKER
            original_suggested[(filepath, desc)] = suggested

    current_file_abs = None
    for line in edited.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith('## '):
            rel = stripped[3:].strip()
            current_file_abs = abs_by_rel.get(rel)
            continue
        if stripped.startswith('#'):
            continue
        if '|' not in stripped or current_file_abs is None:
            continue
        parts = stripped.rsplit('|', 1)
        desc_part = parts[0].strip()
        key_part = parts[1].strip()

        if current_file_abs in decisions and desc_part in decisions[current_file_abs]:
            if key_part:
                decisions[current_file_abs][desc_part] = key_part
            else:
                # Empty key → accept original suggested name.
                fallback = original_suggested.get((current_file_abs, desc_part), '')
                decisions[current_file_abs][desc_part] = fallback if fallback else SKIP_MARKER

    return decisions


def make_batch_prompt_fn(file_decisions):
    """
    Return a ``prompt_fn`` that looks up pre-made batch decisions.

    *file_decisions* maps ``{description: final_key_or_SKIP_MARKER}`` for the
    file currently being processed.
    """
    def prompt_fn(suggested, description):
        return file_decisions.get(description, SKIP_MARKER)
    return prompt_fn


# ---------------------------------------------------------------------------
# Main processing
# ---------------------------------------------------------------------------
def has_any_secrets(parameters, extra_keys):
    """Quick check: does *parameters* contain any potential secret key?"""
    parameters = parameters or {}

    # _param._secret has any keys → secrets exist.
    param_block = parameters.get(PARAM_NS, {}) or {}
    if isinstance(param_block, dict) and param_block.get(SECRET_NS):
        return True

    # Bare _secret at top level (old format) → secrets exist.
    if parameters.get(SECRET_NS):
        return True

    # _param top-level keys matching the pattern count (skip references/non-scalars).
    if isinstance(param_block, dict):
        if any(is_secret_key(k, extra_keys)
               and not isinstance(v, (dict, list))
               and not is_reclass_reference(v)
               for k, v in param_block.items() if k != SECRET_NS):
            return True

    # Check all nested keys outside the secret namespaces.
    def _walk(d):
        for k, v in d.items():
            if k in (PARAM_NS, SECRET_NS):
                continue
            if isinstance(v, (dict, list)):
                if isinstance(v, dict) and _walk(v):
                    return True
                continue
            if is_secret_key(k, extra_keys) and not is_reclass_reference(v):
                return True
        return False

    return _walk(parameters)


def process_file(source_file, repo_root, secret_dir, dry_run, prompt_fn, extra_keys):
    """
    Process one source file.  Returns True if the file was (or would be)
    modified, False otherwise.
    """
    source_file = os.path.abspath(source_file)

    if source_file.startswith(os.path.abspath(secret_dir) + os.sep):
        return False

    data = load_yaml(source_file)
    if not isinstance(data, dict):
        return False

    parameters = data.get('parameters') or {}

    # Extract _secret_ comments from raw text (before yaml.dump loses them).
    secret_comments = extract_secret_comments(source_file)

    # Keys annotated with an inline _secret_ comment are forced secrets,
    # regardless of whether their name matches SECRET_PATTERN.
    # Extract the leaf key name from each path for use as extra_keys.
    comment_forced_keys = [p[-1] for _, p in secret_comments if p is not None]
    all_extra_keys = list(extra_keys) + comment_forced_keys

    if not has_any_secrets(parameters, all_extra_keys) and not secret_comments:
        return False

    cls_name    = secret_class_name(source_file, repo_root, secret_dir)
    target_path = secret_class_path(source_file, repo_root, secret_dir)

    prefix = '[DRY-RUN] ' if dry_run else ''
    print(f"\n{prefix}Processing: {os.path.relpath(source_file, repo_root)}")
    if prompt_fn is tty_prompt:
        print("  (Press Enter to accept the suggested key name, or type a new one.)")

    direct_secrets, direct_remaining, nested_secrets = collect_all_secrets(
        parameters, extra_keys=all_extra_keys, prompt_fn=prompt_fn)

    if not direct_secrets and not nested_secrets and not secret_comments:
        print("  (no secrets after filtering — skipping)")
        return False

    if direct_secrets:
        print(f"  _param._secret keys : {', '.join(direct_secrets)}")
    if nested_secrets:
        parts = [f"parameters.{'.'.join(p)} -> _param._secret.{k}" for p, _v, k in nested_secrets]
        print(f"  nested       : {', '.join(parts)}")
    if secret_comments:
        print(f"  comments     : {len(secret_comments)} _secret_ comment(s) to migrate")
    print(f"  -> class : {cls_name}")
    print(f"  -> file  : {os.path.relpath(target_path, repo_root)}")

    # Build / merge secret class file.
    if os.path.exists(target_path):
        existing = load_yaml(target_path)
    else:
        existing = {}

    existing.setdefault('parameters', {}).setdefault(PARAM_NS, {}).setdefault(SECRET_NS, {})
    existing['parameters'][PARAM_NS][SECRET_NS].update(direct_secrets)
    for _path, value, key in nested_secrets:
        existing['parameters'][PARAM_NS][SECRET_NS][key] = value

    secret_header = (
        f"# Secrets for '{os.path.relpath(source_file, repo_root)}'.\n"
        "# This file is encrypted with SOPS (age). Do not add plaintext secrets here —\n"
        "# run `make sops_encrypt` after editing, or rely on the pre-commit hook.\n"
    )
    # Map source-file paths to secret-file keys so comments land next to
    # the right entry.  Comments carry full paths from the file root, while
    # nested_secrets paths are relative to ``parameters``.
    _ref_re = re.compile(r'\$\{_param:_secret:([^}]+)\}')
    path_to_secret_key = {}
    for path, _value, final_key in nested_secrets:
        full = ('parameters',) + path
        path_to_secret_key[full] = final_key
        # Also map every parent prefix so that a comment above a parent
        # dict resolves to the first secret leaf underneath it.
        for i in range(1, len(full)):
            prefix = full[:i]
            if prefix not in path_to_secret_key:
                path_to_secret_key[prefix] = final_key
    # Also map paths whose value is already a ${_param:_secret:X} reference
    # (re-running on an already-migrated file).
    def _add_ref_mappings(d, path_prefix=()):
        for k, v in d.items():
            p = path_prefix + (k,)
            if isinstance(v, str):
                rm = _ref_re.match(v)
                if rm and p not in path_to_secret_key:
                    path_to_secret_key[p] = rm.group(1)
            elif isinstance(v, dict):
                _add_ref_mappings(v, p)
    _add_ref_mappings(parameters, ('parameters',))

    def _map_comment(comment, path):
        if path is None:
            return (comment, None)
        if path in path_to_secret_key:
            return (comment, path_to_secret_key[path])
        # Try progressively shorter prefixes.
        for i in range(len(path) - 1, 0, -1):
            prefix = path[:i]
            if prefix in path_to_secret_key:
                return (comment, path_to_secret_key[prefix])
        return (comment, None)

    mapped_comments = [_map_comment(c, p) for c, p in secret_comments]

    secret_yaml = inject_comments_into_yaml(dump_yaml(existing), mapped_comments)
    write_or_print(target_path, secret_header + secret_yaml, dry_run, 'secret class')

    # Update source file (surgical text edits, preserving formatting).
    with open(source_file) as f:
        source_text = f.read()

    nested_replacements = {path: f'${{_param:_secret:{key}}}'
                           for path, _value, key in nested_secrets}

    updated_text = update_source_file_text(
        source_text,
        direct_remaining_keys=set(direct_remaining.keys()),
        nested_replacements=nested_replacements,
        cls_name=cls_name,
    )

    write_or_print(source_file, updated_text, dry_run, 'updated source')
    return True


def collect_files(scan_dir, secret_dir, explicit_files):
    """Return the list of YAML files to process."""
    if explicit_files:
        return [os.path.abspath(f) for f in explicit_files]

    result = []
    secret_dir_abs = os.path.abspath(secret_dir) + os.sep
    for root, _dirs, files in os.walk(scan_dir):
        for fname in sorted(files):
            if not fname.endswith(('.yml', '.yaml')):
                continue
            path = os.path.abspath(os.path.join(root, fname))
            if not path.startswith(secret_dir_abs):
                result.append(path)
    return sorted(result)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------
def main(argv=None):
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would change without writing any file.')
    parser.add_argument('--no-interactive', action='store_true',
                        help='Skip prompts and accept all suggested key names.')
    parser.add_argument('--one-by-one', action='store_true',
                        help='Prompt for each secret individually instead of '
                             'opening $EDITOR with a batch review table.')
    parser.add_argument('--key', dest='extra_keys', action='append', default=[],
                        metavar='KEY',
                        help='Also treat KEY as a secret (repeatable).')
    parser.add_argument('--scan-dir', default=os.path.join(repo_root, 'reclass'),
                        metavar='DIR',
                        help='Directory to scan (default: reclass/).')
    parser.add_argument('--secret-dir',
                        default=os.path.join(repo_root, 'reclass', 'classes', 'secret'),
                        metavar='DIR',
                        help='Target directory for secret classes.')
    parser.add_argument('files', nargs='*', metavar='FILE',
                        help='Specific files to process (default: all in --scan-dir).')
    args = parser.parse_args(argv)

    interactive = not args.no_interactive and sys.stdin.isatty() and sys.stdout.isatty()

    files = collect_files(args.scan_dir, args.secret_dir, args.files)

    if not files:
        print("No YAML files found to process.")
        return

    print(f"Scanning {len(files)} file(s) for secrets...")
    if args.dry_run:
        print("(dry-run mode — no files will be modified)")

    # ------------------------------------------------------------------
    # Determine the review mode
    # ------------------------------------------------------------------
    batch_decisions = None  # filepath -> {desc -> key}

    if not interactive:
        print("(non-interactive mode — suggested key names will be used automatically)")
    elif args.one_by_one:
        print("(interactive one-by-one mode — confirm each key, or type 'skip')")
    else:
        # Default interactive: batch review via $EDITOR.
        print("(batch review mode — collecting candidates…)")
        all_candidates = []
        for f in files:
            cands = collect_candidates_for_file(
                f, repo_root, args.secret_dir, args.extra_keys)
            if cands:
                all_candidates.append((os.path.abspath(f), cands))

        if not all_candidates:
            print("\nNo secret candidates found.")
            return

        total = sum(len(c) for _, c in all_candidates)
        print(f"Found {total} candidate(s) in {len(all_candidates)} file(s).")
        print(f"Opening $EDITOR for review…\n")
        batch_decisions = batch_review(all_candidates, repo_root)

        # Count accepted vs skipped for feedback.
        accepted = sum(1 for fd in batch_decisions.values()
                       for v in fd.values() if v != SKIP_MARKER)
        skipped = total - accepted
        print(f"Review complete: {accepted} accepted, {skipped} skipped.")
        if accepted == 0:
            print("Nothing to migrate.")
            return
    print()

    # ------------------------------------------------------------------
    # Process files
    # ------------------------------------------------------------------
    changed = 0
    for f in files:
        f_abs = os.path.abspath(f)
        if batch_decisions is not None:
            file_decs = batch_decisions.get(f_abs)
            if not file_decs or all(v == SKIP_MARKER for v in file_decs.values()):
                continue  # everything skipped for this file
            pfn = make_batch_prompt_fn(file_decs)
        elif interactive and args.one_by_one:
            pfn = tty_prompt
        else:
            pfn = None

        changed += process_file(f, repo_root, args.secret_dir, args.dry_run,
                                pfn, args.extra_keys)

    verb = 'would be ' if args.dry_run else ''
    print(f"\n{'[DRY-RUN] ' if args.dry_run else ''}Done. "
          f"{changed} file(s) {verb}processed.")
    if changed > 0 and not args.dry_run:
        print("\nNext steps:")
        print("  1. Review the changes with: git diff")
        print("  2. Encrypt the secret files : make sops_encrypt")
        print("  3. Stage and commit         : git add reclass/ && git commit")


if __name__ == '__main__':
    main()
