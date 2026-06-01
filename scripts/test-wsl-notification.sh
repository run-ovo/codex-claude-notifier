#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '[codex-wsl-toast-notifier] ERROR: %s\n' "$1" >&2
  exit 1
}

codex_home="${CODEX_HOME:-$HOME/.codex}"
hooks_dir="$codex_home/hooks"
done_script="$hooks_dir/codex_done.ps1"
permission_script="$hooks_dir/codex_permission_notify.ps1"

command -v powershell.exe >/dev/null 2>&1 || fail "powershell.exe not found. Run this inside WSL on Windows."
command -v wslpath >/dev/null 2>&1 || fail "wslpath not found. Run this inside WSL."
[[ -f "$done_script" ]] || fail "hook script not found: $done_script"
[[ -f "$permission_script" ]] || fail "hook script not found: $permission_script"

cwd="$(pwd)"
done_payload="{\"hook_event_name\":\"Stop\",\"cwd\":\"$cwd\",\"session_id\":\"test-session-12345678\",\"last_assistant_message\":\"Smoke test completed.\"}"
permission_payload="{\"hook_event_name\":\"PermissionRequest\",\"cwd\":\"$cwd\",\"session_id\":\"test-session-12345678\",\"tool_name\":\"shell\",\"tool_input\":{\"command\":\"echo test\"}}"

printf '[codex-wsl-toast-notifier] Invoking Stop hook\n'
printf '%s' "$done_payload" | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$done_script")"
printf '\n'

printf '[codex-wsl-toast-notifier] Invoking PermissionRequest hook\n'
printf '%s' "$permission_payload" | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$permission_script")"
printf '\n'

printf '[codex-wsl-toast-notifier] Test payloads sent. Check Windows notifications and %s/codex_done.log\n' "$hooks_dir"
