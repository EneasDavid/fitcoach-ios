#!/usr/bin/env python3
"""Prints the CHANGELOG.md section of one version (the body of its GitHub release). Fails when the version has no section, so a tag
cannot be released without release notes.   Usage: release_notes.py v0.1.0 [CHANGELOG.md]"""
import pathlib
import re
import sys


def section(changelog: str, version: str) -> str:
    version = version.lstrip("v")
    match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|^\[[^\]]+\]: |\Z)", changelog, re.DOTALL | re.MULTILINE)
    if not match or not match.group(1).strip():
        raise SystemExit(f"CHANGELOG.md has no section for version {version}")
    return match.group(1).strip() + "\n"


def is_prerelease(tag: str) -> bool:
    """SemVer: 0.y.z is initial development, and anything with a `-suffix` is a pre-release. Stable starts at 1.0.0."""
    tag = tag.lstrip("v")
    return tag.startswith("0.") or "-" in tag


if __name__ == "__main__":
    tag = sys.argv[1]
    path = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parents[2] / "CHANGELOG.md")
    sys.stdout.write(section(path.read_text(encoding="utf-8"), tag))
