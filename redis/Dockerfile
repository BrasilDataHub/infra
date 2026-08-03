# Redis (ghcr.io/brasildatahub/redis): cache + fila. Dimensionamento via env no start.

FROM redis:7.4-alpine

COPY redis.conf /usr/local/etc/redis/redis.conf

# CLI sobrescreve redis.conf; exec docker-entrypoint.sh evita rodar redis-server como root.
CMD ["sh", "-c", "exec docker-entrypoint.sh redis-server /usr/local/etc/redis/redis.conf --maxmemory ${REDIS_MAXMEMORY:-512mb} --maxmemory-policy ${REDIS_MAXMEMORY_POLICY:-volatile-lru} --appendonly ${REDIS_APPENDONLY:-yes} ${REDIS_PASSWORD:+--requirepass \"$REDIS_PASSWORD\"}"]
