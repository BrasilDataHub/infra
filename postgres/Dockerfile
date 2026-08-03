# Imagem PostgreSQL (ghcr.io/brasildatahub/postgres). Tuning via envs PG_*; perfis em docs/perfis.md.
# initdb/ só roda em volume vazio — extensões em bancos existentes vêm do ETL do projeto.

ARG PG_VERSION=17.10
FROM postgres:${PG_VERSION}

# pgBackRest na imagem do banco — archive_command roda no postmaster, não no sidecar.
# Mesma versão em backup/Dockerfile (ARG compartilhado).
ARG PGBACKREST_VERSION=2.59.0-1.pgdg13+1
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends "pgbackrest=${PGBACKREST_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    # Os três diretórios de trabalho do pgBackRest. Sem eles o archive-push
    # falha com "unable to create path" na primeira troca de segmento — e o
    # postmaster roda como `postgres`, não como root.
    install -d -o postgres -g postgres -m 0750 \
        /var/log/pgbackrest /var/lib/pgbackrest /var/spool/pgbackrest \
        /etc/pgbackrest /etc/pgbackrest/conf.d

COPY generate-config.sh /usr/local/bin/generate-config.sh
COPY shm-guard.sh /usr/local/bin/shm-guard.sh
COPY docker-entrypoint-wrapper.sh /usr/local/bin/docker-entrypoint-wrapper.sh
COPY initdb/ /docker-entrypoint-initdb.d/

RUN chmod +x /usr/local/bin/generate-config.sh /usr/local/bin/shm-guard.sh /usr/local/bin/docker-entrypoint-wrapper.sh \
    && mkdir -p /etc/postgresql \
    && chown -R postgres:postgres /etc/postgresql

ENTRYPOINT ["docker-entrypoint-wrapper.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
