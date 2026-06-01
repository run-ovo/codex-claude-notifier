param(
    [string]$CodexHome = "",
    [string]$ClaudeHome = "",
    [switch]$CodexOnly,
    [switch]$ClaudeOnly
)

$ErrorActionPreference = "Stop"

function Write-Log([string]$Message) {
    Write-Host "[codex-wsl-toast-notifier] $Message"
}

function Fail([string]$Message) {
    Write-Error "[codex-wsl-toast-notifier] ERROR: $Message"
    exit 1
}

function Get-DefaultHome([string]$EnvName, [string]$DirectoryName) {
    $envValue = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return $envValue
    }
    return Join-Path $HOME $DirectoryName
}

function Invoke-HookWithPayload([string]$ScriptPath, [object]$Payload) {
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Fail "hook script not found: $ScriptPath"
    }

    $json = $Payload | ConvertTo-Json -Depth 10 -Compress
    $json | powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
}

if ($CodexOnly -and $ClaudeOnly) {
    Fail "-CodexOnly and -ClaudeOnly cannot be used together."
}

$testCodex = -not $ClaudeOnly
$testClaude = -not $CodexOnly

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = Get-DefaultHome "CODEX_HOME" ".codex"
}
if ([string]::IsNullOrWhiteSpace($ClaudeHome)) {
    $ClaudeHome = Get-DefaultHome "CLAUDE_HOME" ".claude"
}

$cwd = (Get-Location).Path

if ($testCodex) {
    $codexHooksDir = Join-Path $CodexHome "hooks"
    $doneScript = Join-Path $codexHooksDir "codex_done.ps1"
    $permissionScript = Join-Path $codexHooksDir "codex_permission_notify.ps1"

    $donePayload = [pscustomobject]@{
        hook_event_name = "Stop"
        cwd = $cwd
        session_id = "test-session-12345678"
        last_assistant_message = "Smoke test completed."
    }
    $permissionPayload = [pscustomobject]@{
        hook_event_name = "PermissionRequest"
        cwd = $cwd
        session_id = "test-session-12345678"
        tool_name = "shell"
        tool_input = [pscustomobject]@{
            command = "echo test"
        }
    }

    Write-Log "Invoking Codex Stop hook"
    Invoke-HookWithPayload $doneScript $donePayload
    Write-Host ""

    Write-Log "Invoking Codex PermissionRequest hook"
    Invoke-HookWithPayload $permissionScript $permissionPayload
    Write-Host ""

    Write-Log "Codex test payloads sent. Check Windows notifications and $(Join-Path $codexHooksDir 'codex_done.log')"
}

if ($testClaude) {
    $claudeHooksDir = Join-Path $ClaudeHome "hooks"
    $doneScript = Join-Path $claudeHooksDir "claude_done.ps1"
    $notificationScript = Join-Path $claudeHooksDir "claude_notification_notify.ps1"

    $donePayload = [pscustomobject]@{
        hook_event_name = "Stop"
        cwd = $cwd
        session_id = "claude-test-session-12345678"
        transcript_path = Join-Path $env:TEMP "claude-test-transcript.jsonl"
        stop_hook_active = $false
    }
    $notificationPayload = [pscustomobject]@{
        hook_event_name = "Notification"
        cwd = $cwd
        session_id = "claude-test-session-12345678"
        message = "Claude Code needs your permission to continue."
    }

    Write-Log "Invoking Claude Code Stop hook"
    Invoke-HookWithPayload $doneScript $donePayload
    Write-Host ""

    Write-Log "Invoking Claude Code Notification hook"
    Invoke-HookWithPayload $notificationScript $notificationPayload
    Write-Host ""

    Write-Log "Claude Code test payloads sent. Check Windows notifications and $(Join-Path $claudeHooksDir 'claude_code.log')"
}
