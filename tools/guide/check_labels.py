#!/usr/bin/env python3
"""Check that every quoted label in the guide chapters is a string literal in the app.

Usage: check_labels.py CHECKOUT [CHAPTER.md ...]

Reads every quoted label ("..." or '...') in the chapter files (default: ch*.md next to
this script) and checks that it matches a string literal in CHECKOUT/app/lib/**/*.dart.
A literal matches when it equals the label, with any Dart interpolation (${...} or $name)
standing for any text (possibly none). Adjacent literals ('a' 'b') are joined first, as Dart does.
Prints every label that does not match, with file and line; exits 1 if any.

Some messages the app shows are written by the Rust search core, not by app/lib (for
example region download pauses and link-code errors). A label that is not in app/lib but
is a string literal in CHECKOUT/packages/cache_search/native/**/*.rs (format! {...}
placeholders standing for any text) is listed separately as "core text" and does not fail
the check.
"""
import pathlib
import re
import sys

ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', "'": "'", '"': '"', '\\': '\\', '$': '$', 'b': '\b'}
INTERP = '\x00'  # marks an interpolated part inside a decoded literal


def dart_literals(src):
    """Yield decoded string literals (adjacent ones joined), interpolations as INTERP."""
    i, n = 0, len(src)
    pending = None  # literal waiting to see if another follows

    def flush():
        nonlocal pending
        if pending is not None:
            out.append(pending)
            pending = None

    out = []
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        raw = False
        if c in 'rR' and i + 1 < n and src[i + 1] in '\'"' and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == '_')):
            raw = True
            i += 1
            c = src[i]
        if c in '\'"':
            q = src[i:i + 3] if src[i:i + 3] in ("'''", '"""') else c
            i += len(q)
            buf = []
            while i < n and not src.startswith(q, i):
                ch = src[i]
                if ch == '\\' and not raw:
                    nx = src[i + 1] if i + 1 < n else ''
                    if nx == 'u':
                        m = re.match(r'u\{([0-9a-fA-F]+)\}|u([0-9a-fA-F]{4})', src[i + 1:])
                        if m:
                            buf.append(chr(int(m.group(1) or m.group(2), 16)))
                            i += 1 + m.end()
                            continue
                    buf.append(ESCAPES.get(nx, nx))
                    i += 2
                    continue
                if ch == '$' and not raw:
                    if i + 1 < n and src[i + 1] == '{':
                        depth, j = 1, i + 2
                        while j < n and depth:
                            if src[j] == '{':
                                depth += 1
                            elif src[j] == '}':
                                depth -= 1
                            j += 1
                        buf.append(INTERP)
                        i = j
                        continue
                    m = re.match(r'[A-Za-z_][A-Za-z0-9_]*', src[i + 1:])
                    if m:
                        buf.append(INTERP)
                        i += 1 + m.end()
                        continue
                buf.append(ch)
                i += 1
            i += len(q)
            text = ''.join(buf)
            pending = text if pending is None else pending + text
            # look ahead: whitespace / comments then another literal means "join"
            j = i
            while j < n:
                if src[j].isspace():
                    j += 1
                elif src.startswith('//', j):
                    k = src.find('\n', j)
                    j = n if k < 0 else k
                elif src.startswith('/*', j):
                    k = src.find('*/', j + 2)
                    j = n if k < 0 else k + 2
                else:
                    break
            nxt = src[j:j + 2]
            if not (j < n and (src[j] in '\'"' or (src[j] in 'rR' and nxt[1:] in ("'", '"')))):
                flush()
            continue
        if pending is not None and not c.isspace():
            flush()
        i += 1
    flush()
    return out


def rust_literals(src):
    """Decoded "..." literals of a Rust file, {...} placeholders as INTERP."""
    out = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith('//', i) and (i == 0 or src[i - 1] != ':'):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        if src[i] == "'" and i + 2 < n and src[i + 2] == "'":  # a char literal such as '"'
            i += 3
            continue
        if src[i] == '"':
            j, buf = i + 1, []
            while j < n and src[j] != '"':
                if src[j] == '\\' and j + 1 < n:
                    nx = src[j + 1]
                    if nx == '\n':  # line continuation: skip the newline and leading spaces
                        j += 2
                        while j < n and src[j] in ' \t':
                            j += 1
                        continue
                    buf.append(ESCAPES.get(nx, nx))
                    j += 2
                    continue
                buf.append(src[j])
                j += 1
            text = ''.join(buf).replace('{{', '\x01').replace('}}', '\x02')
            text = re.sub(r'\{[^{}]*\}', INTERP, text).replace('\x01', '{').replace('\x02', '}')
            out.append(text)
            i = j + 1
            continue
        i += 1
    return out


def literal_pattern(lit):
    parts = [re.escape(p) for p in lit.split(INTERP)]
    return re.compile('.*?'.join(parts), re.S)  # an interpolated part may be empty


# A label: "..." on one line, or '...' that does not start or end inside a word
# (so apostrophes in words like don't are not taken as quotes).
LABEL_RE = re.compile(r'"([^"\n]+)"|(?<![\w])\'([^\'\n]+?)\'(?![\w])')


def labels_in(path):
    in_code = False
    for no, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if line.startswith('```'):
            in_code = not in_code
            continue
        if in_code:
            continue
        line = re.sub(r'`[^`]*`', '', line)  # inline code is not a label
        for m in LABEL_RE.finditer(line):
            yield no, m.group(1) if m.group(1) is not None else m.group(2)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    lib = pathlib.Path(argv[1]) / 'app' / 'lib'
    if not lib.is_dir():
        print(f'no app/lib under {argv[1]}')
        return 2
    chapters = [pathlib.Path(p) for p in argv[2:]] or sorted(pathlib.Path(__file__).parent.glob('ch*.md'))
    literals = set()
    for f in lib.rglob('*.dart'):
        literals.update(dart_literals(f.read_text(encoding='utf-8', errors='replace')))
    plain = {l for l in literals if INTERP not in l}
    # An interpolated literal counts only when its fixed text has at least 3 letters,
    # so '${a}: ${b}' does not match any label that happens to hold ': '.
    patterns = [literal_pattern(l) for l in literals
                if INTERP in l and len(re.findall(r'[A-Za-z]', l.replace(INTERP, ''))) >= 3]
    def matcher(lits):
        fixed = {l for l in lits if INTERP not in l}
        pats = [literal_pattern(l) for l in lits
                if INTERP in l and len(re.findall(r'[A-Za-z]', l.replace(INTERP, ''))) >= 3]
        return lambda label: label in fixed or any(p.fullmatch(label) for p in pats)

    in_dart = lambda label: label in plain or any(p.fullmatch(label) for p in patterns)
    rust = set()
    native = pathlib.Path(argv[1]) / 'packages' / 'cache_search' / 'native'
    for f in native.rglob('*.rs') if native.is_dir() else []:
        rust.update(rust_literals(f.read_text(encoding='utf-8', errors='replace')))
    in_core = matcher(rust)
    missing, core, total = [], [], 0
    for ch in chapters:
        for no, label in labels_in(ch):
            total += 1
            if in_dart(label):
                continue
            (core if in_core(label) else missing).append((ch.name, no, label))
    for name, no, label in core:
        print(f'{name}:{no}: core text (Rust, not app/lib): "{label}"')
    for name, no, label in missing:
        print(f'{name}:{no}: not in app/lib: "{label}"')
    print(f'{total} labels checked, {len(missing)} missing, {len(core)} core texts, '
          f'{len(literals)} Dart and {len(rust)} Rust literals read')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
