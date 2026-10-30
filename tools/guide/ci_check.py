#!/usr/bin/env python3
"""The guide's CI check, run from the repository root: python3 -I tools/guide/ci_check.py

1. Every quoted label in docs/guide/ch*.md is a string in the app (check_labels.py), except the labels listed in
   tools/guide/allowed_missing.txt (screens that are not on this branch yet; each block there says when it goes).
2. Every guide title the app points the assistant at (the guide titles in app/lib/actions/setup_status.dart) is a
   title of the guide (guide_titles.py).
Prints what fails and exits 1; prints a one-line summary and exits 0 otherwise.
"""
import contextlib
import io
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import check_labels  # noqa: E402
import guide_titles  # noqa: E402


def allowed():
    path = HERE / 'allowed_missing.txt'
    if not path.exists():
        return set()
    return {l.strip() for l in path.read_text(encoding='utf-8').splitlines() if l.strip() and not l.lstrip().startswith('#')}


def main():
    failed = False
    chapters = sorted(str(p) for p in (ROOT / 'docs' / 'guide').glob('ch*.md'))
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        check_labels.main(['check_labels.py', str(ROOT), *chapters])
    ok = allowed()
    missing = []
    for line in out.getvalue().splitlines():
        m = re.match(r'(.*?): not in app/lib: "(.*)"$', line)
        if m and m.group(2) not in ok:
            missing.append(line)
    for line in missing:
        print(line)
    if missing:
        print(f'{len(missing)} guide labels are not in the app and not in allowed_missing.txt')
        failed = True

    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        if guide_titles.main() != 0:
            failed = True
    titles = set(json.loads(out.getvalue())['titles'])
    src = (ROOT / 'app' / 'lib' / 'actions' / 'setup_status.dart').read_text(encoding='utf-8')
    pointers = re.findall(r"SetupArea\('[a-z_]+', '[^']*', '([^']*)'", src)
    if not pointers:
        print('no guide titles found in setup_status.dart')
        failed = True
    for p in pointers:
        if p not in titles:
            print(f'setup_status points at a guide title the guide does not have: "{p}"')
            failed = True
    if not failed:
        print(f'guide check: labels ok ({len(ok)} allowed until their screens arrive), {len(pointers)} guide titles found in the guide')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
