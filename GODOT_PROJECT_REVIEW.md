# Godot Project Optimization Review

**Scope:** Commit `62d953e` on branch `reverse-proxy` — "feat: add caddy reverse proxy support"  
**Date:** 2026-06-18  
**Review type:** Targeted security/safety/correctness audit (not full project review)

---

## 1. Executive Summary

**Overall assessment of reverse-proxy commit:** Mostly solid architecture with several sharp edges that need addressing before production use. The biggest risks are (1) an unsafe `sed` substitution in CI that silently corrupts env files on indentation changes, (2) no Caddyfile rollback on deploy failure, (3) the Godot-side smoke test is entirely unwired from CI, and (4) the `stream_close_delay 5m` configuration that may exhaust backend resources under load.

**Top 5 items to fix first:**
1. Replace fragile `sed` indentation strip in CI (Critical)
2. Add Caddyfile deploy rollback or pre-deploy backup (High)
3. Wire `net_config_smoke.gd` into CI (High)
4. Reduce `stream_close_delay` or justify the 5-minute value (Medium)
5. Add caddy `systemctl start` step to docs for first-run (Medium)

---

## 2. Scope and Methodology

- **Focus:** Caddy WSS reverse-proxy support, CI deploy safety, systemd/Caddy docs, NetConfig URL/bind behavior, temporary world route safety, security, minimalism, test gaps
- **Files examined:** 13 changed files (full diff reviewed)
- **Godot engine:** v4.6.3
- **Validation limits:** Static analysis only; no runtime profiling or live deploy testing performed

---

## 3. Findings Ordered by Severity

---

### 3.1 [CRITICAL] CI: `sed -i` indentation strip silently corrupts env file on YAML reformat

- **Category:** CI / Deploy Safety
- **Confidence:** High
- **Evidence:** `.github/workflows/deploy-github-pages.yml:274`

```yaml
cat > "$RUNNER_TEMP/virtucade.env" <<EOF
MULTI_SERVER_BIND_HOST=127.0.0.1
MULTI_SERVER_PUBLIC_MASTER_URL=wss://${VIRTUCADE_GAME_HOST}/
MULTI_SERVER_PUBLIC_WORLD_URL_TEMPLATE=wss://${VIRTUCADE_GAME_HOST}/{world_key}
MULTI_SERVER_CLIENT_HOST=${VIRTUCADE_GAME_HOST}
MULTI_SERVER_CLIENT_SCHEME=wss
MULTI_SERVER_WORLD_PACK_DIR=/opt/virtucade/world_packs
MULTI_SERVER_WORLD_PACK_BASE_URL=https://shilo.github.io/multi-server-test/world_packs
EOF
sed -i 's/^          //' "$RUNNER_TEMP/virtucade.env"
```

- **Why this matters:** The `sed` depends on exactly 10 leading spaces matching the YAML indentation of the heredoc body. If anyone reindents the YAML block (e.g., adds/removes a nesting level), the env file becomes silently garbled — some lines get partial prefix stripping, others are left with leading spaces. Environment variables with leading whitespace are treated as empty or malformed by systemd and GDScript's `strip_edges()`.
- **Recommended change:** Replace with one of:
  1. Use `<<-EOF` (tab-stripping heredoc) — requires tabs, not spaces
  2. Use bash here-string with `printf` to avoid indentation entirely
  3. Write the file with `echo` commands (one per line) without indentation
  4. Extract to a separate script that generates the env file

  **Simplest fix:**
  ```yaml
  run: |
    set -euo pipefail
    ...
    printf '%s\n' \
      "MULTI_SERVER_BIND_HOST=127.0.0.1" \
      "MULTI_SERVER_PUBLIC_MASTER_URL=wss://${VIRTUCADE_GAME_HOST}/" \
      "MULTI_SERVER_PUBLIC_WORLD_URL_TEMPLATE=wss://${VIRTUCADE_GAME_HOST}/{world_key}" \
      "MULTI_SERVER_CLIENT_HOST=${VIRTUCADE_GAME_HOST}" \
      "MULTI_SERVER_CLIENT_SCHEME=wss" \
      "MULTI_SERVER_WORLD_PACK_DIR=/opt/virtucade/world_packs" \
      "MULTI_SERVER_WORLD_PACK_BASE_URL=https://shilo.github.io/multi-server-test/world_packs" \
      > "$RUNNER_TEMP/virtucade.env"
  ```
- **Expected benefit:** Eliminates silent corruption risk; no `sed` dependency
- **Behavior impact:** None — same file content, different generation method
- **Implementation risk:** Trivial (must verify each line is correct)
- **Validation method:** `diff` the old and new generated output

---

### 3.2 [HIGH] CI: Caddyfile deploy has no rollback on server restart failure

- **Category:** CI / Deploy Safety / Security
- **Confidence:** High
- **Evidence:** `.github/workflows/deploy-github-pages.yml` — The remote SSH command performs operations in this order:
  1. Validate and install Caddyfile → `sudo systemctl reload caddy`
  2. Write `virtucade.env`
  3. Stop `virtucade`, swap server binary, start `virtucade`

  If step 3 fails (server binary corrupt, config mismatch, segfault), Caddy is already pointing at a dead or misconfigured backend, but the old Caddyfile is lost.
- **Why this matters:** Caddy overwrite is irreversible in the current flow. A failed deploy leaves Caddy proxying to a stopped service, causing production downtime with no automated way to revert.
- **Recommended change:** Back up the existing Caddyfile before overwriting:
  ```bash
  if [ -f /tmp/virtucade-Caddyfile ]; then
    sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak.$(date +%s) || true
    sudo caddy validate --config /tmp/virtucade-Caddyfile
    sudo install -m 644 /tmp/virtucade-Caddyfile /etc/caddy/Caddyfile
    sudo systemctl reload caddy
    test "$(sudo systemctl is-active caddy)" = active
  fi
  ```
  Additionally, consider moving the Caddy install step AFTER the server restart succeeds, so Caddy is only updated once the backend is confirmed healthy.
- **Expected benefit:** Manual rollback path; reduced blast radius
- **Behavior impact:** None — adds a backup file on disk
- **Implementation risk:** Low — backup is a non-destructive addition
- **Validation method:** Trigger deploy with an intentionally broken server binary, verify backup exists

---

### 3.3 [HIGH] Test: `net_config_smoke.gd` not wired into CI

- **Category:** Test Gaps
- **Confidence:** High
- **Evidence:**
  - `tools/net_config_smoke.gd` exists (44 lines, 7 assertions)
  - `tools/run_net_config_smoke.ps1` exists (15 lines) but requires a local Godot binary
  - No CI workflow step invokes it (`grep -r "net_config_smoke" .github/` returns nothing)
  - The smoke test covers exactly the new code paths: `bind_host()`, `public_master_url()`, `public_world_url_template()`, `master_url()`, `world_url()` with public URL override
- **Why this matters:** The core URL construction logic changed in this commit (three new env vars, fallback logic in `master_url()` and `world_url()`). The smoke test validates exactly these paths but won't catch regressions because nothing runs it.
- **Recommended change:** Add a CI step after the build that runs Godot headless with the smoke script. Since the CI already has a Godot Linux export, reuse it:
  ```yaml
  - name: Run net_config smoke test
    shell: bash
    run: |
      ./builds/server/multi-server-test.x86_64 --headless --script tools/net_config_smoke.gd
      # Check exit code / output for NET_CONFIG_SMOKE_PASS
  ```
  Or add a Linux-headless CI build artifact that can run the smoke test.
- **Expected benefit:** Catches URL/bind regression before deploy
- **Behavior impact:** None
- **Implementation risk:** Medium — needs a headless Godot binary available in CI
- **Validation method:** CI run passes the smoke step

---

### 3.4 [HIGH] CI: `MULTI_SERVER_WORLD_PACK_BASE_URL` hardcoded to personal GitHub username

- **Category:** CI / Security / Hardcoded values
- **Confidence:** High
- **Evidence:** `.github/workflows/deploy-github-pages.yml` (inside the env file heredoc) and `shared/net/net_config.gd:6`
  ```
  MULTI_SERVER_WORLD_PACK_BASE_URL=https://shilo.github.io/multi-server-test/world_packs
  ```
  Also hardcoded in `net_config.gd:6`:
  ```gdscript
  const GITHUB_PAGES_WORLD_PACK_BASE_URL := "https://shilo.github.io/multi-server-test/world_packs"
  ```
  The CI-generated `virtucade.env` duplicates this hardcoded URL.
- **Why this matters:** Anyone forking this repo must hunt down this URL and change it in two places. A mismatch causes clients to download PCK files from the wrong host, which is a silent runtime failure.
- **Recommended change:** Derive from the GitHub Pages URL in CI:
  ```yaml
  MULTI_SERVER_WORLD_PACK_BASE_URL=https://${GITHUB_REPOSITORY_OWNER}.github.io/${GITHUB_REPOSITORY#*/}/world_packs
  ```
  In `net_config.gd`, the hardcoded fallback is acceptable as a default, but the CI-generated env should override it. The CI env file should use a GitHub Actions context variable instead of a literal.
- **Expected benefit:** Works for any fork without code changes
- **Behavior impact:** None for current repo; enables forking
- **Implementation risk:** Low
- **Validation method:** Fork the repo, run CI, verify PCK URLs resolve correctly

---

### 3.5 [MEDIUM] Caddy: `stream_close_delay 5m` may exhaust backend connections under load

- **Category:** Caddy Config / Performance / Stability
- **Confidence:** Medium
- **Evidence:** `deploy/caddy/Caddyfile.template:6` — Applied to both master and all world routes:
  ```
  reverse_proxy 127.0.0.1:19080 {
      stream_close_delay 5m
  }
  ```
  `tools/render_caddyfile.py:49-50` — All world routes also get the same 5-minute delay.
- **Why this matters:** `stream_close_delay` keeps the *backend connection* alive for 5 minutes after the *client* disconnects, waiting for a potential reconnection. With many unique clients (especially Web clients that refresh or navigate), each disconnect leaves a backend TCP socket open for 5 minutes. Godot WebSocket servers have limited connection capacity. A load test with churning clients could exhaust the Godot server's available peer slots.
- **Recommended change:** Reduce to `2m` or `1m`, or remove entirely if reconnection within 5 minutes is not a measured requirement. If the value is intentional (e.g., browser tab sleep/wake reconnection), document the rationale.
- **Expected benefit:** Reduced backend connection pressure under load
- **Behavior impact:** Clients that disconnect and reconnect after the delay window would get a fresh backend connection instead of reusing the old one. This is generally harmless for WebSocket.
- **Implementation risk:** Low — Caddy will establish a new backend connection if the old one was closed
- **Validation method:** Load test with 100+ Web clients connecting/disconnecting; monitor Godot peer count and Caddy connection stats

---

### 3.6 [MEDIUM] Deploy: Caddy `systemctl reload` fails on first-ever deploy (service not started)

- **Category:** Docs / Deploy Safety
- **Confidence:** High
- **Evidence:** `docs/digitalocean-vps-setup.md:156-158` instructs:
  ```bash
  sudo systemctl enable caddy
  ```
  but never runs `sudo systemctl start caddy`. The CI deploy step (`deploy-github-pages.yml`) runs:
  ```bash
  sudo systemctl reload caddy
  test "$(sudo systemctl is-active caddy)" = active
  ```
  If Caddy has never been started (only enabled), `systemctl reload` on a stopped service fails on some systemd versions, or succeeds but leaves the service stopped. Either way, the `is-active` check fails and the deploy aborts.
- **Why this matters:** First-time setup fails silently or confusingly. The operator must manually `systemctl start caddy` before the first CI deploy.
- **Recommended change:**
  1. In docs: change `sudo systemctl enable caddy` to `sudo systemctl enable --now caddy`
  2. In CI: replace `sudo systemctl reload caddy` with:
     ```bash
     if sudo systemctl is-active --quiet caddy; then
       sudo systemctl reload caddy
     else
       sudo systemctl start caddy
     fi
     ```
- **Expected benefit:** First deploy works without manual intervention
- **Behavior impact:** None — just handles the initial state
- **Implementation risk:** Very low
- **Validation method:** Deploy to a fresh VPS that has Caddy installed but never started

---

### 3.7 [MEDIUM] CI: Remote SSH command is a fragile >2000-char one-liner

- **Category:** CI / Deploy Safety / Maintainability
- **Confidence:** High
- **Evidence:** `.github/workflows/deploy-github-pages.yml` — The VPS deploy step passes a single long SSH command string containing conditionals, file operations, systemctl calls, and error handling all in one line. It is hard to audit, impossible to step-debug, and any quoting error breaks the entire deploy.
- **Why this matters:** A single typo, shell expansion surprise, or special character in a variable (e.g., `VIRTUCADE_GAME_HOST` containing a shell metacharacter) could cause the remote command to partially execute in an unpredictable state.
- **Recommended change:** Move the remote logic into a deploy script (e.g., `tools/vps_deploy.sh`) that is SCP'd to the VPS first, then executed:
  ```bash
  scp tools/vps_deploy.sh "${VIRTUCADE_USER}@${VIRTUCADE_HOST}:/tmp/"
  ssh "${VIRTUCADE_USER}@${VIRTUCADE_HOST}" \
    "sudo bash /tmp/vps_deploy.sh"
  ```
  This keeps the deploy logic in a version-controlled, lintable, testable script.
- **Expected benefit:** Auditable, debuggable, testable deploy logic
- **Behavior impact:** None — same operations, different invocation
- **Implementation risk:** Medium — requires extracting and validating the script
- **Validation method:** Run the script manually on a staging VPS

---

### 3.8 [MEDIUM] Two independent world-key discovery mechanisms risk port drift

- **Category:** Architecture / Consistency
- **Confidence:** Medium
- **Evidence:**
  - **Python side:** `tools/render_caddyfile.py:13-28` discovers world keys by scanning `server/worlds/` directories and sorting alphabetically
  - **Godot side:** `shared/net/net_config.gd:79-96` discovers world keys via `ResourceLoader.list_directory()` and sorts alphabetically
  - Port assignment: `19081 + index` (both sides)
  
  If either sorting, filtering, or directory scanning logic diverges, Caddy routes point at wrong Godot ports.
- **Why this matters:** Adding a new `.tscn` that doesn't follow conventions, a directory with no scene, or a world key with special characters could cause the two systems to disagree on the world key list and therefore the port mapping. The Python side validates with `WORLD_RE` and `.tscn` check; the GDScript side checks `ResourceLoader.exists()` with a PackedScene. These are not identical checks.
- **Recommended change:** Generate a world-keys manifest file during the build that both the Python renderer and the Godot server consume, ensuring a single source of truth. Alternatively, add a CI consistency check that asserts `render_caddyfile.py` and `net_config.gd` produce the same port mappings.
- **Expected benefit:** Eliminates silent port-drift risk
- **Behavior impact:** None — enforces consistency, doesn't change behavior
- **Implementation risk:** Medium — requires a manifest format and build step
- **Validation method:** CI step: `python3 tools/render_caddyfile.py --dump-ports` and compare with expected values

---

### 3.9 [MEDIUM] `net_config_smoke.gd` incomplete coverage — no edge case tests

- **Category:** Test Gaps
- **Confidence:** High
- **Evidence:** `tools/net_config_smoke.gd` — The smoke test covers:
  - Default URL construction (no env vars)
  - Full override with all three new env vars set
  
  It does NOT test:
  - Partial override (e.g., `PUBLIC_MASTER_URL` set but `PUBLIC_WORLD_URL_TEMPLATE` NOT set — `world_url()` falls through to `ws://host:port` composition, which is a mixed-URL scenario)
  - `BIND_HOST` set to empty string after `strip_edges()`
  - `BIND_HOST` set to whitespace-only string
  - `PUBLIC_MASTER_URL` set to a URL without trailing slash (user error but common)
  - `PUBLIC_WORLD_URL_TEMPLATE` missing `{world_key}` placeholder (user error)
  - World key with special characters (e.g., `my world`) and `uri_encode()` behavior
  - `MULTI_SERVER_CLIENT_SCHEME` / `MULTI_SERVER_CLIENT_HOST` mixed with public URL overrides
- **Why this matters:** Partial configuration is the most likely operator error. The mixed-URL scenario (master advertises `wss://`, but worlds still use `ws://host:port`) is a silent runtime bug.
- **Recommended change:** Add test cases:
  ```gdscript
  # Partial: master public URL set, world template NOT set
  OS.set_environment(NET_CONFIG.PUBLIC_MASTER_URL_ENV, "wss://game.example.test/")
  _expect("partial_master", NET_CONFIG.master_url(), "wss://game.example.test/")
  _expect("partial_world", NET_CONFIG.world_url("hub"), "ws://127.0.0.1:19081")  # falls through
  
  # Whitespace-only bind host
  OS.set_environment(NET_CONFIG.BIND_HOST_ENV, "   ")
  _expect("whitespace_bind", NET_CONFIG.bind_host(), "*")  # strip_edges returns ""
  
  # Template missing placeholder
  OS.set_environment(NET_CONFIG.PUBLIC_WORLD_URL_TEMPLATE_ENV, "wss://example.com/")
  # world_url would return "wss://example.com/" with no world key — likely a bug
  ```
- **Expected benefit:** Catches operator misconfiguration at test time
- **Behavior impact:** None — test-only
- **Implementation risk:** Low — add test cases
- **Validation method:** Run `net_config_smoke.gd` and verify all expectations pass

---

### 3.10 [MEDIUM] `render_caddyfile.py` world key regex is more permissive than URL-safe

- **Category:** Caddy Config / Security
- **Confidence:** Medium
- **Evidence:** `tools/render_caddyfile.py:10`
  ```python
  WORLD_RE = re.compile(r"^[A-Za-z0-9_-]+$")
  ```
  This allows underscores and hyphens. But the `GAME_HOST` regex on line 9:
  ```python
  HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$")
  ```
  allows dots. If a world key coincidentally contains a dot (e.g., `my.world`), it's rejected by `WORLD_RE`. But if someone relaxes `WORLD_RE` later without considering Caddy route semantics, double-dots or path traversal could slip through.
- **Why this matters:** World keys become literal URL path segments in Caddy routes (`/{world_key}`). Characters like `..`, `/`, `\`, or `%` could create path traversal or route confusion. The current regex is safe, but there's no comment explaining the constraint.
- **Recommended change:** Add a comment explaining the safety constraint:
  ```python
  # World keys become URL path segments in Caddy routes; must be safe for path matching
  WORLD_RE = re.compile(r"^[A-Za-z0-9_-]+$")
  ```
  Consider also rejecting `_`-only or `-`-only keys that could collide with Caddy internal paths.
- **Expected benefit:** Prevents future maintainer from relaxing the regex unsafely
- **Behavior impact:** None — documentation only
- **Implementation risk:** None
- **Validation method:** Code review

---

### 3.11 [LOW] `render_caddyfile.py` self-test doesn't validate route count

- **Category:** Test Gaps
- **Confidence:** High
- **Evidence:** `tools/render_caddyfile.py:62-75` — The `self_test()` function checks for the presence of expected strings but does NOT assert the **number** of world routes. If a world is added/removed from the repo, the self-test still passes because it only checks that existing keys are in the output.
- **Why this matters:** The self-test would not catch a scenario where the renderer accidentally duplicates routes or skips a world. It only validates "these strings exist" not "exactly these routes exist and no others."
- **Recommended change:** Count the number of `reverse_proxy` occurrences in the output and assert it equals `1 + len(world_keys())` (one master + one per world):
  ```python
  expected_count = 1 + len(world_keys())
  actual_count = output.count("reverse_proxy")
  if actual_count != expected_count:
      raise SystemExit(f"Expected {expected_count} reverse_proxy blocks, got {actual_count}")
  ```
- **Expected benefit:** Catches route duplication/omission bugs
- **Behavior impact:** None — test-only
- **Implementation risk:** Low
- **Validation method:** Temporarily add/remove a world directory, run self-test, verify it fails

---

### 3.12 [LOW] `net_config_smoke.gd` logs expectations before checking failures — `quit(0)` on pass but `push_error` then `quit(n)` on failure

- **Category:** Code Quality
- **Confidence:** High
- **Evidence:** `tools/net_config_smoke.gd:28-32`
  ```gdscript
  if failures == 0:
      print("NET_CONFIG_SMOKE_PASS")
  else:
      push_error("NET_CONFIG_SMOKE_FAIL failures=%d" % failures)
  quit(failures)
  ```
  `quit(0)` on pass is correct. On failure, `push_error` is called but `quit(failures)` uses the count as exit code. Godot headless exits with the given code. A CI step can check `$? -ne 0` to detect failure. This works, but the exit code is the number of failures (could be 1, 2, etc.), which is unusual. Most CI expects 0 or 1.
- **Why this matters:** Minor — the CI step checking `$LASTEXITCODE -ne 0` correctly detects failure. But a non-1 non-zero exit code could confuse generic CI tooling.
- **Recommended change:** `quit(1 if failures > 0 else 0)` for standard exit codes
- **Expected benefit:** Standard exit code semantics
- **Behavior impact:** None — CI still passes/fails correctly
- **Implementation risk:** None
- **Validation method:** Run smoke with intentional failure, verify exit code is 1

---

### 3.13 [LOW] `run_net_config_smoke.ps1` hardcodes a local Godot path

- **Category:** Tooling / Portability
- **Confidence:** High
- **Evidence:** `tools/run_net_config_smoke.ps1:5`
  ```powershell
  $Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe"
  ```
  Falls back to a local path that only exists on the author's machine.
- **Why this matters:** Low — the script checks `$env:GODOT_BIN` first. But the hardcoded path is misleading for other contributors.
- **Recommended change:** Remove the hardcoded default, or error with "Set GODOT_BIN" if not found:
  ```powershell
  if ([string]::IsNullOrWhiteSpace($Godot)) {
      throw "GODOT_BIN is not set. Example: `$env:GODOT_BIN = 'C:\path\to\godot.exe'"
  }
  ```
- **Expected benefit:** Clear error message for new contributors
- **Behavior impact:** Breaks local-only smoke workflow for author; acceptable trade-off
- **Implementation risk:** None
- **Validation method:** Run without GODOT_BIN set, verify clear error

---

### 3.14 [LOW] `render_caddyfile.py` global options block format has trailing blank line

- **Category:** Code Quality / Caddy Config
- **Confidence:** Medium
- **Evidence:** `tools/render_caddyfile.py:42`
  ```python
  global_options_block = "{\n\temail %s\n}\n\n" % acme_email.strip()
  ```
  When `acme_email` is provided, this emits a valid Caddy global options block followed by a blank line separator. When `acme_email` is empty, `global_options_block` is `""`, which means `{$GLOBAL_OPTIONS_BLOCK}` in the template is replaced with nothing, resulting in a leading blank line before `{$GAME_HOST} {`. This is harmless for Caddy but unnecessary.
- **Why this matters:** Cosmetic — Caddy ignores blank lines. But a clean Caddyfile is easier to debug on the VPS.
- **Recommended change:** Strip leading whitespace from the rendered output:
  ```python
  return text.lstrip("\n")
  ```
- **Expected benefit:** Cleaner Caddyfile
- **Behavior impact:** None — Caddy parses identically
- **Implementation risk:** None
- **Validation method:** `caddy validate` on rendered output

---

### 3.15 [LOW] Docs: Hetzner readiness doc states ports 19080-19084 should be closed but doesn't give the firewall command

- **Category:** Docs
- **Confidence:** Medium
- **Evidence:** `docs/hetzner-vps-readiness.md:98-101`
  > Godot still listens on 19080-19084, but those ports should bind to 127.0.0.1 and stay closed publicly when Caddy is enabled.
  
  The doc explains the desired state but doesn't provide the exact `ufw` or Hetzner firewall rule to close those ports. A user following the old instructions (which has them open) won't know how to close them.
- **Why this matters:** If ports 19080-19084 remain publicly open AND the server binds to `127.0.0.1`, there's no security risk (the ports are unreachable). But if someone later removes `BIND_HOST=127.0.0.1`, those ports become exposed.
- **Recommended change:** Add explicit firewall commands:
  ```bash
  sudo ufw delete allow 19080:19084/tcp
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
  ```
- **Expected benefit:** Defense-in-depth; clear instructions
- **Behavior impact:** None — matches documented intent
- **Implementation risk:** None
- **Validation method:** `sudo ufw status` shows correct rules

---

### 3.16 [INFO] Caddyfile template uses tabs for indentation; Python renderer uses tabs too

- **Category:** Code Quality
- **Confidence:** High
- **Evidence:** `deploy/caddy/Caddyfile.template` — All indentation uses tabs (`\t`). `render_caddyfile.py:47` uses `\t` consistently.
- **Why this matters:** Not a bug — consistent formatting is good. Worth noting that mixing tabs and spaces in Caddyfiles can cause issues with some Caddy parsers (though current Caddy handles both).
- **Recommended change:** No change needed. Note for awareness.
- **Expected benefit:** None — informational
- **Behavior impact:** None
- **Implementation risk:** None

---

### 3.17 [INFO] `master_url()` returns `wss://<host>/` (trailing slash) — intentional per Caddy `@master path /`

- **Category:** Architecture Note
- **Confidence:** High
- **Evidence:** `shared/net/net_config.gd:23-27` returns `public_master_url()` as-is when set. CI sets it to `wss://${VIRTUCADE_GAME_HOST}/`. This aligns with Caddy's `@master path /` matcher, which matches exactly `/`.
- **Why this matters:** Informational — the design is consistent. Changing the master URL to omit the trailing slash would break Caddy route matching.
- **Recommended change:** No change needed. Document the trailing slash requirement.
- **Expected benefit:** None — informational

---

## 4. Security Summary

| Finding | Severity |
|---|---|
| No Caddyfile backup/rollback on failed deploy | High (#3.2) |
| Hardcoded GitHub username in CI env file | High (#3.4) |
| Fragile SSH one-liner — quoting risk | Medium (#3.7) |
| World key regex lacks documentation of security rationale | Medium (#3.10) |
| Firewall port-closing instructions missing from docs | Low (#3.15) |

**Notable:** The overall architecture is security-conscious — Godot binds to `127.0.0.1` (not `*`) when Caddy is enabled, and Caddy handles TLS termination on `443`. Public WSS is the only exposed service. No secrets are committed to the repo.

---

## 5. Test Gap Summary

| Gap | Severity |
|---|---|
| `net_config_smoke.gd` not in CI | High (#3.3) |
| Incomplete smoke test coverage (partial config, edge cases) | Medium (#3.9) |
| `render_caddyfile.py` self-test doesn't validate route count | Low (#3.11) |
| No E2E test of WSS through Caddy (acceptance test) | Noted |
| No load test of Caddy with `stream_close_delay` | Noted |

---

## 6. Prioritized Recommendations

### Immediate (before production use)

1. **Fix `sed` indentation strip** (#3.1) — replace with `printf`-based env file generation
2. **Add Caddyfile backup** (#3.2) — backup existing Caddyfile before overwrite
3. **Wire `net_config_smoke.gd` into CI** (#3.3) — run Godot headless smoke test in workflow

### Next

4. **Reduce `stream_close_delay`** (#3.5) — change to `2m` or remove, document rationale
5. **Fix first-deploy Caddy start** (#3.6) — docs: `enable --now`; CI: handle stopped state
6. **Extract remote deploy into script** (#3.7) — `tools/vps_deploy.sh`
7. **Add partial-config smoke tests** (#3.9) — test mixed public URL + default world URL
8. **Derive world pack URL from GitHub context** (#3.4) — use `$GITHUB_REPOSITORY_OWNER`

### Later

9. Add world-key manifest to prevent port drift (#3.8)
10. Add route count assertion to Caddy self-test (#3.11)
11. Add firewall close commands to Hetzner docs (#3.15)
12. Standardize smoke test exit codes (#3.12)

### Do Not Change / Intentionally Keep

- Trailing slash on `master_url` — required for Caddy `/` route match
- Tab indentation in Caddyfile — consistent, not broken
- Static Caddyfile with per-world routes — intentional design, documented
- `_web_query_value` fallback on server — correctly gated behind `OS.has_feature("web")`

---

## 7. Open Questions

1. **`stream_close_delay` value:** Was 5 minutes chosen based on a specific reconnection requirement, or is it arbitrary? Browser tab visibility events might need 1-2 minutes; 5 seems long.

2. **Caddyfile route for world keys with special names:** The `WORLD_RE` rejects keys with dots, slashes, etc. If someone names a world `my.world`, the renderer will refuse to generate a Caddyfile. Is this error surfaced clearly enough in CI?

3. **ACME email optional?** The Caddy template allows empty `acme_email`. Caddy's automatic HTTPS works without email in zero-email mode, but Let's Encrypt strongly recommends providing one for certificate expiry notifications. Should the CI warn when it's missing?

4. **VPS without Caddy:** The deploy step always tries to validate/install Caddy config when `VIRTUCADE_GAME_HOST` is set. If the VPS doesn't have Caddy installed, the deploy fails. Is there a migration path for existing VPS setups?

---

## 8. Appendix: Files Reviewed

| File | Lines | Summary |
|---|---|---|
| `.github/workflows/deploy-github-pages.yml` | ~400 | CI deploy with new Caddy steps |
| `deploy/caddy/Caddyfile.template` | 15 | Caddy reverse-proxy template |
| `tools/render_caddyfile.py` | 101 | Caddyfile renderer + self-test |
| `tools/net_config_smoke.gd` | 44 | NetConfig URL/bind smoke test |
| `tools/run_net_config_smoke.ps1` | 15 | Windows PowerShell runner for smoke test |
| `shared/net/net_config.gd` | 252 | URL/bind/env config + 3 new functions |
| `server/master/master.gd` | 103 | Master now uses `bind_host()` |
| `server/world/world.gd` | 649 | World now uses `bind_host()` |
| `README.md` | ~700 | Reverse-proxy env var docs |
| `docs/digitalocean-vps-setup.md` | ~450 | Caddy install + firewall docs |
| `docs/hetzner-vps-readiness.md` | ~140 | Reverse-proxy firewall update |
| `docs/vps-server-redeploy-strategy.md` | ~250 | Updated deploy flow |
| `docs/wss-native-vs-reverse-proxy-research.md` | ~1010 | Implementation status update |
