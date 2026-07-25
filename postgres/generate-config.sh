#!/usr/bin/env bash
# Gera /etc/postgresql/postgresql.conf a partir de variáveis de ambiente
# PG_* com defaults seguros para um host compartilhado pequeno (~4 GB para
# o Postgres). Perfis por máquina documentados em docs/perfis.md.
set -euo pipefail

CONF=/etc/postgresql/postgresql.conf

cat > "$CONF" <<EOF
# ARQUIVO GERADO no start do container por generate-config.sh — não editar
# à mão: defina as envs PG_* no deploy (ver README do infra/postgres).

# --- Conexões ---------------------------------------------------------------
listen_addresses = '*'
port = 5432
max_connections = ${PG_MAX_CONNECTIONS:-100}

# --- Memória ----------------------------------------------------------------
shared_buffers = ${PG_SHARED_BUFFERS:-2GB}
effective_cache_size = ${PG_EFFECTIVE_CACHE_SIZE:-4GB}
work_mem = ${PG_WORK_MEM:-32MB}
maintenance_work_mem = ${PG_MAINTENANCE_WORK_MEM:-512MB}

# --- Planner / IO -----------------------------------------------------------
random_page_cost = ${PG_RANDOM_PAGE_COST:-1.5}
effective_io_concurrency = ${PG_EFFECTIVE_IO_CONCURRENCY:-100}
default_statistics_target = ${PG_DEFAULT_STATISTICS_TARGET:-100}
jit = ${PG_JIT:-off}

# --- Paralelismo ------------------------------------------------------------
max_worker_processes = ${PG_MAX_WORKER_PROCESSES:-8}
max_parallel_workers = ${PG_MAX_PARALLEL_WORKERS:-8}
max_parallel_workers_per_gather = ${PG_MAX_PARALLEL_WORKERS_PER_GATHER:-2}
max_parallel_maintenance_workers = ${PG_MAX_PARALLEL_MAINTENANCE_WORKERS:-2}

# --- WAL / Checkpoints ------------------------------------------------------
max_wal_size = ${PG_MAX_WAL_SIZE:-4GB}
min_wal_size = ${PG_MIN_WAL_SIZE:-512MB}
wal_compression = ${PG_WAL_COMPRESSION:-zstd}
checkpoint_completion_target = 0.9

# --- Backup físico / PITR (pgBackRest — ver backup/) ------------------------
archive_mode = ${PG_ARCHIVE_MODE:-off}
archive_command = '${PG_ARCHIVE_COMMAND:-/bin/true}'

# --- Autovacuum -------------------------------------------------------------
autovacuum_vacuum_scale_factor = ${PG_AUTOVACUUM_VACUUM_SCALE_FACTOR:-0.2}
autovacuum_analyze_scale_factor = ${PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR:-0.1}

# --- Timeouts de servidor ---------------------------------------------------
idle_in_transaction_session_timeout = ${PG_IDLE_IN_TRANSACTION_SESSION_TIMEOUT:-60s}

# --- Diagnóstico ------------------------------------------------------------
shared_preload_libraries = '${PG_SHARED_PRELOAD_LIBRARIES:-pg_stat_statements}'
# on: sem isso, pg_stat_statements não separa tempo de IO de tempo de CPU;
# custo desprezível em clock sources modernos (verificável com pg_test_timing)
track_io_timing = ${PG_TRACK_IO_TIMING:-on}
log_min_duration_statement = ${PG_LOG_MIN_DURATION_STATEMENT:-2000}
log_line_prefix = '%m [%p] %q%u@%d '
log_timezone = 'UTC'

# --- Locale / misc (espelha os defaults da imagem oficial) -------------------
timezone = 'UTC'
datestyle = 'iso, mdy'
lc_messages = 'en_US.utf8'
lc_monetary = 'en_US.utf8'
lc_numeric = 'en_US.utf8'
lc_time = 'en_US.utf8'
default_text_search_config = 'pg_catalog.english'
dynamic_shared_memory_type = posix
EOF

chmod 644 "$CONF"
echo "postgresql.conf gerado (shared_buffers=${PG_SHARED_BUFFERS:-2GB}, random_page_cost=${PG_RANDOM_PAGE_COST:-1.5})"
