# Privacy and local access

Codex Context Helper has no analytics SDK, crash-reporting service, advertising or direct network client. It launches an installed Codex app-server with analytics disabled. Codex remains separate software: it uses its existing authentication, manages local state, and may contact its own account services to return usage information.

## Data used by the helper

- Recent task titles, identifiers, activity, model metadata and parent/agent relationships from Codex.
- Saved token counters and context-window sizes in regular files under the local Codex session directory.
- Account quota windows and optional token/cost/credit summaries exposed by Codex.
- Optional Accessibility metadata from the Codex application to infer which task is selected.

Session files and server responses can contain sensitive content. The parser processes those inputs locally, retains only fields needed for the monitor, and does not write copies of prompts, tool outputs, credentials or account identity to its own storage. Task titles and usage snapshots are kept in memory and may be visible on screen.

## Persistent preferences

The helper stores panel position, display settings, login preference, and the approved executable's local path, identity and version in macOS UserDefaults. It does not upload these preferences. Build logs, developer tools, macOS and the Codex child process can create their own local diagnostics; review those separately before sharing them.

## Controls

Accessibility and launch at login are optional. Revoke Accessibility in System Settings, turn off launch at login in the app, and quit from the menu-bar item to stop monitoring. Removing the app does not automatically remove its preferences. Do not delete your Codex data to uninstall this helper.

The repository uses synthetic test fixtures. Please redact screenshots and reports: task titles, local paths, model usage, account limits and IDs can reveal private work even when no credential is visible.

This document describes the intended implementation, not a guarantee against every defect or disclosure. See the [security policy](SECURITY.md) and [license](LICENSE).
