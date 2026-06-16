#!/usr/bin/env python3
import argparse
import email.utils
import hashlib
import json
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote, urljoin


USER_AGENT = "multi-server-test-release-verifier/1.0"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def url_with_query(base_url: str, path: str, version: str, nonce: str) -> str:
    url = urljoin(base_url.rstrip("/") + "/", quote(path, safe="/"))
    separator = "&" if "?" in url else "?"
    return f"{url}{separator}v={quote(version)}&verify={quote(nonce)}"


def read_url(url: str, timeout: float) -> tuple[bytes, dict[str, str]]:
    request = urllib.request.Request(url, headers={
        "Cache-Control": "no-cache",
        "User-Agent": USER_AGENT,
    })
    with urllib.request.urlopen(request, timeout=timeout) as response:
        headers = {key.lower(): value for key, value in response.headers.items()}
        return response.read(), headers


def read_manifest_with_retries(
    url: str,
    expected_version: str,
    expected_commit: str,
    expected_files: dict[str, dict],
    timeout: float,
    attempts: int,
    delay: float
) -> dict:
    last_error: str = ""
    for attempt in range(1, attempts + 1):
        try:
            body, _headers = read_url(url, timeout)
            manifest = json.loads(body.decode("utf-8"))
            hosted_files = {str(item["path"]): item for item in manifest.get("files", [])}
            if manifest.get("version") != expected_version:
                last_error = "version mismatch: expected %s, got %s" % (expected_version, manifest.get("version"))
            elif str(manifest.get("commit", "")) != expected_commit:
                last_error = "commit mismatch: expected %s, got %s" % (expected_commit, manifest.get("commit"))
            elif hosted_files != expected_files:
                missing = sorted(set(expected_files.keys()) - set(hosted_files.keys()))
                extra = sorted(set(hosted_files.keys()) - set(expected_files.keys()))
                changed = sorted(
                    path for path in set(expected_files.keys()) & set(hosted_files.keys())
                    if expected_files[path] != hosted_files[path]
                )
                last_error = (
                    "file table mismatch: missing=%s extra=%s changed=%s"
                    % (missing[:5], extra[:5], changed[:5])
                )
            else:
                return manifest
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            last_error = str(error)

        if attempt < attempts:
            time.sleep(delay)

    raise SystemExit(f"Hosted manifest did not match after {attempts} attempts: {last_error}")


def read_matching_file_with_retries(
    url: str,
    path: str,
    expected_size: int,
    expected_hash: str,
    timeout: float,
    attempts: int,
    delay: float
) -> tuple[bytes, dict[str, str]]:
    last_error: str = ""
    for attempt in range(1, attempts + 1):
        try:
            body, headers = read_url(url, timeout)
            hosted_size = len(body)
            hosted_hash = sha256_bytes(body)
            if hosted_size != expected_size:
                last_error = "size mismatch for %s: expected %d, got %d" % (path, expected_size, hosted_size)
            elif hosted_hash != expected_hash:
                last_error = "hash mismatch for %s" % path
            else:
                return body, headers
        except (urllib.error.URLError, TimeoutError) as error:
            last_error = str(error)

        if attempt < attempts:
            time.sleep(delay)

    raise SystemExit(f"Hosted file did not match after {attempts} attempts: {last_error}")


def parse_http_modified_time(headers: dict[str, str]) -> int:
    value = headers.get("last-modified", "")
    if not value:
        return 0
    parsed = email.utils.parsedate_to_datetime(value)
    if parsed is None:
        return 0
    return int(parsed.timestamp())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--web-root", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--attempts", type=int, default=10)
    parser.add_argument("--delay", type=float, default=3.0)
    parser.add_argument("--fail-on-last-modified-mismatch", action="store_true")
    args = parser.parse_args()

    web_root = Path(args.web_root).resolve()
    local_manifest_path = web_root / "deployment_manifest.json"
    if not local_manifest_path.is_file():
        raise SystemExit(f"Missing local deployment manifest: {local_manifest_path}")

    local_manifest = json.loads(local_manifest_path.read_text(encoding="utf-8"))
    local_files = {str(item["path"]): item for item in local_manifest.get("files", [])}
    nonce = str(int(time.time()))
    manifest_url = url_with_query(args.base_url, "deployment_manifest.json", args.version, nonce)
    expected_commit = args.commit.strip()
    read_manifest_with_retries(
        manifest_url,
        args.version,
        expected_commit,
        local_files,
        args.timeout,
        args.attempts,
        args.delay
    )

    checked = 0
    modified_time_mismatches: list[str] = []
    for path, item in local_files.items():
        local_path = web_root / path
        expected_hash = str(item["sha256"])
        if expected_hash != sha256_file(local_path):
            raise SystemExit(f"Local file hash mismatch for {path}.")

        _body, headers = read_matching_file_with_retries(
            url_with_query(args.base_url, path, args.version, nonce),
            path,
            int(item["size"]),
            expected_hash,
            args.timeout,
            args.attempts,
            args.delay
        )

        if path.startswith("world_packs/"):
            hosted_modified_time = parse_http_modified_time(headers)
            local_modified_time = int(local_path.stat().st_mtime)
            if hosted_modified_time > 0 and hosted_modified_time != local_modified_time:
                modified_time_mismatches.append(path)
                status_label = (
                    "HOSTED_LAST_MODIFIED_MISMATCH"
                    if args.fail_on_last_modified_mismatch
                    else "HOSTED_LAST_MODIFIED_WARNING"
                )
                print(
                    "%s path=%s local=%d hosted=%d"
                    % (status_label, path, local_modified_time, hosted_modified_time)
                )
        checked += 1

    if checked <= 0:
        raise SystemExit("No hosted files were checked.")
    if modified_time_mismatches and args.fail_on_last_modified_mismatch:
        raise SystemExit(
            "Hosted world pack Last-Modified headers do not match local pack metadata: %s"
            % ", ".join(modified_time_mismatches)
        )

    print(
        "HOSTED_PAGES_VERIFY_OK version=%s commit=%s checked=%d last_modified_warnings=%d"
        % (args.version, expected_commit[:12], checked, len(modified_time_mismatches))
    )


if __name__ == "__main__":
    main()
