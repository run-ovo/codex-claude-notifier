#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '[codex-wsl-toast-notifier] ERROR: %s\n' "$1" >&2
  exit 1
}

mode="${1:-all}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
claude_home="${CLAUDE_HOME:-$HOME/.claude}"
codex_hooks_dir="$codex_home/hooks"
claude_hooks_dir="$claude_home/hooks"
codex_done_script="$codex_hooks_dir/codex_done.ps1"
codex_permission_script="$codex_hooks_dir/codex_permission_notify.ps1"
claude_done_script="$claude_hooks_dir/claude_done.ps1"
claude_notification_script="$claude_hooks_dir/claude_notification_notify.ps1"

case "$mode" in
  all|codex|claude) ;;
  *) fail "usage: bash scripts/test-wsl-notification.sh [all|codex|claude]" ;;
esac

command -v powershell.exe >/dev/null 2>&1 || fail "powershell.exe not found. Run this inside WSL on Windows."
command -v wslpath >/dev/null 2>&1 || fail "wslpath not found. Run this inside WSL."

cwd="$(pwd)"

if [[ "$mode" == "all" || "$mode" == "codex" ]]; then
  [[ -f "$codex_done_script" ]] || fail "hook script not found: $codex_done_script"
  [[ -f "$codex_permission_script" ]] || fail "hook script not found: $codex_permission_script"

  codex_done_payload="{\"hook_event_name\":\"Stop\",\"cwd\":\"$cwd\",\"session_id\":\"test-session-12345678\",\"last_assistant_message\":\"Smoke test completed.\"}"
  codex_permission_payload="{\"hook_event_name\":\"PermissionRequest\",\"cwd\":\"$cwd\",\"session_id\":\"test-session-12345678\",\"tool_name\":\"shell\",\"tool_input\":{\"command\":\"echo test\"}}"

  printf '[codex-wsl-toast-notifier] Invoking Codex Stop hook\n'
  printf '%s' "$codex_done_payload" | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$codex_done_script")"
  printf '\n'

  printf '[codex-wsl-toast-notifier] Invoking Codex PermissionRequest hook\n'
  printf '%s' "$codex_permission_payload" | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$codex_permission_script")"
  printf '\n'

  printf '[codex-wsl-toast-notifier] Codex test payloads sent. Check Windows notifications and %s/codex_done.log\n' "$codex_hooks_dir"
fi

if [[ "$mode" == "all" || "$mode" == "claude" ]]; then
  [[ -f "$claude_done_script" ]] || fail "hook script not found: $claude_done_script"
  [[ -f "$claude_notification_script" ]] || fail "hook script not found: $claude_notification_script"

  claude_done_payload="{\"hook_event_name\":\"Stop\",\"cwd\":\"$cwd\",\"session_id\":\"claude-test-session-12345678\",\"transcript_path\":\"/tmp/claude-test-transcript.jsonl\",\"stop_hook_active\":false}"
  claude_notification_payload="{\"hook_event_name\":\"Notification\",\"cwd\":\"$cwd\",\"session_id\":\"claude-test-session-12345678\",\"message\":\"Claude Code needs your permission to continue.\"}"

  printf '[codex-wsl-toast-notifier] Invoking Claude Code Stop hook\n'
  printf '%s' "$claude_done_payload" | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$claude_done_script")"
  printf '\n'

  printf '[codex-wsl-toast-notifier] Invoking Claude Code Notification hook\n'
  printf '%s' "$claude_notification_payload" | powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$claude_notification_script")"
  printf '\n'

  printf '[codex-wsl-toast-notifier] Claude Code test payloads sent. Check Windows notifications and %s/claude_code.log\n' "$claude_hooks_dir"
fi
