# postgres

## Papel

PostgreSQL padrão dos projetos BrasilDataHub (`ghcr.io/brasildatahub/postgres:17`). Imagem única: `postgresql.conf` gerado no start a partir de envs `PG_*`; defaults = perfil `dedicada-8gb`. Retunar é trocar envs — sem rebuild.

Base fixa da imagem: `shared_preload_libraries=pg_stat_statements`, `track_io_timing=on`, `random_page_cost=1.1` (NVMe), `io_combine_limit=256kB`, `jit=off`, `wal_compression=zstd`, `checkpoint_timeout=15min`, `checkpoint_completion_target=0.9`, logs de queries lentas / temp files / locks / autovacuum. Initdb (só volume vazio): extensões `pg_trgm`, `unaccent`, `pg_stat_statements`, `btree_gin` + role `dados_read` (timeouts 15 s/60 s; senha `DADOS_READ_PASSWORD`).

## Componentes / imagem

- Imagem: `ghcr.io/brasildatahub/postgres:17`
- Compose: [`docker-compose.yml`](docker-compose.yml), local [`docker-compose.local.yml`](docker-compose.local.yml)
- Overlay métricas: [`docker-compose.metrics.yml`](docker-compose.metrics.yml)
- Guarda `/dev/shm`: [`shm-guard.sh`](shm-guard.sh)
- Volume: `bdh_pg_data`
- Backup: [`backup/`](backup/)

## Perfis e configuração

| Perfil | Orçamento de RAM do Postgres | vCPU | Uso típico |
|---|---|---|---|
| `dedicada-8gb` | 8 GB | 2–4 | produção pequena, staging |
| `dedicada-16gb` | 16 GB | 8 | dezenas de GB |
| `dedicada-32gb` | 32 GB | 8–16 | centenas de GB; multi-projeto |
| `dedicada-64gb` | 64 GB | 16 | base grande com busca textual |
| `dedicada-128gb` | 128 GB | 24 | working set em RAM |

Perfis assumem NVMe local e máquina dedicada. O número no nome é o orçamento do Postgres, não a RAM do host. Arquivos em [`profiles/`](profiles/). Cada perfil inclui `PG_MEMORY_LIMIT` e `PG_SHM_BYTES`.

Guia completo: [docs/perfis.md](docs/perfis.md). Host: [docs/host.md](docs/host.md). Disco: [docs/armazenamento.md](docs/armazenamento.md). Deploy: [docs/deploy.md](docs/deploy.md).

## Deploy / operação

Docker Compose no host ([deploy](docs/deploy.md)). Painel só em modo Compose stack — nunca banco gerenciado.

1. Escolher perfil ([como escolher](docs/perfis.md#como-escolher)); coexistência: [fórmula](docs/perfis.md#fórmula-de-reserva).
2. Preparar host ([docs/host.md](docs/host.md)): `fio`/`pg_test_fsync`, sysctl, THP off, data-root no NVMe.
3. Copiar compose + `.env` (bloco `PG_*`, senhas, `PG_SHM_BYTES`, `PG_MEMORY_LIMIT`) → `docker compose up -d`.
4. Volume vazio → initdb.
5. [Verificação pós-deploy](docs/deploy.md#verificação-pós-deploy).
6. Backups: snapshot do provedor + pgBackRest (`PG_ARCHIVE_MODE=on`) — [`backup/`](backup/).

Métricas (não recria o Postgres; CI compara definição com/sem overlay):

```bash
docker compose -f docker-compose.yml -f docker-compose.metrics.yml up -d
```

Pré-requisitos (`setup.sh --metrics-only`): role `metrics_read` ([`initdb/03-role-metrics.sh`](initdb/03-role-metrics.sh)); senha em `.env.metrics` (não no `.env`). Coletores: `stat_user_tables` e `stat_statements` desligados; `stat_checkpointer` ligado. Detalhe: [docs/metricas.md](docs/metricas.md).

Validação local:

```bash
docker compose -f docker-compose.local.yml up --build -d

PG_SHARED_BUFFERS=512MB PG_EFFECTIVE_CACHE_SIZE=1GB PG_MAX_WAL_SIZE=2GB \
PG_MAX_PARALLEL_WORKERS=16 PG_AUTOVACUUM_VACUUM_COST_LIMIT=6000 \
    docker compose -f docker-compose.local.yml up --build -d

docker compose -f docker-compose.local.yml exec postgres \
    psql -U postgres -d dados_cnpj -c \
    "SELECT sourceline, name, setting, applied, error FROM pg_file_settings
      WHERE NOT applied OR error IS NOT NULL;"

docker compose -f docker-compose.local.yml exec postgres \
    psql -U postgres -d dados_cnpj \
    -c "SELECT name, setting FROM pg_settings WHERE name IN
        ('shared_buffers','effective_cache_size','random_page_cost',
         'io_combine_limit','max_parallel_workers','autovacuum_vacuum_cost_limit',
         'shared_preload_libraries','jit','track_io_timing');"
```

Imagens GHCR públicas (pull sem auth); repositório privado.

## Variáveis e segredos

Defaults = `dedicada-8gb`. Valores por perfil em [docs/perfis.md](docs/perfis.md).

### Conexões

| Env | Default | O que controla |
|---|---|---|
| `PG_MAX_CONNECTIONS` | `100` | conexões simultâneas |

### Memória

| Env | Default | O que controla |
|---|---|---|
| `PG_SHARED_BUFFERS` | `2GB` | cache de páginas |
| `PG_EFFECTIVE_CACHE_SIZE` | `6GB` | estimativa para o planner |
| `PG_WORK_MEM` | `16MB` | sort/hash |
| `PG_HASH_MEM_MULTIPLIER` | `2.0` | multiplicador de `work_mem` em hash |
| `PG_MAINTENANCE_WORK_MEM` | `512MB` | VACUUM/CREATE INDEX |
| `PG_AUTOVACUUM_WORK_MEM` | `-1` | herda o acima se `-1` |
| `PG_HUGE_PAGES` | `try` | |
| `PG_MAX_LOCKS_PER_TRANSACTION` | `64` | |

### Planner e IO

| Env | Default | O que controla |
|---|---|---|
| `PG_RANDOM_PAGE_COST` | `1.1` | NVMe local |
| `PG_EFFECTIVE_IO_CONCURRENCY` | `200` | |
| `PG_MAINTENANCE_IO_CONCURRENCY` | `200` | |
| `PG_IO_COMBINE_LIMIT` | `256kB` | teto PG17 |
| `PG_DEFAULT_STATISTICS_TARGET` | `100` | |
| `PG_JIT` | `off` | |

### Paralelismo

| Env | Default | O que controla |
|---|---|---|
| `PG_MAX_WORKER_PROCESSES` | `4` | |
| `PG_MAX_PARALLEL_WORKERS` | `4` | |
| `PG_MAX_PARALLEL_WORKERS_PER_GATHER` | `2` | |
| `PG_MAX_PARALLEL_MAINTENANCE_WORKERS` | `2` | |
| `PG_PARALLEL_SETUP_COST` | `1000` | |
| `PG_PARALLEL_TUPLE_COST` | `0.1` | |

### Guarda `/dev/shm`

Hash tables de Parallel Hash Join usam `/dev/shm` (default container: 64 MB).

| Env | Default | O que controla |
|---|---|---|
| `PG_SHM_PREFLIGHT` | `adapt` | `adapt` / `fail` / `warn` / `off` |
| `PG_SHM_HASH_NODES` | `2` | nós de hash no cálculo do pico |
| `PG_SHM_BYTES` | via perfil | tamanho do shm do container |

### WAL e checkpoints

| Env | Default | O que controla |
|---|---|---|
| `PG_MAX_WAL_SIZE` / `PG_MIN_WAL_SIZE` | `8GB` / `2GB` | |
| `PG_WAL_BUFFERS` | `32MB` | |
| `PG_WAL_COMPRESSION` | `zstd` | |
| `PG_CHECKPOINT_TIMEOUT` | `15min` | |
| `PG_CHECKPOINT_COMPLETION_TARGET` | `0.9` | |
| `PG_SYNCHRONOUS_COMMIT` | `on` | `off` só no ETL |

### Autovacuum

| Env | Default | O que controla |
|---|---|---|
| `PG_AUTOVACUUM_VACUUM_COST_LIMIT` | `1000` | |
| `PG_AUTOVACUUM_VACUUM_COST_DELAY` | `2ms` | |
| `PG_AUTOVACUUM_MAX_WORKERS` | `3` | |
| `PG_AUTOVACUUM_NAPTIME` | `30s` | |
| `PG_AUTOVACUUM_VACUUM_SCALE_FACTOR` | `0.1` | |
| `PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR` | `0.05` | |
| `PG_AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR` | `0.1` | |

### Busca textual, timeouts e diagnóstico

| Env | Default | O que controla |
|---|---|---|
| `PG_GIN_PENDING_LIST_LIMIT` | `4MB` | |
| `PG_STATEMENT_TIMEOUT` | `0` | |
| `PG_IDLE_IN_TRANSACTION_SESSION_TIMEOUT` | `60s` | |
| `PG_SHARED_PRELOAD_LIBRARIES` | `pg_stat_statements` | |
| `PG_STAT_STATEMENTS_MAX` | `5000` | |
| `PG_TRACK_IO_TIMING` | `on` | |
| `PG_LOG_MIN_DURATION_STATEMENT` | `2000` | |
| `PG_LOG_TEMP_FILES` | `10MB` | |
| `PG_LOG_LOCK_WAITS` | `on` | |
| `PG_LOG_AUTOVACUUM_MIN_DURATION` | `10s` | |

### Backup físico

| Env | Default | O que controla |
|---|---|---|
| `PG_ARCHIVE_MODE` / `PG_ARCHIVE_COMMAND` | `off` / `/bin/true` | WAL archiving — [`backup/`](backup/) |

Segredos: `POSTGRES_PASSWORD`, `DADOS_READ_PASSWORD`; métricas em `.env.metrics`.

## Restrições

- Initdb só na primeira subida (volume vazio).
- Variáveis extras no `.env` (ex. senha de métricas) recriam o container do banco.
- Overlay de backup **recria** o Postgres (`archive_mode` exige restart); overlay de métricas não.
- `/dev/shm` insuficiente quebra Parallel Hash Join no meio da query — usar `PG_SHM_BYTES` do perfil.

## Links

- [docs/perfis.md](docs/perfis.md)
- [docs/host.md](docs/host.md)
- [docs/deploy.md](docs/deploy.md)
- [docs/armazenamento.md](docs/armazenamento.md)
- [docs/troubleshooting.md](docs/troubleshooting.md)
- [docs/metricas.md](docs/metricas.md)
- [`backup/README.md`](backup/README.md)
