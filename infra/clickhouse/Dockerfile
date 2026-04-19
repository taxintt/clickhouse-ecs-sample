ARG CLICKHOUSE_VERSION=24.12-alpine
FROM clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}

# Remove docker_related_config to prevent listen_host conflicts
RUN rm -f /etc/clickhouse-server/config.d/docker_related_config.xml

# Override configs go to config.d/ (default config.xml is preserved)
COPY config/config.xml /etc/clickhouse-server/config.d/custom.xml
COPY config/remote_servers.xml /etc/clickhouse-server/config.d/remote_servers.xml
COPY config/macros.xml /etc/clickhouse-server/config.d/macros.xml
COPY config/keeper.xml /etc/clickhouse-server/config.d/keeper.xml

# listen_host config
COPY config/listen.xml /etc/clickhouse-server/config.d/listen.xml

# Restore console logging (removed with docker_related_config.xml)
COPY config/logger.xml /etc/clickhouse-server/config.d/logger.xml

# Users config override (placeholders replaced at runtime by entrypoint-wrapper.sh)
COPY config/users.xml /etc/clickhouse-server/users.d/custom.xml

# Custom entrypoint that substitutes env vars into users config
COPY entrypoint-wrapper.sh /entrypoint-wrapper.sh
RUN chmod +x /entrypoint-wrapper.sh

# Schema files are NOT in /docker-entrypoint-initdb.d/
# Apply schema manually after cluster is running (see README)

ENTRYPOINT ["/entrypoint-wrapper.sh"]

# Health check
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8123/ping || exit 1

EXPOSE 8123 9000 9009 9363
