# Imagem customizada do PostgreSQL do BaseEmpresarial.
#
# A configuração da instância vive AQUI (repositório infra/) — schema, DDL e
# índices continuam no rfb-cnpj-etl. Um build por perfil:
#
#   docker build --build-arg PROFILE=atual        -t baseempresarial-postgres:17-atual .
#   docker build --build-arg PROFILE=dedicada-64  -t baseempresarial-postgres:17-dedicada-64 .
#   docker build --build-arg PROFILE=dedicada-128 -t baseempresarial-postgres:17-dedicada-128 .
#
# Os scripts de initdb/ só executam na PRIMEIRA inicialização (volume vazio).
# Para o banco de produção existente, extensões e role vêm do script de
# higiene do ETL (rfb-cnpj-etl/sql/prod_hygiene.sql — tarefa F6).

ARG PG_VERSION=17.10
FROM postgres:${PG_VERSION}

ARG PROFILE=atual

COPY conf/${PROFILE}.conf /etc/postgresql/postgresql.conf
COPY initdb/ /docker-entrypoint-initdb.d/

CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
