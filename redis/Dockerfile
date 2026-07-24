# Redis da organização BrasilDataHub (ghcr.io/brasildatahub/redis):
# cache de aplicação + fila (Horizon) dos projetos da org.
# Conf versionada embutida na imagem; senha via env no start
# (redis.conf não lê variáveis de ambiente).

FROM redis:7.4-alpine

COPY redis.conf /usr/local/etc/redis/redis.conf

# --requirepass é anexado pelo entrypoint/compose (REDIS_PASSWORD)
CMD ["sh", "-c", "redis-server /usr/local/etc/redis/redis.conf ${REDIS_PASSWORD:+--requirepass \"$REDIS_PASSWORD\"}"]
