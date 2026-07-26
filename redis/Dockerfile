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
#
# O `exec docker-entrypoint.sh redis-server` no meio não é enfeite: o entrypoint
# oficial só ajusta o dono de /data e degrada para o usuário `redis` (uid 999)
# quando recebe `redis-server` como primeiro argumento. Chamando `redis-server`
# direto a partir do `sh -c`, o daemon rodaria como ROOT e escreveria o AOF com
# dono root no bind mount do host.
CMD ["sh", "-c", "exec docker-entrypoint.sh redis-server /usr/local/etc/redis/redis.conf --maxmemory ${REDIS_MAXMEMORY:-512mb} --maxmemory-policy ${REDIS_MAXMEMORY_POLICY:-volatile-lru} ${REDIS_PASSWORD:+--requirepass \"$REDIS_PASSWORD\"}"]
