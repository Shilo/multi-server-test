#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


PROJECT_FILE = Path(__file__).resolve().parents[1] / "project.godot"
VERSION_RE = re.compile(r'^config/version="([^"]+)"$', re.MULTILINE)
VALID_RE = re.compile(r"^(0|[1-9][0-9]*)\.[0-9]$")


def _matches(text: str) -> list[re.Match[str]]:
    return list(VERSION_RE.finditer(text))


def is_valid(version: str) -> bool:
    return bool(VALID_RE.fullmatch(version))


def read_version() -> str:
    text = PROJECT_FILE.read_text(encoding="utf-8")
    matches = _matches(text)
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one config/version entry, found {len(matches)}.")
    version = matches[0].group(1)
    if not is_valid(version):
        raise SystemExit(f"Project version must be canonical MAJOR.MINOR, got: {version}")
    return version


def next_minor(version: str) -> str:
    if not is_valid(version):
        raise SystemExit(f"Cannot bump invalid version: {version}")
    major_text, minor_text = version.split(".")
    major = int(major_text)
    minor = int(minor_text) + 1
    if minor > 9:
        major += 1
        minor = 0
    return f"{major}.{minor}"


def set_version(version: str) -> None:
    clean = version.strip()
    if not is_valid(clean):
        raise SystemExit(f"Version must be canonical MAJOR.MINOR, got: {version}")
    text = PROJECT_FILE.read_text(encoding="utf-8")
    matches = _matches(text)
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one config/version entry, found {len(matches)}.")
    updated = VERSION_RE.sub(f'config/version="{clean}"', text, count=1)
    PROJECT_FILE.write_text(updated, encoding="utf-8", newline="")
    if read_version() != clean:
        raise SystemExit(f"Project version write did not persist: {clean}")
    print(f"PROJECT_VERSION_SET version={clean}")


def self_test() -> None:
    for version in ("0.1", "1.0", "9.9", "10.0"):
        if not is_valid(version):
            raise SystemExit(f"Expected {version} to be valid.")
    for version in ("1.10", "v1.0", "abc", "00.5", "01.2", "1.09", "-1.0", "1"):
        if is_valid(version):
            raise SystemExit(f"Expected {version} to be invalid.")
    expected = {"0.8": "0.9", "0.9": "1.0", "1.9": "2.0"}
    for before, after in expected.items():
        if next_minor(before) != after:
            raise SystemExit(f"Expected {before} to bump to {after}.")
    print("PROJECT_VERSION_SELF_TEST_PASS")


def main() -> None:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--print", action="store_true", dest="print_version")
    group.add_argument("--set")
    group.add_argument("--bump-minor", action="store_true")
    group.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.print_version:
        print(f"PROJECT_VERSION version={read_version()}")
    elif args.set:
        set_version(args.set)
    elif args.bump_minor:
        set_version(next_minor(read_version()))
    else:
        self_test()


if __name__ == "__main__":
    main()
