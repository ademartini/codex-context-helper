# Privacy and local access

Codex Context Helper has no analytics SDK, crash-reporting service, advertising or direct network client. Local monitoring needs no child process. When you opt into account usage, it launches the approved Codex app-server with analytics disabled. Codex remains separate software: it uses its existing authentication, manages local state, and may contact its own account services to return usage information.

## Data used by the helper

- Local session identifiers, file timestamps, producer versions, model metadata and explicit parent/agent relationships. The optional local desktop catalog supplies display titles for exact local session IDs; optional app-server metadata supplies titles and activity when available. The helper opens the desktop catalog read-only and never uses prompt or preview fields as title fallbacks.
- Saved token counters and context-window sizes in regular files under the local Codex session directory.
- Account quota windows and optional token/cost/credit summaries exposed by Codex.
- Task-view metadata from local Codex desktop diagnostic logs: task IDs, process/session IDs, timestamps, window IDs, visibility and focus flags. The helper follows eligible main-window task selections and requires a matching saved local session.

Session files, desktop diagnostic logs and server responses can contain sensitive content. Desktop log reads are bounded and retain only selection metadata and a bounded unfinished line in memory. The parser processes those inputs locally, retains only fields needed for the monitor, and does not write copies of prompts, tool outputs, credentials or account identity to its own storage. Task titles and usage snapshots are kept in memory and may be visible on screen.

## Persistent preferences

The helper stores panel position, display settings, login preference, and the approved executable's local path, identity and version in macOS UserDefaults. It does not upload these preferences. Build logs, developer tools, macOS and the Codex child process can create their own local diagnostics; review those separately before sharing them.

## Controls

Account usage and launch at login are optional. Task following does not request or require Accessibility permission. Use **Disconnect** under Account limits & history in Settings to remove executable approval and stop that connection while local monitoring continues. Old helper Accessibility entries can be removed in System Settings. Turn off launch at login in the app and quit from the menu-bar item to stop monitoring. Removing the app does not automatically remove its preferences. Do not delete your Codex data to uninstall this helper.

The repository uses synthetic test fixtures. Please redact screenshots and reports: task titles, local paths, model usage, account limits and IDs can reveal private work even when no credential is visible.

This document describes the intended implementation, not a guarantee against every defect or disclosure. See the [security policy](SECURITY.md) and [license](LICENSE).
