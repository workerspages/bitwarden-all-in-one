FROM vaultwarden/server:latest

ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# 安装所有依赖工具（一次性 RUN，减少镜像层）
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl tzdata bash unzip jq; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo $TZ > /etc/timezone; \
    dpkg-reconfigure --frontend noninteractive tzdata; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL https://rclone.org/install.sh | bash; \
    SUPERCRONIC_VERSION=0.2.30; \
    curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64"; \
    chmod +x /usr/local/bin/supercronic

# 复制脚本并设置权限
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/backup.sh     /usr/local/bin/backup.sh
COPY docker/restore.sh    /usr/local/bin/restore.sh
RUN chmod +x /usr/local/bin/*.sh

# 定义环境变量（所有可在 PaaS 平台覆盖）
ENV BACKUP_ENABLED=true \
    BACKUP_CRON="0 3 * * *" \
    BACKUP_SRC="/data" \
    BACKUP_FILENAME_PREFIX="vaultwarden" \
    BACKUP_COMPRESSION="gz" \
    BACKUP_RETAIN_DAYS=14 \
    CLEANUP_METHOD="min-age" \
    RCLONE_CONF_BASE64="" \
    RCLONE_REMOTE="" \
    RCLONE_FLAGS="--checksum --transfers=4 --checkers=8 --fast-list" \
    RESTORE_STRATEGY="replace" \
    TEST_MODE="false" \
    TELEGRAM_ENABLED="false" \
    TELEGRAM_BOT_TOKEN="" \
    TELEGRAM_CHAT_ID="" \
    TELEGRAM_MESSAGE="🚨 *Vaultwarden 备份失败*\\n*错误详情：* %ERROR%\\n*时间戳：* %TIME%\\n*建议：* 验证 RCLONE_REMOTE 配置或联系管理员。"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
