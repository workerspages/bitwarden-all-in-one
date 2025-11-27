#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${RESTORE_STRATEGY:=replace}"
: "${TELEGRAM_ENABLED:=false}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${RCLONE_REMOTE:=}"

# 自动加载 rclone 配置 (修复 base64)
if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | tr -d '\n\r ' | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# Telegram 通知函数
send_telegram_message() {
  local message="$1" local type="$2"
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${message}" \
      -d "parse_mode=HTML" >/dev/null
  fi
}

send_restore_success() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local message=$(printf '<b>✅ Vaultwarden 数据还原成功</b>\n\n<b>📅 完成时间</b>\n%s\n\n<b>💾 源文件</b>\n<code>%s</code>\n\n⚠️ <b>注意：</b> 容器即将重启以加载新数据。' \
    "${timestamp}" "${remote_obj}")
  send_telegram_message "$message" "成功"
}

send_restore_error() {
  local error_msg="$1" local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local escaped_error=$(echo "$error_msg" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
  local message=$(printf '<b>🚨 Vaultwarden 数据还原失败</b>\n\n<b>❌ 错误详情</b>\n<code>%s</code>\n\n<b>⏰ 发生时间</b>\n%s' \
    "$escaped_error" "${timestamp}")
  send_telegram_message "$message" "错误"
}

mode="${1:-}"
if [[ -z "${mode}" ]]; then
  echo "Usage: restore.sh latest | <remote-object-filename> | <local-file-path>"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

local_archive=""
remote_obj="${mode}"

# --- 检查是否为本地文件 ---
if [[ -f "${mode}" ]]; then
  echo "📂 Detected local file input: ${mode}"
  local_archive="${mode}"
  if [[ ! "${mode}" =~ \.(tar|gz|zst|bz2|xz|zip)$ ]]; then
    send_restore_error "Invalid file format uploaded"
    exit 1
  fi
else
  # --- 从 Rclone 下载 ---
  fetch_latest() {
    if ! rclone lsjson "${RCLONE_REMOTE}" --files-only --fast-list >"${work}/ls.json" 2>/dev/null; then
      send_restore_error "Failed to list remote files in ${RCLONE_REMOTE}"
      exit 1
    fi
    jq -r 'sort_by(.ModTime)|last? | .Path // empty' <"${work}/ls.json"
  }

  if [[ "${mode}" == "latest" ]]; then
    if [[ -z "${RCLONE_REMOTE}" ]]; then
      send_restore_error "RCLONE_REMOTE is not set for latest mode"
      exit 1
    fi
    remote_obj="$(fetch_latest)"
  fi

  if [[ -z "${remote_obj}" ]]; then
    send_restore_error "No remote object to restore"
    exit 1
  fi

  echo "☁️  Downloading from remote: ${remote_obj}"
  local_archive="${work}/restore.tar"
  if ! rclone copyto "${RCLONE_REMOTE%/}/${remote_obj}" "${local_archive}" 2>/dev/null; then
    send_restore_error "Failed to download backup file: ${remote_obj}"
    exit 1
  fi
fi

# --- 备份当前数据 ---
backup_before="${BACKUP_SRC%/}.pre-restore-$(date -u +%Y%m%d-%H%M%S)"
echo "📦 Backing up current data to ${backup_before}..."
# 使用 cp -a 备份，忽略可能的 socket/lock 文件错误
if ! cp -a "${BACKUP_SRC}" "${backup_before}" 2>/dev/null; then
  echo "⚠️ Warning: Some files could not be backed up (likely locked), proceeding anyway..."
fi

# 设置错误回滚 (如果解压失败)
trap 'echo "⚠️ Restore failed! Rolling back..."; cp -af "${backup_before}/." "${BACKUP_SRC}/"; rm -rf "${work}"' ERR

# --- 核心修复：宽容清理 ---
if [[ "${RESTORE_STRATEGY}" == "replace" ]]; then
  echo "🧹 Cleaning existing data..."
  # 关键修改：后面加了 || true，忽略 .nfs 等无法删除的文件报错
  find "${BACKUP_SRC}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
fi

echo "🔓 Extracting archive..."
# 增加 --overwrite 选项确保覆盖锁定的文件（如果 tar 支持），标准 tar 默认就是覆盖
case "${local_archive}" in
  *.tar.gz|*.tgz)    tar -xzf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.zst|*.tzst)  tar -I zstd -xf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.bz2|*.tbz2)  tar -xjf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.xz|*.txz)    tar -xJf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar)             tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.zip)             unzip -o "${local_archive}" -d "${BACKUP_SRC}" ;;
  *)                 tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
esac

# 成功后移除 trap
trap 'rm -rf "${work}"' EXIT

echo "✅ Restore data placed. Previous data saved at: ${backup_before}"
send_restore_success

# --- 核心修复：重启容器 ---
# 必须杀掉 vaultwarden 进程，让 Docker/Zeabur 自动重启容器。
# 只有重启才能释放旧的数据库锁并加载刚才还原的数据。
echo "🔄 Killing Vaultwarden process to force container restart..."
pkill -f vaultwarden || true
# 脚本到此结束，容器随后会重启
