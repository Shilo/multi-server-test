#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_PATH = PROJECT_ROOT / "deploy" / "caddy" / "Caddyfile.template"
HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$")
WORLD_RE = re.compile(r"^[A-Za-z0-9_-]+$")
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def world_keys() -> list[str]:
    worlds_root = PROJECT_ROOT / "server" / "worlds"
    keys: list[str] = []
    for directory in sorted(worlds_root.iterdir()):
        if not directory.is_dir():
            continue
        key = directory.name
        if not WORLD_RE.fullmatch(key):
            raise SystemExit(f"World key is not route-safe: {key}")
        scene = directory / f"{key}.tscn"
        if not scene.exists():
            raise SystemExit(f"World folder '{key}' must contain {key}.tscn")
        keys.append(key)
    if not keys:
        raise SystemExit(f"No worlds found under {worlds_root}")
    return keys


def world_port(index: int) -> int:
    return 19081 + index


def render(host: str, acme_email: str = "") -> str:
    clean_host = host.strip()
    if not HOST_RE.fullmatch(clean_host):
        raise SystemExit(f"Host must be a bare DNS name, got: {host}")

    global_options_block = ""
    clean_email = acme_email.strip()
    if clean_email:
        if not EMAIL_RE.fullmatch(clean_email):
            raise SystemExit(f"ACME email is not valid: {acme_email}")
        global_options_block = "{\n\temail %s\n}\n\n" % clean_email

    route_blocks: list[str] = []
    for index, key in enumerate(world_keys()):
        route_blocks.append(
            "\t@world_{key} path /{key}\n"
            "\thandle @world_{key} {{\n"
            "\t\treverse_proxy 127.0.0.1:{port} {{\n"
            "\t\t\tstream_close_delay 5m\n"
            "\t\t}}\n"
            "\t}}".format(key=key, port=world_port(index))
        )

    text = TEMPLATE_PATH.read_text(encoding="utf-8")
    text = text.replace("{$GLOBAL_OPTIONS_BLOCK}", global_options_block)
    text = text.replace("{$GAME_HOST}", clean_host)
    text = text.replace("{$WORLD_ROUTE_BLOCK}", "\n\n".join(route_blocks))
    return text.lstrip("\n")


def self_test() -> None:
    output = render("game.example.test", "admin@example.test")
    output_without_global_options = render("game.example.test")
    if output_without_global_options.startswith("\n"):
        raise SystemExit("Rendered Caddyfile must not start with a blank line")
    expected = [
        "game.example.test {",
        "email admin@example.test",
        "@master path /",
        "reverse_proxy 127.0.0.1:19080",
    ]
    for key in world_keys():
        expected.append(f"@world_{key} path /{key}")
    for needle in expected:
        if needle not in output:
            raise SystemExit(f"Rendered Caddyfile missing: {needle}")
    expected_proxy_count = 1 + len(world_keys())
    actual_proxy_count = output.count("reverse_proxy 127.0.0.1:")
    if actual_proxy_count != expected_proxy_count:
        raise SystemExit(
            f"Expected {expected_proxy_count} reverse_proxy entries, got {actual_proxy_count}"
        )
    print("CADDYFILE_RENDER_SELF_TEST_PASS")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="")
    parser.add_argument("--acme-email", default="")
    parser.add_argument("--output", default="")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return
    if not args.host:
        raise SystemExit("--host is required unless --self-test is used")

    output = render(args.host, args.acme_email)
    if args.output:
        Path(args.output).write_text(output, encoding="utf-8", newline="\n")
        print(f"CADDYFILE_RENDERED path={args.output}")
    else:
        print(output, end="")


if __name__ == "__main__":
    main()
