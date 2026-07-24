#!/bin/bash
# Cria o role de leitura do website (dados_read) com timeouts de servidor.
# Executado apenas na PRIMEIRA inicialização (volume vazio). A senha vem da
# env DADOS_READ_PASSWORD; sem ela, o role é criado com NOLOGIN e a senha
# deve ser definida depois (ALTER ROLE dados_read LOGIN PASSWORD '...').
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dados_read') THEN
            CREATE ROLE dados_read NOLOGIN;
        END IF;
    END
    \$\$;

    ALTER ROLE dados_read SET statement_timeout = '15s';
    ALTER ROLE dados_read SET idle_in_transaction_session_timeout = '60s';

    GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO dados_read;
    GRANT USAGE ON SCHEMA public TO dados_read;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO dados_read;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO dados_read;
EOSQL

if [ -n "${DADOS_READ_PASSWORD:-}" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
        -c "ALTER ROLE dados_read LOGIN PASSWORD '${DADOS_READ_PASSWORD}';"
fi
