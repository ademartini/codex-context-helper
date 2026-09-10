# Development and release checks

## Automated checks

```sh
scripts/check_prerequisites.sh
scripts/test_unit.sh
python3 -m unittest discover -s scripts/tests
python3 scripts/check_public_source.py
PACKAGE_OUTPUT_DIR="$PWD/dist/verification" scripts/package.sh
```

The native suite covers bounded log parsing, metadata identity, compaction and model transitions, context calculation, stale caches, quota and cost decoding, lineage coverage, settings, panel anchoring and mocked lifecycle/permission behavior. The direct Apple XCTest runner avoids an IDE-session handshake and does not launch the app's live monitoring loop. The separate UI-test target builds but requires a graphical session and automation support to execute.

Tests use synthetic fixtures. CI must not sign in to Codex, read real session data, use signing secrets or grant Accessibility permission. The source privacy check is a limited guard for common accidental disclosures, not a comprehensive security audit.

## Reproduce the screenshots

Run `scripts/render_screenshots.sh` in a local graphical macOS session. It renders the actual native views with synthetic data and an in-memory settings store. It does not start the monitoring coordinator, read Codex data or use real app preferences. Review the generated images and their metadata before committing.

## Manual validation still needed

- Compare ordinary, tool-heavy, post-compaction and model-change readings with Codex `/status`.
- Check selected-task identification against the current Codex accessibility tree.
- Exercise Spaces, full-screen applications, multiple displays, display removal, keyboard navigation and VoiceOver.
- Check real launch-at-login registration and relaunch from an accepted installation location.
- Observe a ten-task workload for thirty minutes, including the Codex child process tree. The development targets are below 2% average CPU and 150 MB combined RSS; these are unverified targets, not advertised guarantees.
- Characterize per-task backend cost semantics before enabling combined agent costs.

The resource observer accepts a local process ID and writes a local report:

```sh
python3 scripts/observe_resources.py --pid PID --duration 1800 --output /tmp/resource-check.json
```

Its numeric budget checks do not establish that the workload or other acceptance conditions were met. Do not commit live reports or machine diagnostics.

## Packaging

Default packaging creates a local ad hoc signed build with Hardened Runtime. It preserves existing output. This is not a notarized distribution and is not published as a downloadable release by CI.

For maintainers who already have an appropriate signing identity and stored notarytool profile:

```sh
DEVELOPER_ID_APPLICATION='Your Developer ID Application identity' \
NOTARYTOOL_PROFILE='your-stored-profile' \
PACKAGE_OUTPUT_DIR="$PWD/dist/signed" scripts/package.sh
```

This opt-in path contacts Apple's notarization service. It verifies the signature, waits for accepted notarization, staples and validates the ticket, then produces an archive. Keep credentials in Keychain; never commit them. A valid signature/notarization is not a guarantee of correctness or security.

## Before a public release

Review the exact tracked tree and reachable Git history, including author/committer metadata. Exclude local session captures, build output, credentials, signing files, local settings, personal paths and development notes. Inspect screenshots visually as well as their metadata. Use a GitHub noreply identity when desired. Run tests and public-source checks from the same revision being shared, and keep known limitations in the release notes.

Only label a binary release signed or notarized after verifying that specific artifact. A successful unit suite or source audit does not establish production readiness.
