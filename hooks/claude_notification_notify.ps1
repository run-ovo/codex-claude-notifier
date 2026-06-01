param()

$ErrorActionPreference = "SilentlyContinue"

$raw = [Console]::In.ReadToEnd()
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $scriptDir "claude_code.log"
$workerFile = Join-Path $scriptDir "codex_notify_worker.ps1"

function Write-ClaudeHookLog([string]$messageText) {
    try {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -LiteralPath $logFile -Value ("{0} {1}" -f $stamp, $messageText) -Encoding UTF8
    } catch {}
}

function Quote-PSArg([string]$value) {
    if ($null -eq $value) { $value = "" }
    return "'" + ($value -replace "'", "''") + "'"
}

function Get-ClaudePayloadValue($payload, [string[]]$fields) {
    try {
        if ($null -ne $payload) {
            foreach ($field in $fields) {
                if ($payload.PSObject.Properties.Name -contains $field) {
                    $value = [string]$payload.$field
                    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
                }
            }
        }
    } catch {}
    return ""
}

function Get-ClaudeSessionName($payload) {
    try {
        if ($null -ne $payload) {
            $name = Get-ClaudePayloadValue $payload @("session_name", "session_title", "thread_title", "conversation_title", "title", "name")
            if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }

            $cwdName = ""
            if ($payload.PSObject.Properties.Name -contains "cwd") {
                $cwd = [string]$payload.cwd
                if (-not [string]::IsNullOrWhiteSpace($cwd)) {
                    try { $cwdName = Split-Path -Leaf $cwd } catch {}
                }
            }

            $sidShort = ""
            if ($payload.PSObject.Properties.Name -contains "session_id") {
                $sid = [string]$payload.session_id
                if (-not [string]::IsNullOrWhiteSpace($sid)) {
                    $sidShort = $sid
                    if ($sidShort.Length -gt 8) { $sidShort = $sidShort.Substring(0, 8) }
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($cwdName) -and -not [string]::IsNullOrWhiteSpace($sidShort)) {
                return "$cwdName - $sidShort"
            }
            if (-not [string]::IsNullOrWhiteSpace($cwdName)) { return $cwdName }
            if (-not [string]::IsNullOrWhiteSpace($sidShort)) { return "session $sidShort" }
        }
    } catch {}

    try {
        $leaf = Split-Path -Leaf (Get-Location).Path
        if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf }
    } catch {}
    return "unknown"
}

function Get-TruncatedText([string]$value, [int]$maxLength) {
    if ($null -eq $value) { return "" }
    if ($value.Length -le $maxLength) { return $value }
    return $value.Substring(0, $maxLength) + "..."
}

function Test-ClaudeAttentionMessage([string]$messageText) {
    if ([string]::IsNullOrWhiteSpace($messageText)) { return $true }
    return $messageText -match "(?i)permission|approval|approve|allow|confirm|waiting|wait|requires|needs|input|continue|权限|批准|确认|允许|等待|输入"
}

$notify = $true
$payload = $null
try {
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $payload = $raw | ConvertFrom-Json
        if ($payload.PSObject.Properties.Name -contains "hook_event_name" -and $payload.hook_event_name -ne "Notification") {
            $notify = $false
        }
    }
} catch {
    $notify = $true
}

$sessionName = Get-ClaudeSessionName $payload
$eventName = Get-ClaudePayloadValue $payload @("hook_event_name")
$messageText = Get-ClaudePayloadValue $payload @("message", "notification_message", "text", "reason")
$matchedAttention = Test-ClaudeAttentionMessage $messageText
$kind = if ($matchedAttention) { "permission" } else { "info" }
$message = if ($matchedAttention) { "Permission required" } else { "Claude Code notification" }
$subtitle = if (-not [string]::IsNullOrWhiteSpace($messageText)) { $messageText } elseif ($matchedAttention) { "Claude Code is waiting for your approval." } else { "Claude Code needs your attention." }
$cwd = Get-ClaudePayloadValue $payload @("cwd")
$rawPreview = Get-TruncatedText $raw 4096

Write-ClaudeHookLog ("Notification hook fired; event={0}; notify={1}; matchedAttention={2}; session={3}; cwd={4}; message={5}; stdinLength={6}; payload={7}" -f $eventName, $notify, $matchedAttention, $sessionName, $cwd, $messageText, $raw.Length, $rawPreview)

if ($notify -and (Test-Path -LiteralPath $workerFile)) {
    try {
        $cmd = "& " + (Quote-PSArg $workerFile) +
            " -Kind " + (Quote-PSArg $kind) + " -Title 'Claude Code' -Message " + (Quote-PSArg $message) +
            " -Subtitle " + (Quote-PSArg $subtitle) + " -SessionName " + (Quote-PSArg $sessionName) +
            " -Sound 'on' -LogFileName 'claude_code.log' -ToastTag 'claude-code-wsl-toast-notifier' -SoundMutexName 'Global\ClaudeCodeNotifySoundMutex' -LastSoundFileName 'claude_last_sound.txt'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-EncodedCommand",
            $encoded
        ) -WindowStyle Hidden
    } catch {
        Write-ClaudeHookLog ("Notification worker launch failed: " + $_.Exception.Message)
    }
}

[Console]::Out.Write('{"continue":true,"suppressOutput":true}')
