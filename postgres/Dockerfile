# Imagem PostgreSQL da organização BrasilDataHub (ghcr.io/brasildatahub/postgres),
# consumida pelos projetos da org (baseempresarial, baseescolar, ...).
#
# A configuração da instância vive AQUI (repositório infra) — schema, DDL e
# índices continuam no repositório de ETL de cada projeto. Um build por perfil:
#
#   docker build --build-arg PROFILE=atual        -t brasildatahub/postgres:17-atual .
#   docker build --build-arg PROFILE=dedicada-64  -t brasildatahub/postgres:17-dedicada-64 .
#   docker build --build-arg PROFILE=dedicada-128 -t brasildatahub/postgres:17-dedicada-128 .
#
# Os scripts de initdb/ só executam na PRIMEIRA inicialização (volume vazio).
# Para bancos de produção existentes, extensões e role vêm de script de
# higiene do projeto (ex.: rfb-cnpj-etl/sql/prod_hygiene.sql — tarefa F6).

ARG PG_VERSION=17.10
FROM postgres:${PG_VERSION}

ARG PROFILE=atual

COPY conf/${PROFILE}.conf /etc/postgresql/postgresql.conf
COPY initdb/ /docker-entrypoint-initdb.d/

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
