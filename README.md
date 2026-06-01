# Codex / Claude Code Windows Toast Notifier

这是一个面向 **Windows 原生** 和 **WSL** 中运行的 Codex CLI / Claude Code 的系统通知 hook。

它会在以下场景触发 Windows 右下角系统通知：

- Codex 任务/回合结束：`Stop`
- Codex 等待人工授权：`PermissionRequest`
- Claude Code 任务/回合结束：`Stop`
- Claude Code 等待用户处理或发出通知：`Notification`

通知显示使用 Windows Toast；如果当前系统 Toast 通道不可用，会降级为 Windows 托盘气泡通知。

## 支持场景

| 运行环境 | Codex | Claude Code | 安装入口 |
| --- | --- | --- | --- |
| Windows 原生 | 支持 | 支持 | `install-windows.ps1` |
| WSL | 支持 | 支持 | `install-wsl.sh` |

要求：

- Windows 桌面环境可用。
- 使用的 CLI 版本支持 hooks 功能。
- WSL 安装需要 WSL 中可以调用 `powershell.exe`。

不建议直接复制某台机器上的 hooks 配置，因为里面会包含本机绝对路径。请使用本项目的安装脚本在每台电脑上本地生成配置。

## 快速安装

### Windows 原生

在 PowerShell 里执行：

```powershell
git clone https://github.com/<your-name>/codex-wsl-toast-notifier.git
cd codex-wsl-toast-notifier
powershell.exe -ExecutionPolicy Bypass -File .\install-windows.ps1
```

只安装其中一种：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install-windows.ps1 -CodexOnly
powershell.exe -ExecutionPolicy Bypass -File .\install-windows.ps1 -ClaudeOnly
```

### WSL

在 WSL 里执行：

```bash
git clone https://github.com/<your-name>/codex-wsl-toast-notifier.git
cd codex-wsl-toast-notifier
bash install-wsl.sh
```

安装完成后：

1. 重启 Codex 和/或 Claude Code。
2. Codex 用户在 Codex 里运行 `/hooks`，批准 `Stop` 和 `PermissionRequest` 两个 hook。
3. Claude Code 用户确认 settings 中已写入 `Stop` 和 `Notification` hooks；如 Claude Code 提示信任或批准 hook，请按需确认。

## 自定义 Home 目录

### Windows 原生

默认安装到：

```text
%USERPROFILE%\.codex
%USERPROFILE%\.claude
```

可以指定：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install-windows.ps1 -CodexHome "D:\tools\.codex" -ClaudeHome "D:\tools\.claude"
```

也可以使用环境变量：

```powershell
$env:CODEX_HOME = "D:\tools\.codex"
$env:CLAUDE_HOME = "D:\tools\.claude"
powershell.exe -ExecutionPolicy Bypass -File .\install-windows.ps1
```

### WSL

默认安装到：

```text
~/.codex
~/.claude
```

可以指定：

```bash
CODEX_HOME=/path/to/.codex bash install-wsl.sh
CLAUDE_HOME=/path/to/.claude bash install-wsl.sh
CODEX_HOME=/path/to/.codex CLAUDE_HOME=/path/to/.claude bash install-wsl.sh
```

## 脚本会写入什么

### Codex

```text
$CODEX_HOME/hooks/codex_done.ps1
$CODEX_HOME/hooks/codex_permission_notify.ps1
$CODEX_HOME/hooks/codex_notify_worker.ps1
$CODEX_HOME/hooks.json
$CODEX_HOME/config.toml
```

Windows 原生默认 `$CODEX_HOME = %USERPROFILE%\.codex`；WSL 默认 `$CODEX_HOME = ~/.codex`。

### Claude Code

```text
$CLAUDE_HOME/hooks/claude_done.ps1
$CLAUDE_HOME/hooks/claude_notification_notify.ps1
$CLAUDE_HOME/hooks/codex_notify_worker.ps1
$CLAUDE_HOME/settings.json
```

Windows 原生默认 `$CLAUDE_HOME = %USERPROFILE%\.claude`；WSL 默认 `$CLAUDE_HOME = ~/.claude`。

## 安装脚本做了什么

`install-windows.ps1` 会执行以下操作：

1. 复制 PowerShell hook 脚本到 Codex / Claude Code hooks 目录。
2. 生成 PowerShell `-EncodedCommand`，避免 Windows 路径空格和转义问题。
3. 合并 Codex `hooks.json`，注册：
   - `Stop`
   - `PermissionRequest`
4. 确保 Codex `config.toml` 包含：

```toml
[features]
hooks = true
```

5. 合并 Claude Code `settings.json`，注册：
   - `Stop`
   - `Notification`

`install-wsl.sh` 额外会检查 `powershell.exe`、`wslpath`、`python3`，并用 `wslpath -w` 生成 Windows 可访问路径。

如果已有 `hooks.json`、`config.toml` 或 `settings.json`，安装脚本会先生成 `.bak_时间戳` 备份。

## 测试

### Windows 原生

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\test-windows-notification.ps1
```

只测试其中一种：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\test-windows-notification.ps1 -CodexOnly
powershell.exe -ExecutionPolicy Bypass -File .\scripts\test-windows-notification.ps1 -ClaudeOnly
```

### WSL

```bash
bash scripts/test-wsl-notification.sh all
```

只测试其中一种：

```bash
bash scripts/test-wsl-notification.sh codex
bash scripts/test-wsl-notification.sh claude
```

你应该能看到对应的 Windows 系统通知：

- 任务完成通知
- 授权/等待用户处理通知

日志位置：

```text
$CODEX_HOME/hooks/codex_done.log
$CLAUDE_HOME/hooks/claude_code.log
```

## 常见问题

### 没有看到通知

检查：

1. 已经重启 Codex 或 Claude Code。
2. Codex 已经在 `/hooks` 中批准两个 hook。
3. Claude Code 的 settings 中存在 `hooks.Stop` 和 `hooks.Notification`。
4. Windows 通知没有被系统设置禁用。
5. WSL 安装时，确认 `powershell.exe` 可以在 WSL 中调用。
6. 查看 `$CODEX_HOME/hooks/codex_done.log` 或 `$CLAUDE_HOME/hooks/claude_code.log`。

### Windows 提示脚本执行策略限制

使用文档里的命令运行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install-windows.ps1
```

这只对当前命令绕过执行策略，不会永久修改系统策略。

### Codex 授权通知不出现

如果 Codex 配置是：

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

那 Codex 通常不会触发人工授权请求，因此 `PermissionRequest` 通知可能很少出现。任务结束通知仍然会触发。

### Claude Code 通知太多

Claude Code 的 `Notification` 事件可能不只表示权限请求。当前实现会尽量不漏报：匹配权限/等待关键词时显示为授权等待通知，不匹配时显示为普通 Claude Code 通知。可以根据 `$CLAUDE_HOME/hooks/claude_code.log` 中的真实 payload 后续收紧过滤规则。

### 重复安装会不会重复注册 hook

安装脚本会合并配置，并移除旧的同类通知 hook 后再写入当前版本，正常重复安装不会堆积重复项，也不会删除用户其它无关 hooks。

### 能不能把生成的配置复制到另一台机器

不建议。生成的 hook command 里包含本机绝对路径；换机器、换用户目录、从 WSL 切到 Windows 原生后都应该重新运行安装脚本。
