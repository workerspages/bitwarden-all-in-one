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
: "${TELEGRAM_MESSAGE:=Vaultwarden backup failed: %ERROR% at %TIME%}"

send_telegram() {
  local message="$1"
  if [[ "${TELEGRAM_ENABLED}" == "true" && -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${message}\"}" >/dev/null || true
  fi
}

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

# 执行上传并检查
if ! rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}; then
  error_msg="Upload failed (network or storage issue)."
fi

# 过期清理（可选，如果上传成功再清理）
if [[ -z "${error_msg}" && "${BACKUP_RETAIN_DAYS}" -gt 0 ]]; then
  if ! rclone delete "${RCLONE_REMOTE}" --min-age "${BACKUP_RETAIN_DAYS}d" || true; then
    error_msg="Cleanup failed after successful upload."
  fi
fi

rm -rf "${tmp_dir}"

if [[ -n "${error_msg}" ]]; then
  local_time="$(date)"
  msg="${TELEGRAM_MESSAGE//%ERROR%/${error_msg}}"
  msg="${msg//%TIME%/${local_time}}"
  send_telegram "${msg}"
  exit 1
fi
