#!/usr/bin/env python3
"""Validate repository-local Markdown links and public-release hygiene."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)|<(?:img|a)\s[^>]*?(?:src|href)=\"([^\"]+)\"")
PRIVATE_HOME = re.compile(r"(?<![A-Za-z0-9])/(?:Users|home)/[^/\s`\"']+(?:/|$)")
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
MARKDOWN = sorted(ROOT.glob("*.md")) + sorted((ROOT / "docs").glob("*.md"))
SECRET_PATTERNS = {
    "private key": re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"),
    "AWS key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{50,})\b"),
    "GitLab token": re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}\b"),
    "Google API key": re.compile(r"\bAIza[A-Za-z0-9_-]{35}\b"),
    "npm token": re.compile(r"\bnpm_[A-Za-z0-9]{30,}\b"),
    "OpenAI key": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"),
    "Slack token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "Stripe live key": re.compile(r"\b[rs]k_live_[A-Za-z0-9]{16,}\b"),
}


def main() -> int:
    failures: list[str] = []

    for document in MARKDOWN:
        if not document.exists():
            failures.append(f"missing document: {document.relative_to(ROOT)}")
            continue
        text = document.read_text(encoding="utf-8")
        if "—" in text or "–" in text:
            failures.append(f"dash punctuation in {document.relative_to(ROOT)}")
        for match in LINK.finditer(text):
            destination = (match.group(1) or match.group(2)).strip().split()[0].strip("<>")
            if destination.startswith(("http://", "https://", "mailto:", "#")):
                continue
            path_text = unquote(destination.split("#", 1)[0])
            if path_text and not (document.parent / path_text).resolve().exists():
                failures.append(
                    f"broken link in {document.relative_to(ROOT)}: {destination}"
                )

    publishable = subprocess.run(
        ["git", "ls-files", "-co", "--exclude-standard", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    ).stdout.decode().split("\0")
    sensitive_suffixes = (".env", ".key", ".pem", ".p12", ".pfx", ".mobileprovision")
    for relative in filter(None, publishable):
        if relative == "Config/Local.xcconfig" or relative.endswith(sensitive_suffixes):
            failures.append(f"sensitive file would be published: {relative}")
        path = ROOT / relative
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if PRIVATE_HOME.search(text):
            failures.append(f"private home path in publishable file: {relative}")
        private_emails = {
            address
            for address in EMAIL.findall(text)
            if not address.lower().endswith(("@example.com", "@users.noreply.github.com"))
        }
        if private_emails:
            failures.append(f"possible personal email in publishable file: {relative}")
        for name, pattern in SECRET_PATTERNS.items():
            if pattern.search(text):
                failures.append(f"possible {name} in publishable file: {relative}")

    tracked_noise = [
        relative
        for relative in filter(None, publishable)
        if Path(relative).name == ".DS_Store"
    ]
    failures.extend(f"local metadata would be published: {path}" for path in tracked_noise)

    if failures:
        print("Documentation check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"Documentation check passed ({len(MARKDOWN)} files).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
