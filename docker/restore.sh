#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${RESTORE_STRATEGY:=replace}"
: "${TELEGRAM_ENABLED:=false}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${RCLONE_REMOTE:=}"

if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | tr -d '\n\r ' | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

send_telegram_message() {
  local message="$1" 
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=HTML" >/dev/null
  fi
}

send_restore_success() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local message=$(printf '<b>✅ Vaultwarden 数据还原成功</b>\n\n<b>📅 完成时间</b>\n%s\n\n⚠️ <b>注意：</b> 容器即将重启。' "${timestamp}")
  send_telegram_message "$message"
}

send_restore_error() {
  local error_msg="$1"
  send_telegram_message "<b>🚨 还原失败</b>: $error_msg"
}

mode="${1:-}"
if [[ -z "${mode}" ]]; then echo "Usage: restore.sh latest | <filename>"; exit 1; fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

local_archive=""
remote_obj="${mode}"

if [[ -f "${mode}" ]]; then
  local_archive="${mode}"
else
  if [[ "${mode}" == "latest" ]]; then
    remote_obj="$(rclone lsjson "${RCLONE_REMOTE}" --files-only --fast-list | jq -r 'sort_by(.ModTime)|last? | .Path // empty')"
  fi
  if [[ -z "${remote_obj}" ]]; then send_restore_error "No object found"; exit 1; fi
  
  echo "☁️ Downloading ${remote_obj}..."
  local_archive="${work}/restore.tar"
  if ! rclone copyto "${RCLONE_REMOTE%/}/${remote_obj}" "${local_archive}"; then
    send_restore_error "Download failed"; exit 1
  fi
fi

# --- 核心还原逻辑 (现在非常安全) ---
# 备份现有数据以防万一
backup_before="${BACKUP_SRC%/}.pre-restore-$(date -u +%Y%m%d-%H%M%S)"
echo "📦 Pre-backup to ${backup_before}..."
cp -a "${BACKUP_SRC}" "${backup_before}" 2>/dev/null || true

# 清理 /data (注意：这不会删掉 /conf 下的配置文件)
if [[ "${RESTORE_STRATEGY}" == "replace" ]]; then
  echo "🧹 Cleaning /data..."
  find "${BACKUP_SRC}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
fi

echo "🔓 Extracting..."
case "${local_archive}" in
  *.tar.gz|*.tgz)    tar -xzf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.zst|*.tzst)  tar -I zstd -xf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.bz2|*.tbz2)  tar -xjf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.xz|*.txz)    tar -xJf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar)             tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.zip)             unzip -o "${local_archive}" -d "${BACKUP_SRC}" ;;
  *)                 tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
esac

echo "✅ Restore complete."
send_restore_success

echo "🔄 Restarting container..."
pkill -f vaultwarden || true
