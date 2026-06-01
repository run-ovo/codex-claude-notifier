# Codex WSL Toast Notifier

这是一个面向 **WSL 中运行的 Codex CLI** 的 Windows 系统通知 hook。

它会在以下场景触发 Windows 右下角系统通知：

- Codex 任务/回合结束：`Stop`
- Codex 等待人工授权：`PermissionRequest`

通知显示使用 Windows Toast；如果当前系统 Toast 通道不可用，会降级为 Windows 托盘气泡通知。

## 适用场景

- Codex CLI 运行在 WSL 里。
- Windows 桌面环境可用。
- WSL 中可以调用 `powershell.exe`。
- Codex 版本支持 hooks 功能。

不建议直接复制某台机器上的 `hooks.json`，因为里面会包含本机 WSL 路径。请使用本项目的安装脚本在每台电脑上本地生成配置。

## 快速安装

在 WSL 里执行：

```bash
git clone https://github.com/<your-name>/codex-wsl-toast-notifier.git
cd codex-wsl-toast-notifier
bash install-wsl.sh
```

安装完成后：

1. 重启 Codex。
2. 在 Codex 里运行 `/hooks`。
3. 批准 `Stop` 和 `PermissionRequest` 两个 hook。

## 本地目录安装

如果你已经把项目放在本地目录，例如：

```text
/mnt/d/yz/codex-wsl-toast-notifier
```

则执行：

```bash
cd /mnt/d/yz/codex-wsl-toast-notifier
bash install-wsl.sh
```

## 自定义 Codex Home

默认安装到：

```text
~/.codex
```

如果你的 Codex Home 不在默认位置，可以指定：

```bash
CODEX_HOME=/path/to/.codex bash install-wsl.sh
```

脚本会写入：

```text
$CODEX_HOME/hooks/codex_done.ps1
$CODEX_HOME/hooks/codex_permission_notify.ps1
$CODEX_HOME/hooks/codex_notify_worker.ps1
$CODEX_HOME/hooks.json
$CODEX_HOME/config.toml
```

## 安装脚本做了什么

`install-wsl.sh` 会执行以下操作：

1. 检查 `powershell.exe`、`wslpath`、`python3`。
2. 复制三个 PowerShell hook 脚本到 `$CODEX_HOME/hooks`。
3. 使用 `wslpath -w` 生成当前 WSL 机器对应的 Windows 可访问路径。
4. 生成 PowerShell `-EncodedCommand`，避免路径转义问题。
5. 合并 `$CODEX_HOME/hooks.json`，注册：
   - `Stop`
   - `PermissionRequest`
6. 确保 `$CODEX_HOME/config.toml` 包含：

```toml
[features]
hooks = true
```

如果已有 `hooks.json` 或 `config.toml`，安装脚本会先生成 `.bak_时间戳` 备份。

## 测试

安装后在 WSL 里执行：

```bash
bash scripts/test-wsl-notification.sh
```

你应该能看到两条 Windows 系统通知：

- 任务完成通知
- 授权等待通知

日志位置：

```text
$CODEX_HOME/hooks/codex_done.log
```

## 常见问题

### 没有看到通知

检查：

1. 已经重启 Codex。
2. 已经在 `/hooks` 中批准两个 hook。
3. Windows 通知没有被系统设置禁用。
4. `powershell.exe` 可以在 WSL 中调用。
5. 查看 `$CODEX_HOME/hooks/codex_done.log`。

### 授权通知不出现

如果 Codex 配置是：

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

那 Codex 通常不会触发人工授权请求，因此 `PermissionRequest` 通知可能很少出现。任务结束通知仍然会触发。

### 重复安装会不会重复注册 hook

安装脚本会合并 `hooks.json`，并移除旧的同类通知 hook 后再写入当前版本，正常重复安装不会堆积重复项。
