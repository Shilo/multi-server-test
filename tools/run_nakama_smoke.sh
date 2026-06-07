#!/usr/bin/env bash
set -euo pipefail

GODOT="${GODOT:-godot}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-45}"
CLIENT_COUNT="${CLIENT_COUNT:-1}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="$PROJECT_ROOT/.logs/nakama-smoke"
ORCHESTRATOR_EXE="${ORCHESTRATOR_EXE:-}"

rm -rf "$LOG_ROOT"
mkdir -p "$LOG_ROOT"

"$GODOT" --headless --editor --path "$PROJECT_ROOT" --quit

if [[ -z "$ORCHESTRATOR_EXE" ]]; then
  ORCHESTRATOR_EXE="$LOG_ROOT/virtucade-orchestrator"
  (cd "$PROJECT_ROOT" && go build -o "$ORCHESTRATOR_EXE" ./orchestrator)
fi

ORCH_PID=""
CLIENT_PIDS=()

cleanup() {
  for pid in "${CLIENT_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  if [[ -n "$ORCH_PID" ]]; then
    kill "$ORCH_PID" 2>/dev/null || true
  fi
  pkill -f "$PROJECT_ROOT.*--role world" 2>/dev/null || true
}
trap cleanup EXIT

"$ORCHESTRATOR_EXE" \
  --godot "$GODOT" \
  --project-root "$PROJECT_ROOT" \
  --key localdev-secret \
  --log-root "$LOG_ROOT/worlds" \
  > "$LOG_ROOT/orchestrator.out.log" \
  2> "$LOG_ROOT/orchestrator.err.log" &
ORCH_PID="$!"

deadline=$((SECONDS + 10))
while ! grep -q "ORCHESTRATOR_READY" "$LOG_ROOT/orchestrator.out.log" 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    cat "$LOG_ROOT/orchestrator.out.log" 2>/dev/null || true
    cat "$LOG_ROOT/orchestrator.err.log" 2>/dev/null || true
    echo "Timed out waiting for ORCHESTRATOR_READY" >&2
    exit 1
  fi
  sleep 0.1
done

for i in $(seq 1 "$CLIENT_COUNT"); do
  name="client"
  if [[ "$CLIENT_COUNT" -gt 1 ]]; then
    name="client$i"
  fi
  "$GODOT" \
    --headless \
    --path "$PROJECT_ROOT" \
    -- \
    --role client \
    --smoke-test \
    --device-id "virtucade-smoke-$i-$RANDOM" \
    > "$LOG_ROOT/$name.out.log" \
    2> "$LOG_ROOT/$name.err.log" &
  CLIENT_PIDS+=("$!")
done

for index in "${!CLIENT_PIDS[@]}"; do
  pid="${CLIENT_PIDS[$index]}"
  name="client"
  if [[ "$CLIENT_COUNT" -gt 1 ]]; then
    name="client$((index + 1))"
  fi

  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      kill "$pid" 2>/dev/null || true
      cat "$LOG_ROOT/$name.out.log" 2>/dev/null || true
      cat "$LOG_ROOT/$name.err.log" 2>/dev/null || true
      echo "Nakama smoke client $name timed out" >&2
      exit 1
    fi
    sleep 0.2
  done
  wait "$pid" || true

  if ! grep -q "SMOKE_PASS" "$LOG_ROOT/$name.out.log"; then
    cat "$LOG_ROOT/$name.out.log" 2>/dev/null || true
    cat "$LOG_ROOT/$name.err.log" 2>/dev/null || true
    echo "Nakama smoke did not produce SMOKE_PASS for $name" >&2
    exit 1
  fi
done

echo "NAKAMA_SMOKE_PASS clients=$CLIENT_COUNT logs=$LOG_ROOT"
