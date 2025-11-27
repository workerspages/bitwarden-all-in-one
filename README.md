
# Vaultwarden Rclone Backup

![Docker Image Size (tag)](https://img.shields.io/docker/image-size/workerspages/vaultwarden-rclone/latest)
![Docker Pulls](https://img.shields.io/docker/pulls/workerspages/vaultwarden-rclone)

这是一个基于官方 [vaultwarden/server](https://github.com/dani-garcia/vaultwarden) 构建的 Docker 镜像，集成了 **Rclone** 和 **Supercronic**，实现了自动定时将密码库数据加密备份到任何 Rclone 支持的云存储（如 Google Drive, OneDrive, S3, MinIO, WebDAV 等）。

## ✨ 主要特性

*   🐳 **基于官方镜像**：紧跟 Vaultwarden 官方最新版本。
*   ☁️ **Rclone 集成**：支持几十种云存储后端，支持 `RCLONE_CONF_BASE64` 环境变量注入配置。
*   ⏰ **稳定定时任务**：使用 `supercronic` 替代 crond，不仅日志清晰，而且能完美处理 Docker 容器信号。
*   🔔 **Telegram 通知**：备份成功/失败会发送详细的 HTML 格式通知。
*   📦 **多种压缩格式**：支持 `gz`, `zst` (Zstandard), `bz2`, `xz`，默认启用 `gz`。
*   🔄 **一键还原**：内置 `restore.sh` 脚本，支持从云端拉取最新备份并自动覆盖（含本地安全回滚备份）。
*   🧹 **自动清理**：支持基于天数的旧备份轮替清理。

## 🚀 快速开始 (Docker Compose)

创建一个 `docker-compose.yml` 文件：

```yaml
version: '3.8'

services:
  vaultwarden:
    image: ghcr.io/workerspages/vaultwarden-rclone:latest
    container_name: vaultwarden
    restart: always
    environment:
      - TZ=Asia/Shanghai
      # --- Rclone 配置 ---
      - RCLONE_REMOTE=onedrive:/vaultwarden_backup  # 你的 Rclone 远程名称和路径
      - RCLONE_CONF_BASE64=eyJ...  # 你的 rclone.conf 文件的 Base64 编码字符串
      # --- 备份策略 ---
      - BACKUP_CRON=0 3 * * *      # 每天凌晨 3 点备份
      - BACKUP_RETAIN_DAYS=14      # 保留 14 天
      - BACKUP_COMPRESSION=zst     # 使用 zstd 高效压缩
      # --- 通知 (可选) ---
      - TELEGRAM_ENABLED=true
      - TELEGRAM_BOT_TOKEN=123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11
      - TELEGRAM_CHAT_ID=123456789
    volumes:
      - ./vw-data:/data

```

## ⚙️ 环境变量说明

| 变量名 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `TZ` | `Asia/Shanghai` | 时区设置 |
| `BACKUP_ENABLED` | `true` | 是否启用自动备份 |
| `BACKUP_CRON` | `0 3 * * *` | Crontab 表达式 (分 时 日 月 周) |
| `RCLONE_REMOTE` | **必填** | 远程存储路径，例如 `myremote:/backups/vw` |
| `RCLONE_CONF_BASE64` | `""` | `rclone.conf` 文件内容的 Base64 编码串 (推荐) |
| `BACKUP_FILENAME_PREFIX`| `vaultwarden` | 备份文件名前缀 |
| `BACKUP_COMPRESSION` | `gz` | 压缩格式: `gz`, `zst`, `bz2`, `xz` |
| `BACKUP_RETAIN_DAYS` | `14` | 云端保留备份的天数，0 为不清理 |
| `TELEGRAM_ENABLED` | `false` | 是否开启 TG 通知 |
| `TELEGRAM_BOT_TOKEN` | `""` | Telegram Bot Token |
| `TELEGRAM_CHAT_ID` | `""` | 接收通知的 Chat ID |

## 🛠️ 如何获取 Rclone 配置 (Base64)

为了避免挂载配置文件的麻烦，推荐使用环境变量注入配置：

1. 在本地机器上安装并配置好 Rclone (`rclone config`)。
2. 验证配置是否可用：`rclone lsd myremote:`。
3. 将配置文件转换为 Base64 字符串：

   **Linux/macOS:**
   ```bash
   cat ~/.config/rclone/rclone.conf | base64 | tr -d '\n'
   ```
   **Windows (PowerShell):**
   ```powershell
   [Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$env:USERPROFILE\.config\rclone\rclone.conf"))
   ```
4. 将生成的字符串填入 `RCLONE_CONF_BASE64`。

## 🔄 数据还原 (Restore)

容器内置了还原脚本，可以方便地从云端恢复数据。

**注意：还原操作会覆盖当前的 `/data` 目录，但脚本会自动在还原前将当前数据备份到 `/data.pre-restore-日期` 目录中。**

### 1. 恢复最新的备份
```bash
docker exec -it vaultwarden restore.sh latest
```

### 2. 恢复指定文件
如果不确定文件名，可以先进入容器查看：
```bash
docker exec -it vaultwarden rclone ls your-remote:
```
然后指定文件名恢复：
```bash
docker exec -it vaultwarden restore.sh vaultwarden-20231127-090000.tar.gz
```

## 🏗️ 构建说明

如果你想自己构建镜像：

```bash
docker build -t vaultwarden-rclone -f docker/Dockerfile .
```
```

---

### 2. 代码审查与优化建议

我对你提供的代码进行了一些微调建议，这可以让你的镜像更健壮：

#### A. 关于 `entrypoint.sh` 的优化建议
目前的 `entrypoint.sh` 在 `wait` 时如果任何一个进程退出，脚本就会继续执行。为了确保如果主程序（vaultwarden）挂了容器能自动重启，建议修改 `wait` 逻辑。

**当前代码：**
```bash
wait $SERVICE_PID $CRON_PID
```
**建议逻辑：** 如果 `vaultwarden` 死了，容器应该退出以便 Docker 重启它。如果 `supercronic` 死了，也应该引起注意。
```bash
# 简单的改进：等待任意进程退出，然后退出脚本
wait -n $SERVICE_PID $CRON_PID
# 退出并传递状态码，这会让 Docker 守护进程知道容器停止了
exit $?
```

#### B. 关于 `backup.sh` 的安全性
你在脚本中硬编码了 `RCLONE_VIEW_URL="https://www.jianguoyun.com/"`。
**建议：** 将其改为环境变量 `RCLONE_VIEW_URL`，默认值为空。这样其他用户如果使用 S3 或 Google Drive，可以将其设置为他们自己的控制台链接，或者留空不显示链接。

**修改 `docker/backup.sh` 开头：**
```bash
: "${RCLONE_VIEW_URL:=}" # 默认为空，由用户在 docker-compose 中定义
```

#### C. 关于 `Dockerfile` 的层级
目前的 Dockerfile 已经写得非常好（将 `apt-get` 合并在一个 layer），这很棒。
唯一的小提示：`supercronic` 的下载地址目前是硬编码版本 `0.2.30`，这很稳定。如果未来想要自动更新，可以使用 Build Args，但目前这样有利于构建的可复现性。

#### D. 目录结构
你当前的目录结构是：
```
.
├── docker/
│   ├── Dockerfile
│   ├── backup.sh
│   ├── ...
├── .github/
```
建议在根目录添加 `docker-compose.yml` 和 `README.md`，方便用户 Clone 下来直接使用。

### 总结
这是一个质量很高的实用型项目。特别是还原脚本中的 `trap` 错误回滚和本地预备份（`pre-restore`）逻辑，考虑得非常周到，极大地降低了数据丢失的风险。
