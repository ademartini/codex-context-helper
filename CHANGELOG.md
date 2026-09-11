# Changelog

## Unreleased

- Compact Settings explains the CLI requirement for account limits and history; refreshed screenshots use synthetic data only.
- Main-window task clicks are read from Codex desktop selection logs and matched to local sessions; Accessibility permission is no longer needed.
- Cached task switches follow without sending messages. Missing or ambiguous selection metadata offers manual pinning.

- Local session discovery and context monitoring work without a separate CLI.
- Account usage is optional, with connection recovery separate from local activity.
- Structurally compatible session and CLI versions no longer require an exact release match.
- Local agent discovery reports partial coverage; producer versions appear in Details.
- Changed optional executables still require approval.

## 0.1.0 — Experimental source preview

- Floating macOS panel with estimated context remaining and saved tokens/window.
- Task picker follows the selected Codex task, with per-launch pinning. Background activity never changes the monitored task.
- Separate agent and daily-history pages with Back navigation.
- Rounded panel with light and dark appearances.
- Account quota windows and optional backend cost/credit estimates.
- Saved-file updates, periodic refresh and stale-data handling.
- Optional Accessibility selection and launch at login.
- Synthetic regression fixtures, local build tooling and privacy checks.

This is a source preview, not a stable or notarized binary release. Compatibility and known limitations are documented in [README](README.md).
