param()

$ErrorActionPreference = "SilentlyContinue"

$raw = [Console]::In.ReadToEnd()
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $scriptDir "codex_done.log"
$workerFile = Join-Path $scriptDir "codex_notify_worker.ps1"

function Write-CodexHookLog([string]$messageText) {
    try {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -LiteralPath $logFile -Value ("{0} {1}" -f $stamp, $messageText) -Encoding UTF8
    } catch {}
}

function Quote-PSArg([string]$value) {
    if ($null -eq $value) { $value = "" }
    return "'" + ($value -replace "'", "''") + "'"
}

function Get-CodexSessionName($payload) {
    try {
        if ($null -ne $payload) {
            foreach ($field in @("session_name", "session_title", "thread_title", "conversation_title", "title", "name")) {
                if ($payload.PSObject.Properties.Name -contains $field) {
                    $value = [string]$payload.$field
                    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
                }
            }

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

$payload = $null
try {
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $payload = $raw | ConvertFrom-Json
    }
} catch {}

$sessionName = Get-CodexSessionName $payload

Write-CodexHookLog ("PermissionRequest hook fired; session={0}; stdinLength={1}" -f $sessionName, $raw.Length)

if (Test-Path -LiteralPath $workerFile) {
    try {
        $cmd = "& " + (Quote-PSArg $workerFile) +
            " -Kind 'permission' -Title 'Codex' -Message 'Permission required' -Subtitle 'Codex is waiting for your approval.' -SessionName " +
            (Quote-PSArg $sessionName) + " -Sound 'on'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-EncodedCommand",
            $encoded
        ) -WindowStyle Hidden
    } catch {
        Write-CodexHookLog ("PermissionRequest worker launch failed: " + $_.Exception.Message)
    }
}
