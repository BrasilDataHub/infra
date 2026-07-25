# Redis da organização BrasilDataHub (ghcr.io/brasildatahub/redis):
# cache de aplicação + fila (Horizon) dos projetos da org.
#
# Imagem ÚNICA: a conf base é embutida; o dimensionamento (maxmemory,
# política de despejo) e a senha vêm de envs no start — os perfis por
# orçamento de memória estão documentados no README.

FROM redis:7.4-alpine

COPY redis.conf /usr/local/etc/redis/redis.conf

# Argumentos de CLI têm precedência sobre o redis.conf:
# - REDIS_MAXMEMORY (default 512mb) e REDIS_MAXMEMORY_POLICY (default
#   volatile-lru — ver justificativa no redis.conf) dimensionam a instância;
# - REDIS_PASSWORD anexa --requirepass (redis.conf não lê variáveis de env).
CMD ["sh", "-c", "redis-server /usr/local/etc/redis/redis.conf --maxmemory ${REDIS_MAXMEMORY:-512mb} --maxmemory-policy ${REDIS_MAXMEMORY_POLICY:-volatile-lru} ${REDIS_PASSWORD:+--requirepass \"$REDIS_PASSWORD\"}"]
