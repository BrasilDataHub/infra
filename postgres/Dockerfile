# Imagem PostgreSQL da organização BrasilDataHub (ghcr.io/brasildatahub/postgres),
# consumida pelos projetos da org (baseempresarial, baseescolar, ...).
#
# Imagem ÚNICA: o tuning é feito por variáveis de ambiente (PG_*), cujos
# defaults equivalem ao perfil dedicada-8gb. Os perfis por máquina
# (dedicada-8gb/16gb/32gb/64gb/128gb — todos assumem máquina dedicada com
# NVMe local) estão documentados em docs/perfis.md; nenhum rebuild é
# necessário para retunar.
#
# A configuração da instância vive AQUI (repositório infra) — schema, DDL e
# índices continuam no repositório de ETL de cada projeto.
#
# Os scripts de initdb/ só executam na PRIMEIRA inicialização (volume vazio).
# Para bancos de produção existentes, extensões e role vêm do script de
# higiene do repositório de ETL do projeto.

ARG PG_VERSION=17.10
FROM postgres:${PG_VERSION}

# pgBackRest DENTRO da imagem do banco, e não só no sidecar de backup/: quem
# executa o archive_command é o próprio servidor Postgres, como subprocesso do
# postmaster. Sem o binário aqui, PG_ARCHIVE_MODE=on faz o archive_command
# falhar a cada segmento, o pg_wal cresce sem limite e o banco cai com o disco
# cheio — o modo de falha que backup/README.md descreve.
#
# Versão travada: um upgrade de major do pgBackRest pode exigir upgrade do
# repositório, e o sidecar (backup/Dockerfile) precisa da MESMA versão que
# escreve o WAL. Os dois Dockerfiles compartilham este ARG.
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
