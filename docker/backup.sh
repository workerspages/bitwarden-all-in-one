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
: "${TELEGRAM_MESSAGE:=🚨 *Vaultwarden 备份失败*\\n*错误详情：* %ERROR%\\n*时间戳：* %TIME%\\n*建议：* 验证 RCLONE_REMOTE 配置或联系管理员。}"
: "${TEST_MODE:=false}"
: "${CLEANUP_METHOD:=min-age}"  # 新增：支持 min-age（快速）或 jq（兼容）

# 自动加载 rclone 配置
if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# MarkdownV2 转义函数
escape_markdown_v2() {
  local text="$1"
  text=$(echo "$text" | sed 's/[_*[]()~>#+=|{}.!\\-/\\/g')
  echo "$text"
}

send_telegram() {
  local error_msg="$1"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
  local message="$TELEGRAM_MESSAGE"
  
  local escaped_error=$(escape_markdown_v2 "$error_msg")
  message="${message//%ERROR%/${escaped_error}}"
  message="${message//%TIME%/${timestamp}}"
  
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\",\"parse_mode\":\"MarkdownV2\"}" >/dev/null || {
        echo "Telegram notification failed (non-fatal)"
      }
  fi
}

if [[ "${TEST_MODE}" == "true" ]]; then
  echo "Test mode: Sending sample Telegram notification."
  send_telegram "Test error with special chars: * & \\"
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

echo "Backup archive created: $(du -h "${archive}" | cut -f1)"

# 执行上传并检查
echo "Uploading to ${RCLONE_REMOTE}..."
if ! rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}; then
  error_msg="Upload failed (network or storage issue)."
else
  echo "Upload completed successfully"
fi

# 过期清理
cleanup_error=""
if [[ -z "${error_msg}" && "${BACKUP_RETAIN_DAYS}" -gt 0 ]]; then
  echo "Cleanup: Deleting files older than ${BACKUP_RETAIN_DAYS} days..."
  
  if [[ "${CLEANUP_METHOD}" == "min-age" ]]; then
    # 方法1：使用 rclone --min-age（快速，但某些WebDAV不支持）
    if rclone delete "${RCLONE_REMOTE}" --min-age "${BACKUP_RETAIN_DAYS}d" --include "*.tar.*" -v 2>&1 | tee /tmp/rclone_delete.log; then
      echo "Cleanup completed successfully"
    else
      cleanup_error="rclone --min-age failed. Retrying with jq-based method..."
      CLEANUP_METHOD="jq"  # 自动 fallback
    fi
  fi
  
  if [[ "${CLEANUP_METHOD}" == "jq" ]]; then
    # 方法2：使用 jq 手动删除（兼容所有 WebDAV，包括坚果云）
    if command -v jq >/dev/null 2>&1; then
      echo "Using jq-based cleanup (compatible with WebDAV)..."
      cutoff_date=$(date -d "${BACKUP_RETAIN_DAYS} days ago" '+%Y%m%d')
      
      # 列出所有文件，过滤旧备份，逐一删除
      cleanup_error=""
      deleted_count=0
      if rclone lsjson "${RCLONE_REMOTE}" --files-only 2>/dev/null | jq -r ".[] | select(.Path | test(\"${BACKUP_FILENAME_PREFIX}.*\\\\.tar\\\\.${BACKUP_COMPRESSION}\$\")) | .Path" | while read -r file; do
        file_date=$(echo "$file" | grep -oE "[0-9]{8}" | head -1)
        if [[ -n "$file_date" && "$file_date" -lt "$cutoff_date" ]]; then
          echo "  Deleting old backup: $file (date: $file_date)"
          if rclone delete "${RCLONE_REMOTE}/${file}" -v 2>&1; then
            ((deleted_count++))
          else
            echo "  Warning: Failed to delete $file"
          fi
        fi
      done; then
        echo "jq-based cleanup completed (deleted $deleted_count old files)"
      else
        cleanup_error="jq-based cleanup failed. Check remote access or jq availability."
      fi
    else
      cleanup_error="jq not found. Cannot perform backup retention cleanup. Install jq or disable cleanup by setting BACKUP_RETAIN_DAYS=0."
    fi
  fi
fi

rm -rf "${tmp_dir}"

if [[ -n "${error_msg}" ]]; then
  send_telegram "${error_msg}"
  exit 1
elif [[ -n "${cleanup_error}" ]]; then
  send_telegram "${cleanup_error}"
  exit 0  # 清理失败非致命
fi

echo "Backup completed successfully at $(date)"
