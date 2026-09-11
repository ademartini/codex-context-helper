# Repository guidance

Codex Context Helper is a native macOS companion built with Swift 6, SwiftUI and AppKit. Read `README.md` for setup and limitations, and `CONTRIBUTING.md` before changing code.

## Code layout

- `CodexContextHelper/Domain/`: measurements, task models and preferences.
- `CodexContextHelper/Infrastructure/`: approved Codex processes, app-server requests, session readers, Accessibility and monitoring lifecycle.
- `CodexContextHelper/UI/` and `CodexContextHelper/App/`: native views, panel state and application entry points.
- `CodexContextHelperTests/`: unit tests using synthetic fixtures. UI tests live in `CodexContextHelperUITests/`.
- `scripts/`: prerequisite checks, test runners, packaging and source privacy checks.

## Working conventions

- Keep changes focused and follow existing Swift patterns. The app has no third-party Swift dependencies.
- Preserve the read-only request allowlist, executable approval, bounded parsing and session identity checks.
- Missing or invalid measurements must stay distinct from zero. Keep raw counters, context estimates and billing estimates separate.
- Treat Codex versions and data schemas as separate compatibility concerns. Check both app-server and session-log behavior when changing compatibility policy.
- Use synthetic fixtures and screenshots. Never commit real session logs, prompts, credentials, account details, personal paths or generated build output.

## Validation

Run the checks relevant to your changes:

```sh
scripts/check_prerequisites.sh
scripts/test_unit.sh
python3 -m unittest discover -s scripts/tests
python3 scripts/check_public_source.py
```

Add regression coverage for parsing, identity, compatibility, freshness and permission changes. Tests must not require a signed-in Codex account, real session data or Accessibility permission. UI tests need a graphical session; do not claim they ran when only the target built.

For packaging, use `PACKAGE_OUTPUT_DIR="$PWD/dist/check" scripts/package.sh` with a fresh destination. See `docs/verification.md` for manual and release checks. Report what changed, which checks ran and any remaining limitations.
