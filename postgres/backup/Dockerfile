# Sidecar de backup físico (ghcr.io/brasildatahub/pgbackrest) — pgBackRest +
# agendador, no MESMO host do Postgres. A especificação está no README ao lado.
#
# Por que a base é `postgres:17.10` e não `debian:trixie-slim`, que seria menor:
#
#   1. UID. O sidecar monta o volume de dados do banco e precisa LER o PGDATA,
#      que é 0700 do usuário `postgres` (uid 999 na imagem oficial). Numa base
#      genérica seria preciso recriar o usuário com o uid exato — e um uid
#      divergente só se manifesta como "permission denied" no primeiro backup.
#   2. O repositório PGDG e sua chave já estão configurados, então a versão do
#      pgBackRest é a mesma do banco sem repetir a configuração de apt.
#   3. `psql` vem junto, e a validação de restore precisa dele.
#
#   Custo real ≈ 0: o host que roda o banco já tem essas camadas em disco.

ARG PG_VERSION=17.10
FROM postgres:${PG_VERSION}

# MESMA versão da imagem do banco (../Dockerfile). Divergir aqui é possível — o
# formato do repositório é estável — mas não há ganho, e uma versão do sidecar
# mais NOVA que a do archive-push já apareceu como aviso de compatibilidade em
# `pgbackrest check`.
ARG PGBACKREST_VERSION=2.59.0-1.pgdg13+1
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        "pgbackrest=${PGBACKREST_VERSION}" \
        cron \
        jq \
        tzdata; \
    rm -rf /var/lib/apt/lists/*; \
    # O cron do Debian instala jobs próprios em /etc/cron.d e /etc/cron.daily
    # que só existem para uma máquina completa (man-db, apt, logrotate). Num
    # container eles rodam como root a cada dia sem servir para nada.
    rm -f /etc/cron.d/e2scrub_all /etc/cron.daily/* /etc/cron.weekly/* /etc/cron.monthly/*; \
    install -d -o postgres -g postgres -m 0750 \
        /var/log/pgbackrest /var/lib/pgbackrest /var/spool/pgbackrest \
        /etc/pgbackrest /etc/pgbackrest/conf.d; \
    # Diretório do textfile collector do node_exporter. É por ele que o
    # resultado de cada backup vira métrica — ver backup-run.sh.
    install -d -o postgres -g postgres -m 0755 /var/lib/node_exporter/textfile

COPY entrypoint.sh /usr/local/bin/pgbackrest-entrypoint.sh
COPY backup-run.sh /usr/local/bin/pgbackrest-backup-run.sh
COPY restore-test.sh /usr/local/bin/pgbackrest-restore-test.sh

RUN chmod +x /usr/local/bin/pgbackrest-entrypoint.sh \
             /usr/local/bin/pgbackrest-backup-run.sh \
             /usr/local/bin/pgbackrest-restore-test.sh

# Roda como root: o `cron` precisa de root para trocar de usuário, e cada job em
# /etc/cron.d declara `postgres` no sexto campo. O pgBackRest em si nunca roda
# como root — ele recusa, e com razão.
ENTRYPOINT ["/usr/local/bin/pgbackrest-entrypoint.sh"]
CMD ["cron", "-f", "-L", "2"]
