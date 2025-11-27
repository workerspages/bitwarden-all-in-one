#!/usr/bin/env bash
set -e

# 定义配置路径
CONF_DIR="/conf"
CONF_FILE="${CONF_DIR}/env.conf"
LOG_FILE="${CONF_DIR}/backup.log"

# --- 0. 自动迁移逻辑 (兼容旧版本) ---
# 如果旧位置有配置，新位置没有，则移动过去
if [[ -f "/data/env.conf" && ! -f "$CONF_FILE" ]]; then
    echo "📦 Migrating configuration from /data to /conf..."
    mv /data/env.conf "$CONF_FILE"
fi

# --- 1. 优先处理 Rclone 配置 ---
if [[ -n "${RCLONE_CONF_BASE64}" ]]; then
    echo "⚙️  Generating Rclone config from environment variable..."
    mkdir -p /config/rclone
    echo "${RCLONE_CONF_BASE64}" | tr -d '\n\r ' | base64 -d > /config/rclone/rclone.conf
    export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# --- 2. 加载持久化配置 ---
if [[ -f "$CONF_FILE" ]]; then
    echo "📜 Loading configuration from $CONF_FILE..."
    set -a
    source "$CONF_FILE"
    set +a
fi

if [[ -z "${RCLONE_CONFIG}" && -f "/config/rclone/rclone.conf" ]]; then
    export RCLONE_CONFIG="/config/rclone/rclone.conf"
fi

# --- 3. 初始化日志 ---
touch "$LOG_FILE"
echo "--- System Started at $(date) ---" >> "$LOG_FILE"

# --- 4. 启动 Web 控制台 ---
echo "🖥️  Starting Dashboard..."
# 传递新的配置文件路径给 Python (虽然 app.py 里硬编码了，但这里通过 env 传递是个好习惯)
python3 /app/dashboard/app.py >> /var/log/dashboard.log 2>&1 &
DASH_PID=$!

# --- 5. 启动 Vaultwarden ---
echo "🚀 Starting Vaultwarden service..."
exec_path="/start.sh"

if [[ "${BACKUP_ENABLED:-true}" == "true" ]]; then
  echo "📅 Configuring backup schedule: ${BACKUP_CRON}"
  
  CRONTAB_FILE="/tmp/crontab"
  # 注意：日志输出到 /conf/backup.log
  cat > "$CRONTAB_FILE" <<EOF
# Vaultwarden Backup Schedule
${BACKUP_CRON} /usr/local/bin/backup.sh >> ${LOG_FILE} 2>&1
EOF
  
  "$exec_path" &
  SERVICE_PID=$!
  
  /usr/local/bin/supercronic "$CRONTAB_FILE" >> "$LOG_FILE" 2>&1 &
  CRON_PID=$!
  
  echo "✅ Backup scheduler started."
  wait -n $SERVICE_PID $CRON_PID $DASH_PID
else
  "$exec_path" &
  SERVICE_PID=$!
  wait -n $SERVICE_PID $DASH_PID
fi
