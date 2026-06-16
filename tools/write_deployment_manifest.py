#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from project_version import read_version


def git_value(args: list[str], default: str = "") -> str:
    try:
        return subprocess.check_output(["git", *args], text=True).strip()
    except Exception:
        return default


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--web-root", required=True)
    parser.add_argument("--version", default="")
    parser.add_argument("--output", default="deployment_manifest.json")
    args = parser.parse_args()

    web_root = Path(args.web_root).resolve()
    if not web_root.is_dir():
        raise SystemExit(f"Missing Web root: {web_root}")

    output_path = web_root / args.output
    version = args.version.strip() or read_version()
    commit = os.environ.get("GITHUB_SHA", "").strip() or git_value(["rev-parse", "HEAD"])
    run_id = os.environ.get("GITHUB_RUN_ID", "").strip()

    files = []
    for path in sorted(web_root.rglob("*")):
        if not path.is_file() or path == output_path:
            continue
        stat = path.stat()
        files.append({
            "path": path.relative_to(web_root).as_posix(),
            "size": stat.st_size,
            "sha256": sha256(path),
        })

    manifest = {
        "schema": 1,
        "project": "multi-server-test",
        "version": version,
        "commit": commit,
        "commit_short": commit[:12],
        "workflow_run_id": run_id,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "file_count": len(files),
        "files": files,
    }
    output_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="")
    print(f"DEPLOYMENT_MANIFEST_WRITTEN path={output_path} files={len(files)} version={version}")


if __name__ == "__main__":
    main()
