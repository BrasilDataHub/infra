# Imagem PostgreSQL da organização BrasilDataHub (ghcr.io/brasildatahub/postgres),
# consumida pelos projetos da org (baseempresarial, baseescolar, ...).
#
# Imagem ÚNICA: o tuning é feito por variáveis de ambiente (PG_*), com
# defaults seguros para um host compartilhado pequeno. Os cenários por
# máquina (compartilhada 8 GB, dedicada 64 GB, dedicada 128 GB) estão
# documentados no README — nenhum rebuild é necessário para retunar.
#
# A configuração da instância vive AQUI (repositório infra) — schema, DDL e
# índices continuam no repositório de ETL de cada projeto.
#
# Os scripts de initdb/ só executam na PRIMEIRA inicialização (volume vazio).
# Para bancos de produção existentes, extensões e role vêm de script de
# higiene do projeto (ex.: cnpj-pipeline/sql/prod_hygiene.sql — tarefa F6).

ARG PG_VERSION=17.10
FROM postgres:${PG_VERSION}

COPY generate-config.sh /usr/local/bin/generate-config.sh
COPY docker-entrypoint-wrapper.sh /usr/local/bin/docker-entrypoint-wrapper.sh
COPY initdb/ /docker-entrypoint-initdb.d/

RUN chmod +x /usr/local/bin/generate-config.sh /usr/local/bin/docker-entrypoint-wrapper.sh \
    && mkdir -p /etc/postgresql \
    && chown -R postgres:postgres /etc/postgresql

ENTRYPOINT ["docker-entrypoint-wrapper.sh"]
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
