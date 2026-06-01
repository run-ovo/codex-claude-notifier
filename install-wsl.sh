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
hooks_dir="$codex_home/hooks"
hooks_json="$codex_home/hooks.json"
config_toml="$codex_home/config.toml"

command -v powershell.exe >/dev/null 2>&1 || fail "powershell.exe not found. Run this inside WSL on Windows."
command -v wslpath >/dev/null 2>&1 || fail "wslpath not found. Run this inside WSL."
command -v python3 >/dev/null 2>&1 || fail "python3 not found."

for required in \
  "$script_dir/hooks/codex_done.ps1" \
  "$script_dir/hooks/codex_permission_notify.ps1" \
  "$script_dir/hooks/codex_notify_worker.ps1"; do
  [[ -f "$required" ]] || fail "required file not found: $required"
done

mkdir -p "$hooks_dir"
cp "$script_dir/hooks/codex_done.ps1" "$hooks_dir/codex_done.ps1"
cp "$script_dir/hooks/codex_permission_notify.ps1" "$hooks_dir/codex_permission_notify.ps1"
cp "$script_dir/hooks/codex_notify_worker.ps1" "$hooks_dir/codex_notify_worker.ps1"
log "Installed hook scripts to $hooks_dir"

make_encoded_command() {
  local windows_script_path="$1"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
    "\$code = \"& '$windows_script_path'\"; [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(\$code))" |
    tr -d '\r\n'
}

done_script_win="$(wslpath -w "$hooks_dir/codex_done.ps1")"
permission_script_win="$(wslpath -w "$hooks_dir/codex_permission_notify.ps1")"
done_encoded="$(make_encoded_command "$done_script_win")"
permission_encoded="$(make_encoded_command "$permission_script_win")"
done_command="powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $done_encoded"
permission_command="powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $permission_encoded"

timestamp="$(date +%Y%m%d_%H%M%S)"
if [[ -f "$hooks_json" ]]; then
  cp "$hooks_json" "$hooks_json.bak_$timestamp"
  log "Backed up hooks.json to $hooks_json.bak_$timestamp"
fi

tmp_hooks="$(mktemp)"
python3 - "$hooks_json" "$done_command" "$permission_command" > "$tmp_hooks" <<'PY'
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
mv "$tmp_hooks" "$hooks_json"
log "Merged notifier hooks into $hooks_json"

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

ensure_hooks_feature "$config_toml"

cat <<EOF

[codex-wsl-toast-notifier] Done.

Next steps:
  1. Restart Codex.
  2. Run /hooks inside Codex.
  3. Approve the Stop and PermissionRequest hook commands.
  4. Optional smoke test:
     bash scripts/test-wsl-notification.sh

EOF
