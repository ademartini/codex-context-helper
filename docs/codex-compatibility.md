# Data sources and compatibility

The helper has two independent connections: local task monitoring and authenticated account features. A CLI connection failure must not interrupt local context updates.

## Local task monitoring

The helper reads saved sessions under `CODEX_HOME/sessions` when an absolute `CODEX_HOME` is supplied to the app, or `~/.codex/sessions` otherwise. GUI apps do not inherit terminal environment variables automatically.

- Session headers establish task identity, producer version and explicit agent relationships. Token records supply context windows and saved counters.
- The local desktop title catalog is opened read-only. Titles are matched by exact local ID; prompt and preview fields are never title fallbacks.
- Selection comes from `thread_stream_view_activity_changed` metadata in the running Codex desktop process's diagnostic logs. An eligible event must identify a visible, focused primary window and a verified local task. Background responses never select a task.
- Manual pins remain fixed until the user resumes following Codex or quits the helper.

Selection parsing checks process lifetime, task identity, log integrity and event ordering. Reads, directory traversal and caches are bounded. Incomplete lines, conflicting evidence and dropped records cannot restore a stale selection. Missing metadata offers manual pinning.

The desktop log and catalog formats are private interfaces. Codex updates can change them independently of CLI versions. Following covers task changes in the main window; switching focus between already-open windows is unsupported. Cloud-only tasks and local sessions outside the bounded catalog may be unavailable.

## Account limits and history

Account features require an installed, signed-in Codex CLI approved in Settings. The helper starts `codex app-server` over its default stdio transport, with analytics disabled, and uses a restricted read-only request allowlist.

| Reading | Request |
|---|---|
| Sign-in state | `account/read`, without requesting token refresh |
| Account limits and reset times | `account/rateLimits/read` |
| Account-wide daily token activity | `account/usage/read` |
| Reported task cost/credit estimates | `account/usage/read` with a task ID, when supported |

These readings come from the authenticated Codex service. Local session totals are not substituted for account history or quota readings. Returned features and fields vary; absent values stay unavailable rather than becoming zero. Backend cost semantics remain incompletely characterized, so the helper does not advertise verified combined agent costs or invoiced totals.

OpenAI documents the app-server protocol and account requests in its [official app-server documentation](https://learn.chatgpt.com/docs/app-server).

## Updates and approval

Compatible CLI releases are accepted without an exact version requirement. Session-log structure and app-server capabilities are checked separately; a newer version alone does not disable monitoring. A changed approved executable still requires review. This protects executable identity, not publisher authenticity.

Unsupported account methods degrade independently, so missing history support does not disable working limit readings. Reconnecting reevaluates capabilities. Disconnect clears executable approval and stops account access while local monitoring continues; previous account readings are marked stale.

## Measurement limits

Context remaining is an estimate based on the latest saved response, reported model window and a source-derived baseline calculation. Compatible fields do not prove unchanged semantics or parity with Codex's own display. Cumulative response tokens, current context and reported costs are distinct measurements.

Synthetic regression tests cover identity, bounded parsing, rotation, process changes, cached task switches, manual pins and connection recovery. Live desktop-version coverage, context parity and resource use still need broader validation. See [verification](verification.md) for the remaining manual checks.
