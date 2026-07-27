#!/bin/bash
# Cria o role de leitura de MÉTRICAS (metrics_read), usado pelo postgres_exporter.
#
# Diferente do 02-role-dados-read.sh, este script roda em DOIS momentos, com o
# mesmo arquivo:
#
#   1. initdb — primeira inicialização, volume vazio (igual aos demais);
#   2. cluster JÁ existente — o entrypoint oficial não repete o initdb num volume
#      inicializado, e produção nunca está vazia. Nesse caso:
#
#        docker exec -i -e PG_METRICS_PASSWORD=... \
#            $(docker ps -q --filter label=org.brasildatahub.service=postgres) \
#            bash -s < 03-role-metrics.sh
#
#      É o que o infra-setup.sh faz com --metrics. POSTGRES_USER e POSTGRES_DB
#      não precisam ser passados: já estão no ambiente do container.
#
# Um caminho só para os dois casos é deliberado — dois divergiriam com o tempo.
# Por isso tudo aqui é idempotente: rodar de novo num banco em produção não muda
# nada além da senha.
#
# pg_monitor = pg_read_all_settings + pg_read_all_stats + pg_stat_scan_tables.
# É o mínimo de que o exporter precisa e o máximo que ele deve ter: NÃO dá
# SELECT em nenhuma tabela de dados.
set -euo pipefail

PSQL_USER="${POSTGRES_USER:-postgres}"
PSQL_DB="${POSTGRES_DB:?defina POSTGRES_DB}"

psql -v ON_ERROR_STOP=1 --username "$PSQL_USER" --dbname "$PSQL_DB" <<-EOSQL
	DO \$\$
	BEGIN
	    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metrics_read') THEN
	        CREATE ROLE metrics_read NOLOGIN;
	    END IF;
	END
	\$\$;

	GRANT pg_monitor TO metrics_read;
	GRANT CONNECT ON DATABASE "$PSQL_DB" TO metrics_read;

	-- Mesma disciplina do dados_read, por um motivo mais forte: um scrape travado
	-- segura o snapshot, e durante o ETL isso atrasa o autovacuum de TODAS as
	-- tabelas. O exporter jamais pode ser a causa de bloat.
	ALTER ROLE metrics_read SET statement_timeout = '10s';
	ALTER ROLE metrics_read SET idle_in_transaction_session_timeout = '30s';
	ALTER ROLE metrics_read SET application_name = 'postgres_exporter';

	-- O exporter mantém 1-2 conexões permanentes; o teto protege o
	-- max_connections do perfil (100 no dedicada-8gb/16gb) de um exporter em
	-- restart loop.
	ALTER ROLE metrics_read CONNECTION LIMIT 5;
EOSQL

if [ -n "${PG_METRICS_PASSWORD:-}" ]; then
    psql -v ON_ERROR_STOP=1 --username "$PSQL_USER" --dbname "$PSQL_DB" \
        -c "ALTER ROLE metrics_read LOGIN PASSWORD '${PG_METRICS_PASSWORD}';"
fi
