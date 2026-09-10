#!/usr/bin/env python3
"""Check tracked public source for common accidental disclosures; never print values."""
import pathlib
import re
import subprocess
import sys

PATTERNS = {
    "absolute home directory": re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
    "private temporary directory": re.compile(r"/(?:private/)?var/folders/[A-Za-z0-9_/.-]+"),
    "private key": re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "API key": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b"),
    "cloud access key": re.compile(r"\bAKIA[A-Z0-9]{16}\b"),
}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
ALLOWED_EMAIL_DOMAINS = {"example.com", "example.org", "example.test", "users.noreply.github.com"}
PRIVATE_PARTS = {".local-only", ".codex", ".agents", "plans", "dist", "build", "xcuserdata", "__pycache__"}
PRIVATE_SUFFIXES = {".p12", ".p8", ".key", ".pem", ".log", ".xcuserstate", ".mobileprovision", ".provisionprofile"}


def findings(path, data):
    """Return categories only, so diagnostics cannot repeat a discovered secret."""
    path = pathlib.PurePosixPath(path)
    issues = []
    if any(part in PRIVATE_PARTS or part.startswith(".build") for part in path.parts):
        issues.append("private/generated path")
    if path.suffix in PRIVATE_SUFFIXES or (path.name.startswith(".env") and path.name != ".env.example"):
        issues.append("credential or local-output filename")
    if len(data) > 2 * 1024 * 1024:
        issues.append("file exceeds public-source size limit")
    if path.suffix == ".png":
        # Native screenshots are explicitly reviewed before commit. Reject common
        # text/EXIF metadata chunks, which can carry machine or author information.
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            issues.append("invalid PNG")
        offset = 8
        while offset + 12 <= len(data):
            size = int.from_bytes(data[offset:offset + 4], "big")
            kind = data[offset + 4:offset + 8]
            if kind in {b"tEXt", b"zTXt", b"iTXt", b"eXIf"}:
                issues.append("screenshot text or EXIF metadata")
            offset += size + 12
        return issues
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return issues + ["unexpected binary file"]
    issues.extend(label for label, pattern in PATTERNS.items() if pattern.search(text))
    if any(match.group(1).lower() not in ALLOWED_EMAIL_DOMAINS for match in EMAIL.finditer(text)):
        issues.append("non-example personal email")
    return issues


def main():
    root = pathlib.Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    failures = 0
    checked = 0
    for name in filter(None, paths):
        path = root / name
        if path.is_symlink():
            issues = ["symlink requires manual review"]
        elif not path.is_file():
            issues = ["tracked file missing from checkout"]
        else:
            checked += 1
            issues = findings(name, path.read_bytes())
        for issue in issues:
            print(f"{name}: {issue}")
            failures += 1
    print(f"Checked {checked} tracked files; {failures} findings. Values are not printed.")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
