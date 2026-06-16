#!/usr/bin/env python3
import argparse
import struct
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def read_pck_entries(path: Path, pack_start: int = 0) -> list[str]:
    data = path.read_bytes()
    if data[pack_start:pack_start + 4] != b"GDPC":
        raise ValueError(f"Not a Godot PCK file at offset {pack_start}: {path}")

    cursor = pack_start + 4
    cursor += 4 * 5
    cursor += 8
    directory_offset = struct.unpack_from("<Q", data, cursor)[0]
    if directory_offset <= 0 or pack_start + directory_offset >= len(data):
        raise ValueError(f"Invalid PCK directory offset {directory_offset}: {path}")

    cursor = pack_start + directory_offset
    file_count = struct.unpack_from("<I", data, cursor)[0]
    cursor += 4
    if file_count > 10000:
        raise ValueError(f"Unreasonable PCK file count {file_count}: {path}")

    entries: list[str] = []
    for _ in range(file_count):
        path_length = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4
        if path_length <= 0 or path_length > 4096:
            raise ValueError(f"Invalid PCK path length {path_length}: {path}")
        raw_path = data[cursor:cursor + path_length]
        cursor += path_length
        entries.append(raw_path.rstrip(b"\0").decode("utf-8"))
        cursor += 8
        cursor += 8
        cursor += 16
        cursor += 4
    return entries


def embedded_pck_entries(path: Path) -> list[str]:
    data = path.read_bytes()
    valid: list[tuple[int, list[str]]] = []
    offset = data.find(b"GDPC")
    while offset != -1:
        try:
            valid.append((offset, read_pck_entries(path, offset)))
        except Exception:
            pass
        offset = data.find(b"GDPC", offset + 1)
    if len(valid) != 1:
        raise SystemExit(f"Expected exactly one embedded PCK in {path}, found {len(valid)}.")
    print(f"VERIFY_EMBEDDED_PCK_OK path={path} offset={valid[0][0]} entries={len(valid[0][1])}")
    return valid[0][1]


def normalized(entries: list[str]) -> list[str]:
    return [entry[6:] if entry.startswith("res://") else entry for entry in entries]


def assert_no_editor_entries(path: Path, entries: list[str]) -> None:
    bad = [entry for entry in entries if entry.startswith("editor/") or entry.startswith("res://editor/")]
    if bad:
        raise SystemExit(f"Runtime export includes editor files in {path}: {', '.join(bad)}")
    print(f"VERIFY_NO_EDITOR_ENTRIES_OK path={path}")


def assert_no_server_entries(path: Path) -> None:
    entries = read_pck_entries(path)
    bad = [entry for entry in entries if entry.startswith("server/") or entry.startswith("res://server/")]
    if bad:
        raise SystemExit(f"Client/Web export includes server files in {path}: {', '.join(bad)}")
    assert_no_editor_entries(path, entries)
    print(f"VERIFY_CLIENT_PACK_OK path={path} entries={len(entries)}")


def assert_no_client_entries(path: Path, entries: list[str]) -> None:
    bad = [entry for entry in entries if entry.startswith("client/") or entry.startswith("res://client/")]
    if bad:
        raise SystemExit(f"Server export includes client files in {path}: {', '.join(bad)}")
    assert_no_editor_entries(path, entries)
    print(f"VERIFY_SERVER_PACK_OK path={path} entries={len(entries)}")


def assert_no_server_sidecars(path: Path) -> None:
    if not path.exists():
        return
    sidecars = [item for item in path.rglob("*") if item.is_file() and "gdsqlite" in item.name]
    if sidecars:
        raise SystemExit(f"Client/Web export contains server-only SQLite sidecars: {sidecars}")
    print(f"VERIFY_NO_SERVER_SIDECARS_OK path={path}")


def assert_world_pack(path: Path, world_key: str) -> None:
    entries = read_pck_entries(path)
    assert_no_editor_entries(path, entries)
    items = normalized(entries)
    expected_scene = f"server/worlds/{world_key}/{world_key}.tscn"
    expected_remap = f"{expected_scene}.remap"
    if expected_scene not in items and expected_remap not in items:
        raise SystemExit(f"World pack {path} is missing {expected_scene} or {expected_remap}")
    wrong_world = [
        entry for entry in items
        if entry.startswith("server/worlds/") and not entry.startswith(f"server/worlds/{world_key}/")
    ]
    if wrong_world:
        raise SystemExit(f"World pack {path} contains other world files: {', '.join(wrong_world)}")
    allowed = {
        ".godot/global_script_class_cache.cfg",
        ".godot/uid_cache.bin",
        "icon.svg",
        "project.binary",
    }
    unexpected = [
        entry for entry in items
        if not entry.startswith(f"server/worlds/{world_key}/")
        and not entry.startswith(".godot/exported/")
        and entry not in allowed
    ]
    if unexpected:
        raise SystemExit(f"World pack {path} contains unexpected entries: {', '.join(unexpected)}")
    print(f"VERIFY_WORLD_PACK_OK key={world_key} path={path} entries={len(entries)}")


def world_keys() -> list[str]:
    keys: list[str] = []
    for directory in sorted((PROJECT_ROOT / "server" / "worlds").iterdir()):
        if not directory.is_dir():
            continue
        scene = directory / f"{directory.name}.tscn"
        if not scene.exists():
            raise SystemExit(f"World folder '{directory.name}' must contain {directory.name}.tscn")
        keys.append(directory.name)
    return keys


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-root", default=str(PROJECT_ROOT / "builds"))
    parser.add_argument("--server-binary", default="server/server.x86_64")
    parser.add_argument("--web-only", action="store_true")
    parser.add_argument("--skip-web-client", action="store_true")
    parser.add_argument("--world-keys", default="all")
    args = parser.parse_args()

    build_root = Path(args.build_root).resolve()
    if not args.skip_web_client:
        assert_no_server_entries(build_root / "web" / "index.pck")
    assert_no_server_sidecars(build_root / "web")

    if not args.web_only:
        server_path = build_root / args.server_binary
        assert_no_client_entries(server_path, embedded_pck_entries(server_path))

    keys = world_keys()
    if args.world_keys == "none":
        keys = []
    elif args.world_keys != "all":
        requested = [key.strip() for key in args.world_keys.split(",") if key.strip()]
        unknown = [key for key in requested if key not in keys]
        if unknown:
            raise SystemExit(f"Unknown worlds: {', '.join(unknown)}. Valid worlds: {', '.join(keys)}")
        keys = requested

    for key in keys:
        if not args.web_only:
            assert_world_pack(build_root / "world_packs" / f"{key}.pck", key)
        assert_world_pack(build_root / "web" / "world_packs" / f"{key}.pck", key)

    print("VERIFY_EXPORT_ARTIFACTS_DONE")


if __name__ == "__main__":
    main()
