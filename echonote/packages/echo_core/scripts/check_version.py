#!/usr/bin/env python3
"""Checks that every version number agrees with echo_core.h.

Usage:
  check_version.py                 header vs pubspec.yaml and CHANGELOG.md
  check_version.py --tag v0.2.0-rc.1
                                   also the release tag; prints the package
                                   version suffix ("rc.1", or "" for a release)
  check_version.py --notes 0.2.0   prints that version's CHANGELOG section

The C# package version is read from the header at build time, so it can't
disagree.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def header_version() -> str:
    text = (ROOT / "src" / "echo_core.h").read_text()
    parts = [re.search(rf"#define EC_VERSION_{p} (\d+)", text) for p in ("MAJOR", "MINOR", "PATCH")]
    if not all(parts):
        sys.exit("echo_core.h: EC_VERSION_MAJOR/MINOR/PATCH not found")
    return ".".join(m.group(1) for m in parts)


def changelog_sections() -> list[tuple[str, str]]:
    text = (ROOT / "CHANGELOG.md").read_text()
    heads = list(re.finditer(r"^## \[([^\]]+)\].*$", text, re.M))
    return [(h.group(1), text[h.end():heads[i + 1].start() if i + 1 < len(heads) else len(text)].strip())
            for i, h in enumerate(heads)]


def main() -> None:
    args = sys.argv[1:]
    if args[:1] == ["--notes"]:
        for version, body in changelog_sections():
            if version == args[1]:
                print(body)
                return
        sys.exit(f"CHANGELOG.md has no section for {args[1]}")

    version = header_version()
    errors = []
    pubspec = re.search(r"^version: (\S+)", (ROOT / "pubspec.yaml").read_text(), re.M)
    if not pubspec or pubspec.group(1) != version:
        errors.append(f"pubspec.yaml version is {pubspec and pubspec.group(1)}")
    released = [v for v, _ in changelog_sections() if v != "Unreleased"]
    if not released or released[0] != version:
        errors.append(f"newest CHANGELOG.md section is {released[0] if released else None}")

    suffix = ""
    if args[:1] == ["--tag"]:
        tag = re.fullmatch(r"v(\d+\.\d+\.\d+)(?:-([0-9A-Za-z.-]+))?", args[1])
        if not tag:
            errors.append(f"tag {args[1]} is not vMAJOR.MINOR.PATCH[-suffix]")
        elif tag.group(1) != version:
            errors.append(f"tag {args[1]} is version {tag.group(1)}")
        else:
            suffix = tag.group(2) or ""

    if errors:
        print(f"echo_core.h says {version}, but:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        sys.exit(1)
    print(suffix if args[:1] == ["--tag"] else f"version {version}: header, pubspec.yaml and CHANGELOG.md agree")


if __name__ == "__main__":
    main()
