#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${BACKUP_FILENAME_PREFIX:=vaultwarden}"
: "${BACKUP_COMPRESSION:=gz}"
: "${RCLONE_REMOTE:=}"
: "${RCLONE_FLAGS:=}"
: "${BACKUP_RETAIN_DAYS:=14}"
: "${TELEGRAM_ENABLED:=false}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"
: "${TEST_MODE:=false}"
: "${CLEANUP_METHOD:=min-age}"

# 自动加载 rclone 配置
if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

send_telegram() {
  local error_msg="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  
  # HTML 格式（简单、可靠，无复杂转义）
  local message="<b>🚨 Vaultwarden 备份失败</b>"
  message="${message}<br><br>"
  message="${message}<b>错误详情：</b><br>"
  message="${message}<code>${error_msg}</code><br><br>"
  message="${message}<b>时间戳：</b><br>"
  message="${message}${timestamp}<br><br>"
  message="${message}<b>建议：</b><br>"
  message="${message}验证 RCLONE_REMOTE 配置或联系管理员。"
  
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    local response
    echo "📤 Sending Telegram notification..."
    response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}")
    
    # 检查响应
    if echo "$response" | grep -q '"ok":true'; then
      echo "✅ Telegram notification sent successfully"
    else
      echo "❌ Telegram API error response:"
      echo "$response" | tee -a /tmp/telegram_error.log
    fi
  else
    echo "⚠️  Telegram not enabled (ENABLED=$TELEGRAM_ENABLED, TOKEN=${TELEGRAM_BOT_TOKEN:-(empty)}, CHAT_ID=${TELEGRAM_CHAT_ID:-(empty)})"
  fi
}

if [[ "${TEST_MODE}" == "true" ]]; then
  echo "🧪 Test mode: Sending sample Telegram notification."
  send_telegram "Test error with special chars: * & < > \" '"
  exit 0
fi

if [[ -z "${RCLONE_REMOTE}" ]]; then
  send_telegram "RCLONE_REMOTE is not set; skipping backup."
  exit 0
fi

ts="$(date -u +%Y%m%d-%H%M%S)"
tmp_dir="$(mktemp -d)"
archive="${tmp_dir}/${BACKUP_FILENAME_PREFIX}-${ts}.tar.${BACKUP_COMPRESSION}"
error_msg=""

cd "${BACKUP_SRC}"

case "${BACKUP_COMPRESSION}" in
  gz)  tar -czf "${archive}" . ;;
  zst) tar -I 'zstd -19 -T0' -cf "${archive}" . ;;
  bz2) tar -cjf "${archive}" . ;;
  xz)  tar -cJf "${archive}" . ;;
  *)   echo "Unsupported compression: ${BACKUP_COMPRESSION}"; exit 2 ;;
esac

archive_size=$(du -h "${archive}" | cut -f1)
echo "📦 Backup archive created: ${archive_size}"

# 执行上传
echo "📤 Uploading to ${RCLONE_REMOTE}..."
if ! rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}; then
  error_msg="Upload failed (network or storage issue)."
else
  echo "✅ Upload completed successfully"
fi

# 过期清理
cleanup_error=""
if [[ -z "${error_msg}" && "${BACKUP_RETAIN_DAYS}" -gt 0 ]]; then
  echo "🧹 Cleanup: Deleting files older than ${BACKUP_RETAIN_DAYS} days..."
  
  if [[ "${CLEANUP_METHOD}" == "min-age" ]]; then
    if rclone delete "${RCLONE_REMOTE}" --min-age "${BACKUP_RETAIN_DAYS}d" --include "*.tar.*" -v 2>&1 | tee /tmp/rclone_delete.log; then
      echo "✅ Cleanup completed successfully"
    else
      cleanup_error="rclone --min-age failed (WebDAV compatibility issue). Attempting jq-based cleanup..."
      CLEANUP_METHOD="jq"
    fi
  fi
  
  if [[ "${CLEANUP_METHOD}" == "jq" ]]; then
    echo "🔧 Using jq-based cleanup (WebDAV compatible)..."
    if command -v jq >/dev/null 2>&1; then
      cutoff_date=$(date -d "${BACKUP_RETAIN_DAYS} days ago" '+%Y%m%d')
      deleted_count=0
      
      if rclone lsjson "${RCLONE_REMOTE}" --files-only 2>/dev/null | jq -r ".[] | select(.Path | test(\"${BACKUP_FILENAME_PREFIX}.*\\\\.tar\\\\.${BACKUP_COMPRESSION}\$\")) | .Path" | while read -r file; do
        file_date=$(echo "$file" | grep -oE "[0-9]{8}" | head -1)
        if [[ -n "$file_date" && "$file_date" -lt "$cutoff_date" ]]; then
          echo "  🗑️  Deleting: $file"
          if rclone delete "${RCLONE_REMOTE}/${file}" 2>/dev/null; then
            ((deleted_count++))
          fi
        fi
      done; then
        echo "✅ jq-based cleanup completed"
      else
        cleanup_error="jq-based cleanup failed"
      fi
    else
      cleanup_error="jq not found. Install jq or set BACKUP_RETAIN_DAYS=0 to disable cleanup."
    fi
  fi
fi

rm -rf "${tmp_dir}"

if [[ -n "${error_msg}" ]]; then
  send_telegram "${error_msg}"
  exit 1
elif [[ -n "${cleanup_error}" ]]; then
  send_telegram "${cleanup_error}"
  exit 0
fi

echo "✨ Backup completed successfully at $(date)"
