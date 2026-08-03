# Sidecar pgBackRest (ghcr.io/brasildatahub/pgbackrest). Base postgres:17.10 para uid 999 e PGDG.

ARG PG_VERSION=17.10
FROM postgres:${PG_VERSION}

# Mesma versão da imagem do banco (../Dockerfile).
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
