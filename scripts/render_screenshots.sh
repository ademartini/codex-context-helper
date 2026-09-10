#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_root/.build-screenshots"
python3 - "$repo_root" <<'PY'
from pathlib import Path
import subprocess
import sys
root = Path(sys.argv[1])
files = sorted(str(p) for p in (root / 'CodexContextHelper').rglob('*.swift') if p.name != 'CodexContextHelperApp.swift')
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-D', 'DEBUG', '-swift-version', '6',
                '-module-cache-path', str(root / '.build-screenshots/ModuleCache'),
                *files, str(root / 'scripts/render_screenshots.swift'), '-o', str(root / '.build-screenshots/render')], check=True)
subprocess.run([str(root / '.build-screenshots/render'), str(root / 'docs/images')], check=True)
subprocess.run(['python3', str(root / 'scripts/strip_png_metadata.py'),
                *[str(root / 'docs/images' / (name + '.png')) for name in ['compact', 'agents', 'history']]], check=True)
PY
