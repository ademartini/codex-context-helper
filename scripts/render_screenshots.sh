#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_root/.build-screenshots"
python3 - "$repo_root" <<'PY'
from pathlib import Path
import subprocess
import sys
import os
import shutil
root = Path(sys.argv[1])
files = sorted(str(p) for p in (root / 'CodexContextHelper').rglob('*.swift') if p.name != 'CodexContextHelperApp.swift')
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-D', 'DEBUG', '-swift-version', '6',
                '-module-cache-path', str(root / '.build-screenshots/ModuleCache'),
                *files, str(root / 'scripts/render_screenshots.swift'), '-o', str(root / '.build-screenshots/render')], check=True)
# Separate processes avoid AppKit image-cache reuse when tearing down offscreen windows.
output = Path(os.environ.get('SCREENSHOT_OUTPUT_DIR', str(root / 'docs/images')))
output.mkdir(parents=True, exist_ok=True)
if output.resolve() != (root / 'docs/images').resolve():
    shutil.copyfile(root / 'docs/images/logo.png', output / 'logo.png')
pages = os.environ.get('SCREENSHOT_PAGES', 'compact agents history settings').split()
allowed = {'compact', 'agents', 'history', 'local-only', 'empty', 'access', 'update', 'settings', 'selection'}
if not pages or any(page not in allowed for page in pages):
    raise SystemExit('Unknown screenshot page')
for name in pages:
    subprocess.run([str(root / '.build-screenshots/render'), str(output), name], check=True)
subprocess.run(['python3', str(root / 'scripts/strip_png_metadata.py'),
                *[str(output / (name + '.png')) for name in pages]], check=True)
PY
