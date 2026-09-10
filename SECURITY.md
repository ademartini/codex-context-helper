# Security policy

Codex Context Helper is experimental software. No version is designated for security-critical use, and no response time, fix, compatibility or maintenance commitment is offered.

## Reporting a vulnerability

Use [GitHub's private vulnerability report form](https://github.com/ademartini/codex-context-helper/security/advisories/new). Do not post exploitable details, credentials, real session logs or account information in a public issue.

Include the affected revision, a short impact description, and reproduction steps using synthetic data. If private reporting is unavailable, open a public issue requesting a private contact channel without disclosing the vulnerability itself.

## Trust boundary

The helper runs outside App Sandbox to inspect local Codex session files and launch the user-approved Codex executable. Optional Accessibility permission is powerful system access; grant it only to a build you trust. The helper uses it to read task-selection metadata from Codex.

The app sends allowlisted read requests to Codex's app-server. That process uses your existing Codex authentication and may contact account services. It also manages its own local state. The helper does not initiate task execution or billing actions. See [privacy](PRIVACY.md) for what it reads and stores.

The project does not currently publish a notarized installer. Development builds are signed ad hoc. Do not disable Gatekeeper, SIP or other system protections to run a download. Review the source and build locally, or wait for a separately verified signed release.
