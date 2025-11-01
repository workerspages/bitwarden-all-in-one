#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${BACKUP_FILENAME_PREFIX:=vaultwarden}"
: "${BACKUP_COMPRESSION:=gz}"
: "${RCLONE_REMOTE:=}"
: "${RCLONE_FLAGS:=}"
: "${BACKUP_RETAIN_DAYS:=14}"

if [[ -z "${RCLONE_REMOTE}" ]]; then
  echo "RCLONE_REMOTE is not set; skip backup."
  exit 0
fi

ts="$(date -u +%Y%m%d-%H%M%S)"
tmp_dir="$(mktemp -d)"
archive="${tmp_dir}/${BACKUP_FILENAME_PREFIX}-${ts}.tar.${BACKUP_COMPRESSION}"

cd "${BACKUP_SRC}"

case "${BACKUP_COMPRESSION}" in
  gz)  tar -czf "${archive}" . ;;
  zst) tar -I 'zstd -19 -T0' -cf "${archive}" . ;;
  bz2) tar -cjf "${archive}" . ;;
  xz)  tar -cJf "${archive}" . ;;
  *)   echo "Unsupported compression: ${BACKUP_COMPRESSION}"; exit 2 ;;
esac

rclone copy "${archive}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS}
rm -rf "${tmp_dir}"

# 过期清理（按远端对象年龄）
if [[ "${BACKUP_RETAIN_DAYS}" -gt 0 ]]; then
  rclone delete "${RCLONE_REMOTE}" --min-age "${BACKUP_RETAIN_DAYS}d" || true
fi
