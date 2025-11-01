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

# 修复：清理 RCLONE_REMOTE 中可能的前缀（如 PaaS 自动添加的版本号）
RCLONE_REMOTE="${RCLONE_REMOTE#0}"  # 移除前缀 "0"（如有）
RCLONE_REMOTE="${RCLONE_REMOTE#0}"  # 再次移除以防多个前缀

send_telegram() {
  local error_msg="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  
  # HTML 格式（用 \n 换行，不用 <br>）
  local message="<b>🚨 Vaultwarden 备份失败</b>
<b>错误详情：</b>
<code>${error_msg}</code>

<b>时间戳：</b>
${timestamp}

<b>建议：</b>
验证 RCLONE_REMOTE 配置或联系管理员。"
  
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    local response
    echo "📤 Sending Telegram notification..."
    response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}")
    
    if echo "$response" | grep -q '"ok":true'; then
      echo "✅ Telegram notification sent successfully"
    else
      echo "❌ Telegram API error response:"
      echo "$response" | tee -a /tmp/telegram_error.log
    fi
  else
    echo "⚠️  Telegram not enabled"
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
      cleanup_error="rclone --min-age failed. Retrying with jq method..."
      CLEANUP_METHOD="jq"
    fi
  fi
  
  if [[ "${CLEANUP_METHOD}" == "jq" ]]; then
    echo "🔧 Using jq-based cleanup..."
    if command -v jq >/dev/null 2>&1; then
      cutoff_date=$(date -d "${BACKUP_RETAIN_DAYS} days ago" '+%Y%m%d')
      if rclone lsjson "${RCLONE_REMOTE}" --files-only 2>/dev/null | jq -r ".[] | select(.Path | test(\"${BACKUP_FILENAME_PREFIX}.*\\\\.tar\\\\.${BACKUP_COMPRESSION}\$\")) | .Path" | while read -r file; do
        file_date=$(echo "$file" | grep -oE "[0-9]{8}" | head -1)
        if [[ -n "$file_date" && "$file_date" -lt "$cutoff_date" ]]; then
          echo "  🗑️  Deleting: $file"
          rclone delete "${RCLONE_REMOTE}/${file}" 2>/dev/null || true
        fi
      done; then
        echo "✅ jq-based cleanup completed"
      else
        cleanup_error="jq cleanup failed"
      fi
    else
      cleanup_error="jq not found"
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

echo "✨ Backup completed successfully"
