param(
    [string]$Title = "Codex",
    [string]$Message = "Task completed",
    [string]$Subtitle = "",
    [string]$SessionName = "",
    [ValidateSet("done", "permission", "info")]
    [string]$Kind = "done",
    [ValidateSet("on", "off")]
    [string]$Sound = "on"
)

$ErrorActionPreference = "SilentlyContinue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $scriptDir "codex_done.log"

function Write-CodexNotifyLog([string]$messageText) {
    try {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -LiteralPath $logFile -Value ("{0} worker: {1}" -f $stamp, $messageText) -Encoding UTF8
    } catch {}
}

function Play-CodexSingleSound {
    $played = $false
    try {
        $mediaDir = Join-Path $env:WINDIR "Media"
        $customSoundFromEnv = [string]$env:CODEX_NOTIFY_SOUND
        $customSoundNextToScript = Join-Path $scriptDir "codex_notify.wav"
        $soundCandidates = @(
            $customSoundFromEnv,
            $customSoundNextToScript,
            (Join-Path $mediaDir "Windows Notify Messaging.wav"),
            (Join-Path $mediaDir "Windows Notify System Generic.wav"),
            (Join-Path $mediaDir "Windows Notify.wav"),
            (Join-Path $mediaDir "notify.wav"),
            (Join-Path $mediaDir "Windows Ding.wav"),
            (Join-Path $mediaDir "ding.wav")
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

        foreach ($soundFile in $soundCandidates) {
            if (Test-Path -LiteralPath $soundFile) {
                $player = New-Object System.Media.SoundPlayer($soundFile)
                $player.Load()
                $player.PlaySync()
                try { $player.Dispose() } catch {}
                Write-CodexNotifyLog ("SoundPlayer.PlaySync: " + $soundFile)
                $played = $true
                break
            }
        }
    } catch {
        Write-CodexNotifyLog ("SoundPlayer failed: " + $_.Exception.Message)
    }

    if (-not $played) {
        try {
            [System.Media.SystemSounds]::Exclamation.Play()
            Start-Sleep -Milliseconds 600
            Write-CodexNotifyLog "SystemSounds fallback attempted"
        } catch {
            Write-CodexNotifyLog ("SystemSounds fallback failed: " + $_.Exception.Message)
        }
    }
}

function Invoke-CodexSoundOnce {
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, "Global\CodexNotifySoundMutex")
        $entered = $mutex.WaitOne(150)
        if (-not $entered) {
            Write-CodexNotifyLog "sound skipped: mutex busy"
            return
        }

        $stampFile = Join-Path $scriptDir "codex_last_sound.txt"
        $now = [DateTime]::UtcNow
        $minGapMs = 1400
        $shouldPlay = $true
        try {
            if (Test-Path -LiteralPath $stampFile) {
                $rawStamp = (Get-Content -LiteralPath $stampFile -Raw).Trim()
                if ($rawStamp) {
                    $last = [DateTime]::FromBinary([Int64]$rawStamp)
                    if (($now - $last).TotalMilliseconds -lt $minGapMs) {
                        $shouldPlay = $false
                    }
                }
            }
        } catch {
            $shouldPlay = $true
        }

        if ($shouldPlay) {
            Set-Content -LiteralPath $stampFile -Value ([string]$now.ToBinary()) -Encoding ASCII
            Play-CodexSingleSound
        } else {
            Write-CodexNotifyLog "sound skipped: throttled"
        }
    } catch {
        Write-CodexNotifyLog ("sound throttle failed: " + $_.Exception.Message)
        Play-CodexSingleSound
    } finally {
        try { if ($entered -and $mutex) { $mutex.ReleaseMutex() | Out-Null } } catch {}
        try { if ($mutex) { $mutex.Dispose() } } catch {}
    }
}

function Get-CodexToastLines {
    $lines = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($Message)) {
        if ($Kind -eq "permission") {
            $lines.Add("Codex is waiting for permission.")
        } else {
            $lines.Add("Codex task completed.")
        }
    } else {
        $lines.Add($Message)
    }

    if (-not [string]::IsNullOrWhiteSpace($SessionName)) {
        $lines.Add("Session: " + $SessionName)
    }

    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        $lines.Add($Subtitle)
    }

    return $lines
}

function Escape-XmlText([string]$value) {
    if ($null -eq $value) { return "" }
    return [System.Security.SecurityElement]::Escape($value)
}

function Show-CodexWindowsToast {
    $lines = Get-CodexToastLines
    $line1 = if ($lines.Count -gt 0) { [string]$lines[0] } else { "" }
    $line2 = if ($lines.Count -gt 1) { [string]$lines[1] } else { "" }
    $line3 = if ($lines.Count -gt 2) { [string]$lines[2] } else { "" }

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $duration = "short"
    if ($Kind -eq "permission") {
        $duration = "long"
    }

    $xmlText = @"
<toast duration="$duration">
  <visual>
    <binding template="ToastGeneric">
      <text>$(Escape-XmlText $Title)</text>
      <text>$(Escape-XmlText $line1)</text>
      <text>$(Escape-XmlText $line2)</text>
      <text>$(Escape-XmlText $line3)</text>
    </binding>
  </visual>
</toast>
"@

    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($xmlText)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    $toast.Tag = "codex-task-notifier"
    $toast.Group = $Kind

    $appIds = @(
        "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App",
        "Microsoft.Windows.PowerShell",
        "Windows PowerShell",
        "PowerShell",
        "Codex"
    )

    $lastError = $null
    foreach ($appId in $appIds) {
        try {
            $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
            $notifier.Show($toast)
            Write-CodexNotifyLog ("windows toast shown kind={0} appId={1}" -f $Kind, $appId)
            return $true
        } catch {
            $lastError = $_.Exception.Message
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($lastError)) {
        Write-CodexNotifyLog ("windows toast failed: " + $lastError)
    } else {
        Write-CodexNotifyLog "windows toast failed"
    }
    return $false
}

function Show-CodexTrayBalloon {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $lines = Get-CodexToastLines
        $body = ($lines.ToArray() -join [Environment]::NewLine)
        $icon = [System.Windows.Forms.ToolTipIcon]::Info
        if ($Kind -eq "permission") {
            $icon = [System.Windows.Forms.ToolTipIcon]::Warning
        }

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
        if ($Kind -eq "permission") {
            $notifyIcon.Icon = [System.Drawing.SystemIcons]::Warning
        }
        $notifyIcon.Visible = $true
        $notifyIcon.ShowBalloonTip(5000, $Title, $body, $icon)
        Start-Sleep -Milliseconds 5500
        $notifyIcon.Visible = $false
        try { $notifyIcon.Dispose() } catch {}
        Write-CodexNotifyLog ("tray balloon shown kind={0}" -f $Kind)
        return $true
    } catch {
        Write-CodexNotifyLog ("tray balloon failed: " + $_.Exception.Message)
        return $false
    }
}

Write-CodexNotifyLog ("started kind={0} sound={1}" -f $Kind, $Sound)
Start-Sleep -Milliseconds 120

if ($Sound -eq "on") {
    Invoke-CodexSoundOnce
}

$shown = Show-CodexWindowsToast
if (-not $shown) {
    Show-CodexTrayBalloon | Out-Null
}

Write-CodexNotifyLog "finished"
