#!/usr/bin/env bash
set -euo pipefail

# 写入 rclone 配置
if [[ -n "${RCLONE_CONF_BASE64:-}" ]]; then
  mkdir -p /config/rclone
  echo "${RCLONE_CONF_BASE64}" | base64 -d > /config/rclone/rclone.conf
  export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# 生成定时任务文件供 supercronic 使用
if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
  mkdir -p /opt
  echo "${BACKUP_CRON} /usr/local/bin/backup.sh" > /opt/backup.cron
  /usr/local/bin/supercronic -quiet /opt/backup.cron &
fi

# 兼容官方镜像启动方式
if [[ -x "/start.sh" ]]; then
  exec /start.sh
elif command -v vaultwarden >/dev/null 2>&1; then
  exec vaultwarden
else
  echo "Cannot find vaultwarden entrypoint, please check base image."
  exit 1
fi
