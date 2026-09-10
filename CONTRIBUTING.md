# Contributing

Small, focused fixes and reproducible bug reports are welcome. This is an experimental community project; review, support, fixes and continued maintenance are not guaranteed.

Before starting a larger change, open an issue describing the problem and proposed behavior. For security concerns, use [private vulnerability reporting](SECURITY.md).

## Development

Use macOS with Xcode and its command-line tools selected. The app uses Swift 6 and Apple frameworks, with no third-party package dependencies. See [README](README.md) for setup and compatibility.

```sh
scripts/check_prerequisites.sh
scripts/test_unit.sh
python3 -m unittest discover -s scripts/tests
python3 scripts/check_public_source.py
PACKAGE_OUTPUT_DIR="$PWD/dist/check" scripts/package.sh
```

Use a fresh package output directory on subsequent builds. Unit tests use synthetic fixtures and do not require a signed-in Codex account, Accessibility access or real login-item registration. UI tests require a local graphical session and macOS automation permission; they are not part of headless CI.

Include the problem, resulting behavior, and relevant validation in a pull request. Add regression coverage for parsing, identity, freshness, overflow, or permission behavior changes. Do not describe a source-derived estimate as verified without live comparison evidence. Missing values must remain distinct from zero.

## Keep contributions safe to share

- Use synthetic task IDs, names, token data and file paths in tests and screenshots.
- Never attach raw Codex session logs, authentication files, account exports or unredacted diagnostics.
- Review screenshots for task titles, account details and home-directory paths.
- Do not commit build output, signing material, local settings or personal development notes.
- Check staged files and commit author/committer metadata. Use GitHub's private email option if you do not want your email address public.
- Do not enable secret-bearing workflows on untrusted pull-request code.

The source check detects common accidental disclosures; it is not a complete secret scanner or a substitute for review. Contributions are accepted under the [MIT license](LICENSE). By submitting a contribution, you confirm you have the right to share it under that license.
