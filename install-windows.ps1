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

function Quote-PSArg([string]$Value) {
    if ($null -eq $Value) { $Value = "" }
    return "'" + ($Value -replace "'", "''") + "'"
}

function New-EncodedHookCommand([string]$ScriptPath) {
    $command = "& " + (Quote-PSArg (Resolve-Path -LiteralPath $ScriptPath).Path)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

function Backup-File([string]$Path, [string]$Timestamp) {
    if (Test-Path -LiteralPath $Path) {
        $backupPath = "$Path.bak_$Timestamp"
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
        Write-Log "Backed up $Path to $backupPath"
    }
}

function Read-JsonObject([string]$Path) {
    if ((Test-Path -LiteralPath $Path) -and -not [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $Path -Raw))) {
        $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } else {
        $data = [pscustomobject]@{}
    }

    if ($null -eq $data -or $data -isnot [pscustomobject]) {
        $data = [pscustomobject]@{}
    }
    return $data
}

function Ensure-ObjectProperty([pscustomobject]$Object, [string]$Name) {
    if (-not ($Object.PSObject.Properties.Name -contains $Name) -or $null -eq $Object.$Name -or $Object.$Name -isnot [pscustomobject]) {
        if ($Object.PSObject.Properties.Name -contains $Name) {
            $Object.PSObject.Properties.Remove($Name)
        }
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue ([pscustomobject]@{})
    }
    return $Object.$Name
}

function Decode-EncodedCommand([string]$Command) {
    $match = [regex]::Match($Command, '(?i)-EncodedCommand\s+"?([A-Za-z0-9+/=]+)"?')
    if (-not $match.Success) { return "" }
    try {
        return [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($match.Groups[1].Value))
    } catch {
        return ""
    }
}

function Test-NotifierHook([object]$Hook, [string[]]$Markers) {
    if ($null -eq $Hook -or -not ($Hook.PSObject.Properties.Name -contains "command")) {
        return $false
    }

    $command = [string]$Hook.command
    $combined = $command + "`n" + (Decode-EncodedCommand $command)
    foreach ($marker in $Markers) {
        if ($combined.Contains($marker)) { return $true }
    }
    return $false
}

function Set-HookEvent([pscustomobject]$HooksRoot, [string]$EventName, [string]$Command, [string[]]$Markers, [bool]$IncludeMatcher) {
    $existingGroups = @()
    if ($HooksRoot.PSObject.Properties.Name -contains $EventName -and $HooksRoot.$EventName -is [System.Collections.IEnumerable] -and $HooksRoot.$EventName -isnot [string]) {
        $existingGroups = @($HooksRoot.$EventName)
    }

    $mergedGroups = New-Object System.Collections.ArrayList
    foreach ($group in $existingGroups) {
        if ($null -eq $group -or -not ($group.PSObject.Properties.Name -contains "hooks") -or $group.hooks -isnot [System.Collections.IEnumerable] -or $group.hooks -is [string]) {
            [void]$mergedGroups.Add($group)
            continue
        }

        $filteredHooks = @()
        foreach ($hook in @($group.hooks)) {
            if (-not (Test-NotifierHook $hook $Markers)) {
                $filteredHooks += $hook
            }
        }

        if ($filteredHooks.Count -gt 0) {
            $nextGroup = [pscustomobject]@{}
            foreach ($property in $group.PSObject.Properties) {
                if ($property.Name -ne "hooks") {
                    $nextGroup | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
                }
            }
            $nextGroup | Add-Member -NotePropertyName "hooks" -NotePropertyValue @($filteredHooks)
            [void]$mergedGroups.Add($nextGroup)
        }
    }

    $hookEntry = [pscustomobject]@{
        type = "command"
        command = $Command
        timeout = 10
    }

    if ($IncludeMatcher) {
        $newGroup = [pscustomobject]@{
            matcher = ""
            hooks = @($hookEntry)
        }
    } else {
        $newGroup = [pscustomobject]@{
            hooks = @($hookEntry)
        }
    }
    [void]$mergedGroups.Add($newGroup)

    if ($HooksRoot.PSObject.Properties.Name -contains $EventName) {
        $HooksRoot.PSObject.Properties.Remove($EventName)
    }
    $HooksRoot | Add-Member -NotePropertyName $EventName -NotePropertyValue @($mergedGroups)
}

function Save-TextUtf8([string]$Path, [string]$Value) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $encoding)
}

function Save-Json([object]$Data, [string]$Path) {
    $json = $Data | ConvertTo-Json -Depth 30
    Save-TextUtf8 $Path ($json + "`n")
}

function Merge-CodexHooks([string]$HooksJsonPath, [string]$DoneCommand, [string]$PermissionCommand, [string]$Timestamp) {
    Backup-File $HooksJsonPath $Timestamp
    $data = Read-JsonObject $HooksJsonPath
    $hooksRoot = Ensure-ObjectProperty $data "hooks"
    $markers = @("codex_done.ps1", "codex_permission_notify.ps1", "codex-task-notifier", "codex-wsl-toast-notifier")
    Set-HookEvent $hooksRoot "Stop" $DoneCommand $markers $false
    Set-HookEvent $hooksRoot "PermissionRequest" $PermissionCommand $markers $false
    Save-Json $data $HooksJsonPath
    Write-Log "Merged Codex notifier hooks into $HooksJsonPath"
}

function Merge-ClaudeSettings([string]$SettingsJsonPath, [string]$DoneCommand, [string]$NotificationCommand, [string]$Timestamp) {
    Backup-File $SettingsJsonPath $Timestamp
    $data = Read-JsonObject $SettingsJsonPath
    $hooksRoot = Ensure-ObjectProperty $data "hooks"
    $markers = @("claude_done.ps1", "claude_notification_notify.ps1", "claude-code-wsl-toast-notifier")
    Set-HookEvent $hooksRoot "Stop" $DoneCommand $markers $true
    Set-HookEvent $hooksRoot "Notification" $NotificationCommand $markers $true
    Save-Json $data $SettingsJsonPath
    Write-Log "Merged Claude Code notifier hooks into $SettingsJsonPath"
}

function Ensure-CodexHooksFeature([string]$ConfigPath, [string]$Timestamp) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Save-TextUtf8 $ConfigPath "[features]`nhooks = true`n"
        Write-Log "Created config.toml with [features].hooks = true"
        return
    }

    Backup-File $ConfigPath $Timestamp
    $text = Get-Content -LiteralPath $ConfigPath -Raw
    $lines = @($text -split "\r?\n", -1)
    if ($lines.Count -gt 0 -and $lines[-1] -eq "") {
        $lines = $lines[0..($lines.Count - 2)]
    }

    $featuresIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[features\]\s*$') {
            $featuresIndex = $i
            break
        }
    }

    if ($featuresIndex -lt 0) {
        $output = $text.TrimEnd() + "`n`n[features]`nhooks = true`n"
    } else {
        $nextTable = $lines.Count
        for ($i = $featuresIndex + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[') {
                $nextTable = $i
                break
            }
        }

        $hooksIndex = -1
        for ($i = $featuresIndex + 1; $i -lt $nextTable; $i++) {
            if ($lines[$i] -match '^\s*hooks\s*=') {
                $hooksIndex = $i
                break
            }
        }

        if ($hooksIndex -lt 0) {
            $before = @()
            $after = @()
            if ($featuresIndex -ge 0) { $before = $lines[0..$featuresIndex] }
            if ($featuresIndex + 1 -lt $lines.Count) { $after = $lines[($featuresIndex + 1)..($lines.Count - 1)] }
            $lines = @($before) + @("hooks = true") + @($after)
        } else {
            $lines[$hooksIndex] = "hooks = true"
        }
        $output = ($lines -join "`n") + "`n"
    }

    Save-TextUtf8 $ConfigPath $output
    Write-Log "Ensured [features].hooks = true in $ConfigPath"
}

if ($CodexOnly -and $ClaudeOnly) {
    Fail "-CodexOnly and -ClaudeOnly cannot be used together."
}

$installCodex = -not $ClaudeOnly
$installClaude = -not $CodexOnly

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = Get-DefaultHome "CODEX_HOME" ".codex"
}
if ([string]::IsNullOrWhiteSpace($ClaudeHome)) {
    $ClaudeHome = Get-DefaultHome "CLAUDE_HOME" ".claude"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hooksSourceDir = Join-Path $scriptDir "hooks"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$requiredFiles = @("codex_notify_worker.ps1")
if ($installCodex) {
    $requiredFiles += @("codex_done.ps1", "codex_permission_notify.ps1")
}
if ($installClaude) {
    $requiredFiles += @("claude_done.ps1", "claude_notification_notify.ps1")
}

foreach ($fileName in $requiredFiles) {
    $path = Join-Path $hooksSourceDir $fileName
    if (-not (Test-Path -LiteralPath $path)) {
        Fail "required file not found: $path"
    }
}

if ($installCodex) {
    $codexHooksDir = Join-Path $CodexHome "hooks"
    $codexHooksJson = Join-Path $CodexHome "hooks.json"
    $codexConfigToml = Join-Path $CodexHome "config.toml"
    New-Item -ItemType Directory -Path $codexHooksDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $hooksSourceDir "codex_done.ps1") -Destination (Join-Path $codexHooksDir "codex_done.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $hooksSourceDir "codex_permission_notify.ps1") -Destination (Join-Path $codexHooksDir "codex_permission_notify.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $hooksSourceDir "codex_notify_worker.ps1") -Destination (Join-Path $codexHooksDir "codex_notify_worker.ps1") -Force
    Write-Log "Installed Codex hook scripts to $codexHooksDir"

    $doneCommand = New-EncodedHookCommand (Join-Path $codexHooksDir "codex_done.ps1")
    $permissionCommand = New-EncodedHookCommand (Join-Path $codexHooksDir "codex_permission_notify.ps1")
    Merge-CodexHooks $codexHooksJson $doneCommand $permissionCommand $timestamp
    Ensure-CodexHooksFeature $codexConfigToml $timestamp
}

if ($installClaude) {
    $claudeHooksDir = Join-Path $ClaudeHome "hooks"
    $claudeSettingsJson = Join-Path $ClaudeHome "settings.json"
    New-Item -ItemType Directory -Path $claudeHooksDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $hooksSourceDir "claude_done.ps1") -Destination (Join-Path $claudeHooksDir "claude_done.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $hooksSourceDir "claude_notification_notify.ps1") -Destination (Join-Path $claudeHooksDir "claude_notification_notify.ps1") -Force
    Copy-Item -LiteralPath (Join-Path $hooksSourceDir "codex_notify_worker.ps1") -Destination (Join-Path $claudeHooksDir "codex_notify_worker.ps1") -Force
    Write-Log "Installed Claude Code hook scripts to $claudeHooksDir"

    $doneCommand = New-EncodedHookCommand (Join-Path $claudeHooksDir "claude_done.ps1")
    $notificationCommand = New-EncodedHookCommand (Join-Path $claudeHooksDir "claude_notification_notify.ps1")
    Merge-ClaudeSettings $claudeSettingsJson $doneCommand $notificationCommand $timestamp
}

Write-Host ""
Write-Log "Done."
Write-Host ""
if ($installCodex) {
    Write-Host "Next steps for Codex:"
    Write-Host "  1. Restart Codex."
    Write-Host "  2. Run /hooks inside Codex."
    Write-Host "  3. Approve the Stop and PermissionRequest hook commands."
    Write-Host ""
}
if ($installClaude) {
    Write-Host "Next steps for Claude Code:"
    Write-Host "  1. Restart Claude Code."
    Write-Host "  2. Review hooks in Claude Code if prompted."
    Write-Host "  3. Confirm Stop and Notification hooks are enabled."
    Write-Host ""
}
Write-Host "Optional smoke test:"
Write-Host "  powershell.exe -ExecutionPolicy Bypass -File .\scripts\test-windows-notification.ps1"
