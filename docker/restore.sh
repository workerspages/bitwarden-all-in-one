#!/usr/bin/env bash
set -euo pipefail

: "${BACKUP_SRC:=/data}"
: "${RESTORE_STRATEGY:=replace}"

# 强制要求 RCLONE_REMOTE 已通过 PaaS 环境变量正确注入
if [[ -z "${RCLONE_REMOTE:-}" ]]; then
  echo "Error: RCLONE_REMOTE not set. 请在 PaaS 平台环境变量区设置，示例 jianguoyun:vaultwarden-rclone"
  exit 1
fi

# 自动加载 rclone.conf，完全兼容 PaaS 环境变量注入
if [[ -z "${RCLONE_CONFIG:-}" && -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# 用法说明
mode="${1:-}"
if [[ -z "${mode}" ]]; then
  echo "Usage: restore.sh latest | <remote-object-filename>"
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# 获取最新备份文件名
fetch_latest() {
  if ! rclone lsjson "${RCLONE_REMOTE}" --files-only --fast-list >"${work}/ls.json"; then
    echo "Error: rclone 无法列出远程文件。请检查 RCLONE_REMOTE 路径和 rclone.conf。"
    exit 2
  fi
  jq -r 'sort_by(.ModTime)|last|.Path' <"${work}/ls.json"
}

remote_obj="${mode}"
if [[ "${mode}" == "latest" ]]; then
  remote_obj="$(fetch_latest)"
fi

if [[ -z "${remote_obj}" ]]; then
  echo "Error: 没找到远程备份文件，请检查网盘及路径配置"
  exit 2
fi

local_archive="${work}/restore.tar"
if ! rclone copyto "${RCLONE_REMOTE%/}/${remote_obj}" "${local_archive}"; then
  echo "Error: 下载[${remote_obj}]失败，请检查认证、路径或网盘API"
  exit 2
fi

backup_before="${BACKUP_SRC%/}.pre-restore-$(date -u +%Y%m%d-%H%M%S)"
cp -a "${BACKUP_SRC}" "${backup_before}"

if [[ "${RESTORE_STRATEGY}" == "replace" ]]; then
  find "${BACKUP_SRC}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
fi

case "${local_archive}" in
  *.tar.gz|*.tgz)    tar -xzf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.zst|*.tzst)  tar -I zstd -xf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.bz2|*.tbz2)  tar -xjf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar.xz|*.txz)    tar -xJf "${local_archive}" -C "${BACKUP_SRC}" ;;
  *.tar)             tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
  *)                 tar -xf  "${local_archive}" -C "${BACKUP_SRC}" ;;
esac

echo "Restore done. Previous data saved at: ${backup_before}"
