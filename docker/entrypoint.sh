#!/usr/bin/env bash
set -e

# 启动 Vaultwarden 服务
echo "🚀 Starting Vaultwarden service..."
/start.sh &
SERVICE_PID=$!

# 配置定时备份（如果启用）
if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
  echo "📅 Configuring backup schedule: ${BACKUP_CRON}"
  
  # 创建 crontab 任务
  CRON_CMD="/usr/local/bin/backup.sh >> /var/log/backup.log 2>&1"
  (crontab -l 2>/dev/null || true; echo "${BACKUP_CRON} ${CRON_CMD}") | crontab -
  
  # 启动 supercronic（cron 后台进程）
  /usr/local/bin/supercronic /etc/cron.d/crontabs/root &
  CRON_PID=$!
  
  echo "✅ Backup scheduler started"
fi

# 等待服务
wait $SERVICE_PID
