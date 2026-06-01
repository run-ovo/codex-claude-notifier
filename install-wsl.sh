#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[codex-wsl-toast-notifier] %s\n' "$1"
}

fail() {
  printf '[codex-wsl-toast-notifier] ERROR: %s\n' "$1" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
codex_home="${CODEX_HOME:-$HOME/.codex}"
codex_hooks_dir="$codex_home/hooks"
codex_hooks_json="$codex_home/hooks.json"
codex_config_toml="$codex_home/config.toml"
claude_home="${CLAUDE_HOME:-$HOME/.claude}"
claude_hooks_dir="$claude_home/hooks"
claude_settings_json="$claude_home/settings.json"

command -v powershell.exe >/dev/null 2>&1 || fail "powershell.exe not found. Run this inside WSL on Windows."
command -v wslpath >/dev/null 2>&1 || fail "wslpath not found. Run this inside WSL."
command -v python3 >/dev/null 2>&1 || fail "python3 not found."

for required in \
  "$script_dir/hooks/codex_done.ps1" \
  "$script_dir/hooks/codex_permission_notify.ps1" \
  "$script_dir/hooks/codex_notify_worker.ps1" \
  "$script_dir/hooks/claude_done.ps1" \
  "$script_dir/hooks/claude_notification_notify.ps1"; do
  [[ -f "$required" ]] || fail "required file not found: $required"
done

make_encoded_command() {
  local windows_script_path="$1"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
    "\$code = \"& '$windows_script_path'\"; [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(\$code))" |
    tr -d '\r\n'
}

timestamp="$(date +%Y%m%d_%H%M%S)"

mkdir -p "$codex_hooks_dir"
cp "$script_dir/hooks/codex_done.ps1" "$codex_hooks_dir/codex_done.ps1"
cp "$script_dir/hooks/codex_permission_notify.ps1" "$codex_hooks_dir/codex_permission_notify.ps1"
cp "$script_dir/hooks/codex_notify_worker.ps1" "$codex_hooks_dir/codex_notify_worker.ps1"
log "Installed Codex hook scripts to $codex_hooks_dir"

codex_done_script_win="$(wslpath -w "$codex_hooks_dir/codex_done.ps1")"
codex_permission_script_win="$(wslpath -w "$codex_hooks_dir/codex_permission_notify.ps1")"
codex_done_encoded="$(make_encoded_command "$codex_done_script_win")"
codex_permission_encoded="$(make_encoded_command "$codex_permission_script_win")"
codex_done_command="powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $codex_done_encoded"
codex_permission_command="powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $codex_permission_encoded"

if [[ -f "$codex_hooks_json" ]]; then
  cp "$codex_hooks_json" "$codex_hooks_json.bak_$timestamp"
  log "Backed up hooks.json to $codex_hooks_json.bak_$timestamp"
fi

tmp_hooks="$(mktemp)"
python3 - "$codex_hooks_json" "$codex_done_command" "$codex_permission_command" > "$tmp_hooks" <<'PY'
import base64
import json
import re
import sys
from pathlib import Path

hooks_path = Path(sys.argv[1])
done_command = sys.argv[2]
permission_command = sys.argv[3]

if hooks_path.exists() and hooks_path.read_text(encoding="utf-8").strip():
    data = json.loads(hooks_path.read_text(encoding="utf-8"))
else:
    data = {}

if not isinstance(data, dict):
    data = {}

hooks_root = data.setdefault("hooks", {})
if not isinstance(hooks_root, dict):
    hooks_root = {}
    data["hooks"] = hooks_root


def is_notifier_hook(hook):
    if not isinstance(hook, dict):
        return False
    command = str(hook.get("command", ""))
    if (
        "codex_done.ps1" in command
        or "codex_permission_notify.ps1" in command
        or "codex-task-notifier" in command
        or "codex-wsl-toast-notifier" in command
    ):
        return True

    match = re.search(r"(?i)-EncodedCommand\s+\"?([A-Za-z0-9+/=]+)\"?", command)
    if not match:
        return False

    try:
        decoded = base64.b64decode(match.group(1)).decode("utf-16le", errors="ignore")
    except Exception:
        return False

    return (
        "codex_done.ps1" in decoded
        or "codex_permission_notify.ps1" in decoded
        or "codex-task-notifier" in decoded
        or "codex-wsl-toast-notifier" in decoded
    )


def merge_event(event_name, command):
    existing_groups = hooks_root.get(event_name, [])
    if not isinstance(existing_groups, list):
        existing_groups = []

    merged_groups = []
    for group in existing_groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            merged_groups.append(group)
            continue

        filtered_hooks = [
            hook for hook in group["hooks"]
            if not is_notifier_hook(hook)
        ]
        if filtered_hooks:
            next_group = dict(group)
            next_group["hooks"] = filtered_hooks
            merged_groups.append(next_group)

    merged_groups.append({
        "hooks": [
            {
                "type": "command",
                "command": command,
                "timeout": 10
            }
        ]
    })
    hooks_root[event_name] = merged_groups


merge_event("Stop", done_command)
merge_event("PermissionRequest", permission_command)

print(json.dumps(data, indent=2, ensure_ascii=False))
PY
mv "$tmp_hooks" "$codex_hooks_json"
log "Merged Codex notifier hooks into $codex_hooks_json"

ensure_hooks_feature() {
  local config_path="$1"
  local tmp_config
  tmp_config="$(mktemp)"

  if [[ ! -f "$config_path" ]]; then
    printf '[features]\nhooks = true\n' > "$config_path"
    log "Created config.toml with [features].hooks = true"
    return
  fi

  cp "$config_path" "$config_path.bak_$timestamp"
  log "Backed up config.toml to $config_path.bak_$timestamp"

  python3 - "$config_path" > "$tmp_config" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = text.splitlines()

features_index = None
for index, line in enumerate(lines):
    if re.match(r"^\s*\[features\]\s*$", line):
        features_index = index
        break

if features_index is None:
    output = text.rstrip() + "\n\n[features]\nhooks = true\n"
else:
    next_table = len(lines)
    for index in range(features_index + 1, len(lines)):
        if re.match(r"^\s*\[", lines[index]):
            next_table = index
            break

    hooks_index = None
    for index in range(features_index + 1, next_table):
        if re.match(r"^\s*hooks\s*=", lines[index]):
            hooks_index = index
            break

    if hooks_index is None:
        lines.insert(features_index + 1, "hooks = true")
    else:
        lines[hooks_index] = "hooks = true"
    output = "\n".join(lines) + "\n"

sys.stdout.write(output)
PY
  mv "$tmp_config" "$config_path"
  log "Ensured [features].hooks = true in $config_path"
}

ensure_hooks_feature "$codex_config_toml"

mkdir -p "$claude_hooks_dir"
cp "$script_dir/hooks/claude_done.ps1" "$claude_hooks_dir/claude_done.ps1"
cp "$script_dir/hooks/claude_notification_notify.ps1" "$claude_hooks_dir/claude_notification_notify.ps1"
cp "$script_dir/hooks/codex_notify_worker.ps1" "$claude_hooks_dir/codex_notify_worker.ps1"
log "Installed Claude Code hook scripts to $claude_hooks_dir"

claude_done_script_win="$(wslpath -w "$claude_hooks_dir/claude_done.ps1")"
claude_notification_script_win="$(wslpath -w "$claude_hooks_dir/claude_notification_notify.ps1")"
claude_done_encoded="$(make_encoded_command "$claude_done_script_win")"
claude_notification_encoded="$(make_encoded_command "$claude_notification_script_win")"
claude_done_command="powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $claude_done_encoded"
claude_notification_command="powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $claude_notification_encoded"

if [[ -f "$claude_settings_json" ]]; then
  cp "$claude_settings_json" "$claude_settings_json.bak_$timestamp"
  log "Backed up settings.json to $claude_settings_json.bak_$timestamp"
fi

tmp_settings="$(mktemp)"
python3 - "$claude_settings_json" "$claude_done_command" "$claude_notification_command" > "$tmp_settings" <<'PY'
import base64
import json
import re
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
done_command = sys.argv[2]
notification_command = sys.argv[3]

if settings_path.exists() and settings_path.read_text(encoding="utf-8").strip():
    data = json.loads(settings_path.read_text(encoding="utf-8"))
else:
    data = {}

if not isinstance(data, dict):
    data = {}

hooks_root = data.setdefault("hooks", {})
if not isinstance(hooks_root, dict):
    hooks_root = {}
    data["hooks"] = hooks_root


def decode_encoded_command(command):
    match = re.search(r"(?i)-EncodedCommand\s+\"?([A-Za-z0-9+/=]+)\"?", command)
    if not match:
        return ""
    try:
        return base64.b64decode(match.group(1)).decode("utf-16le", errors="ignore")
    except Exception:
        return ""


def is_claude_notifier_hook(hook):
    if not isinstance(hook, dict):
        return False
    command = str(hook.get("command", ""))
    combined = command + "\n" + decode_encoded_command(command)
    return (
        "claude_done.ps1" in combined
        or "claude_notification_notify.ps1" in combined
        or "claude-code-wsl-toast-notifier" in combined
    )


def merge_event(event_name, command):
    existing_groups = hooks_root.get(event_name, [])
    if not isinstance(existing_groups, list):
        existing_groups = []

    merged_groups = []
    for group in existing_groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            merged_groups.append(group)
            continue

        filtered_hooks = [
            hook for hook in group["hooks"]
            if not is_claude_notifier_hook(hook)
        ]
        if filtered_hooks:
            next_group = dict(group)
            next_group["hooks"] = filtered_hooks
            merged_groups.append(next_group)

    merged_groups.append({
        "matcher": "",
        "hooks": [
            {
                "type": "command",
                "command": command,
                "timeout": 10
            }
        ]
    })
    hooks_root[event_name] = merged_groups


merge_event("Stop", done_command)
merge_event("Notification", notification_command)

print(json.dumps(data, indent=2, ensure_ascii=False))
PY
mv "$tmp_settings" "$claude_settings_json"
log "Merged Claude Code notifier hooks into $claude_settings_json"

cat <<EOF

[codex-wsl-toast-notifier] Done.

Next steps for Codex:
  1. Restart Codex.
  2. Run /hooks inside Codex.
  3. Approve the Stop and PermissionRequest hook commands.

Next steps for Claude Code:
  1. Restart Claude Code.
  2. Review hooks in Claude Code if prompted.
  3. Confirm Stop and Notification hooks are enabled in $claude_settings_json.

Optional smoke tests:
  bash scripts/test-wsl-notification.sh codex
  bash scripts/test-wsl-notification.sh claude
  bash scripts/test-wsl-notification.sh all

EOF
