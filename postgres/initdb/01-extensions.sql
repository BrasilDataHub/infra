-- Executado apenas na PRIMEIRA inicialização (volume vazio), no banco
-- definido por POSTGRES_DB. Para bancos existentes, use o script de higiene
-- do ETL (rfb-cnpj-etl/sql/prod_hygiene.sql).

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS btree_gin;
