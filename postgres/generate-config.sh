#!/usr/bin/env bash
# Gera /etc/postgresql/postgresql.conf a partir de variáveis de ambiente PG_*.
# Os defaults equivalem ao perfil dedicada-8gb (8 GB de orçamento para o
# Postgres, 2–4 vCPU, NVMe local) — o menor perfil do catálogo. Todos os
# perfis por máquina estão em docs/perfis.md.
#
# Ao adicionar um parâmetro, separe o default com ":-" (dois-pontos e hífen),
# nunca só com "-": sem os dois-pontos, uma env definida como vazia no compose
# gera uma linha sem valor no conf e o Postgres não sobe. A ordem das seções
# abaixo é a mesma da tabela mestra de docs/perfis.md.
set -euo pipefail

CONF=/etc/postgresql/postgresql.conf

# Confere o /dev/shm real contra o que o perfil precisa e, por default, reduz
# max_parallel_workers_per_gather se não couber — em vez de deixar a primeira
# query paralela pesada morrer com "could not resize shared memory segment".
# Precisa vir ANTES do heredoc, que é onde a variável é consumida.
# Ver shm-guard.sh e docs/troubleshooting.md.
# shellcheck source=shm-guard.sh
. /usr/local/bin/shm-guard.sh

cat > "$CONF" <<EOF
# ARQUIVO GERADO no start do container por generate-config.sh — não editar
# à mão: defina as envs PG_* no deploy (ver README do infra/postgres).

# --- Conexões ---------------------------------------------------------------
listen_addresses = '*'
port = 5432
max_connections = ${PG_MAX_CONNECTIONS:-100}

# --- Memória ----------------------------------------------------------------
shared_buffers = ${PG_SHARED_BUFFERS:-2GB}
effective_cache_size = ${PG_EFFECTIVE_CACHE_SIZE:-6GB}
work_mem = ${PG_WORK_MEM:-16MB}
# work_mem vale por operação de sort/hash; hash_mem_multiplier dá mais folga
# só aos nós de hash, que dominam os filtros avançados sobre tabelas grandes.
hash_mem_multiplier = ${PG_HASH_MEM_MULTIPLIER:-2.0}
maintenance_work_mem = ${PG_MAINTENANCE_WORK_MEM:-512MB}
# -1 faz cada worker de autovacuum herdar maintenance_work_mem. O PG17 removeu
# o teto silencioso de 1 GB do VACUUM, então em perfis com maintenance_work_mem
# de vários GB este valor precisa ser fixado à parte.
autovacuum_work_mem = ${PG_AUTOVACUUM_WORK_MEM:--1}
# só rende se o host reservar hugepages (ver docs/host.md); 'try' cai para
# páginas normais quando não há.
huge_pages = ${PG_HUGE_PAGES:-try}
max_locks_per_transaction = ${PG_MAX_LOCKS_PER_TRANSACTION:-64}

# --- Planner / IO (premissa: NVMe local) -------------------------------------
random_page_cost = ${PG_RANDOM_PAGE_COST:-1.1}
effective_io_concurrency = ${PG_EFFECTIVE_IO_CONCURRENCY:-200}
# default upstream é 10 — estrangula o prefetch de VACUUM/ANALYZE.
maintenance_io_concurrency = ${PG_MAINTENANCE_IO_CONCURRENCY:-200}
# PG17: teto de 256kB (PG_IOV_MAX = 32 blocos). No PG18 é preciso subir
# também io_max_combine_limit, senão este valor é reduzido em silêncio.
io_combine_limit = ${PG_IO_COMBINE_LIMIT:-256kB}
default_statistics_target = ${PG_DEFAULT_STATISTICS_TARGET:-100}
jit = ${PG_JIT:-off}

# --- Paralelismo ------------------------------------------------------------
max_worker_processes = ${PG_MAX_WORKER_PROCESSES:-4}
max_parallel_workers = ${PG_MAX_PARALLEL_WORKERS:-4}
max_parallel_workers_per_gather = ${PG_MAX_PARALLEL_WORKERS_PER_GATHER:-2}
max_parallel_maintenance_workers = ${PG_MAX_PARALLEL_MAINTENANCE_WORKERS:-2}
parallel_setup_cost = ${PG_PARALLEL_SETUP_COST:-1000}
parallel_tuple_cost = ${PG_PARALLEL_TUPLE_COST:-0.1}

# --- WAL / Checkpoints ------------------------------------------------------
max_wal_size = ${PG_MAX_WAL_SIZE:-8GB}
min_wal_size = ${PG_MIN_WAL_SIZE:-2GB}
wal_compression = ${PG_WAL_COMPRESSION:-zstd}
wal_buffers = ${PG_WAL_BUFFERS:-32MB}
# 5min (default) reescreve as mesmas páginas em full-page writes durante
# cargas em massa; 15min corta volume de WAL ao custo de recovery mais longo.
checkpoint_timeout = ${PG_CHECKPOINT_TIMEOUT:-15min}
checkpoint_completion_target = ${PG_CHECKPOINT_COMPLETION_TARGET:-0.9}
# 'off' durante o ETL acelera commits sem risco de corrupção (perde-se apenas
# os últimos commits num crash). Nunca deixar 'off' em regime.
synchronous_commit = ${PG_SYNCHRONOUS_COMMIT:-on}

# --- Backup físico / PITR (pgBackRest — ver backup/) ------------------------
archive_mode = ${PG_ARCHIVE_MODE:-off}
archive_command = '${PG_ARCHIVE_COMMAND:-/bin/true}'
# Força a troca de segmento mesmo sem escrita suficiente para fechar os 16 MB.
# Duas consequências, e as duas são o motivo de o default do overlay de backup
# ser 60s e não 0 (desligado):
#   1. RPO. Sem isto, um banco ocioso pode passar horas com o último commit
#      apenas no segmento corrente, que NÃO está no repositório.
#   2. O alerta. `pg_stat_archiver_last_archive_age > 300s` é a trava que
#      protege o pg_wal (backup/README.md); num banco ocioso com
#      archive_timeout=0 ele dispararia como falso positivo eterno, e um alerta
#      que sempre está vermelho é um alerta desligado.
# O custo é um segmento de 16 MB por intervalo mesmo quase vazio — alguns KB no
# repositório depois da compressão zstd.
archive_timeout = ${PG_ARCHIVE_TIMEOUT:-0}

# --- Autovacuum -------------------------------------------------------------
autovacuum_max_workers = ${PG_AUTOVACUUM_MAX_WORKERS:-3}
autovacuum_naptime = ${PG_AUTOVACUUM_NAPTIME:-30s}
autovacuum_vacuum_scale_factor = ${PG_AUTOVACUUM_VACUUM_SCALE_FACTOR:-0.1}
autovacuum_analyze_scale_factor = ${PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR:-0.05}
# tabelas append-only só ganham visibility map (e index-only scans) via
# vacuum de inserção.
autovacuum_vacuum_insert_scale_factor = ${PG_AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR:-0.1}
autovacuum_vacuum_cost_delay = ${PG_AUTOVACUUM_VACUUM_COST_DELAY:-2ms}
# o default (-1 => 200) limita o autovacuum a ~40 MB/s de páginas sujas — em
# NVMe é o que produz bloat em tabelas de dezenas de milhões de linhas.
autovacuum_vacuum_cost_limit = ${PG_AUTOVACUUM_VACUUM_COST_LIMIT:-1000}

# --- Busca textual (pg_trgm / GIN) -------------------------------------------
# com fastupdate=on a pending list é varrida a cada busca; em carga de leitura
# dominante o certo é fastupdate=off no índice (DDL do projeto de ETL).
gin_pending_list_limit = ${PG_GIN_PENDING_LIST_LIMIT:-4MB}

# --- Timeouts de servidor ---------------------------------------------------
statement_timeout = ${PG_STATEMENT_TIMEOUT:-0}
idle_in_transaction_session_timeout = ${PG_IDLE_IN_TRANSACTION_SESSION_TIMEOUT:-60s}

# --- Diagnóstico ------------------------------------------------------------
shared_preload_libraries = '${PG_SHARED_PRELOAD_LIBRARIES:-pg_stat_statements}'
pg_stat_statements.max = ${PG_STAT_STATEMENTS_MAX:-5000}
# on: sem isso, pg_stat_statements não separa tempo de IO de tempo de CPU;
# custo desprezível em clock sources modernos (verificável com pg_test_timing)
track_io_timing = ${PG_TRACK_IO_TIMING:-on}
log_min_duration_statement = ${PG_LOG_MIN_DURATION_STATEMENT:-2000}
# denuncia derramamento de work_mem — o sinal que decide subir de perfil
log_temp_files = ${PG_LOG_TEMP_FILES:-10MB}
log_lock_waits = ${PG_LOG_LOCK_WAITS:-on}
log_autovacuum_min_duration = ${PG_LOG_AUTOVACUUM_MIN_DURATION:-10s}
log_checkpoints = on
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
# max_parallel_workers_per_gather entra no resumo porque o shm-guard pode
# tê-lo reduzido — sem isso, a degradação passa despercebida.
echo "postgresql.conf gerado (shared_buffers=${PG_SHARED_BUFFERS:-2GB}, effective_cache_size=${PG_EFFECTIVE_CACHE_SIZE:-6GB}, max_parallel_workers=${PG_MAX_PARALLEL_WORKERS:-4}, max_parallel_workers_per_gather=${PG_MAX_PARALLEL_WORKERS_PER_GATHER:-2}, random_page_cost=${PG_RANDOM_PAGE_COST:-1.1})"
