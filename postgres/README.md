# postgres

`ghcr.io/brasildatahub/postgres:17` — o PostgreSQL padrão dos projetos
BrasilDataHub (baseempresarial, baseescolar, basehospitalar, ...).

É uma **imagem única**: o `postgresql.conf` é gerado no start do container a
partir de variáveis de ambiente `PG_*`, cujos defaults equivalem ao perfil
`dedicada-8gb` — subir sem env nenhuma produz exatamente esse perfil. Retunar
para outra máquina é só trocar envs no deploy — nenhum rebuild, nenhuma
variação de imagem.

Base fixa da imagem (igual em qualquer perfil):
`shared_preload_libraries=pg_stat_statements`, `track_io_timing=on`,
`random_page_cost=1.1` (NVMe local), `io_combine_limit=256kB`, `jit=off`,
`wal_compression=zstd`, `checkpoint_timeout=15min`,
`checkpoint_completion_target=0.9`, logs de queries lentas, de arquivos
temporários, de locks e de autovacuum, e initdb com extensões (`pg_trgm`,
`unaccent`, `pg_stat_statements`, `btree_gin`) + role de leitura `dados_read`
(timeouts de servidor 15 s/60 s, senha via env `DADOS_READ_PASSWORD`). O initdb
roda **apenas** na primeira inicialização (volume vazio); para bancos
existentes, use o script de higiene do repositório de ETL do projeto.

## Perfis de dimensionamento

Os perfis são definidos por **características da máquina** (RAM, vCPUs),
independentes de fornecedor, e servem a todos os projetos da org. Cada perfil é
um **arquivo `.env` versionado** em [`profiles/`](profiles/), pronto para copiar
para o lado do compose — a mesma fonte que o script de setup usa.

| Perfil | Orçamento de RAM do Postgres | vCPU | Uso típico |
|---|---|---|---|
| `dedicada-8gb` | 8 GB | 2–4 | produção pequena (ex.: Base Escolar), staging |
| `dedicada-16gb` | 16 GB | 8 | bases de dezenas de GB |
| `dedicada-32gb` | 32 GB | 8–16 | centenas de GB; consolidação multi-projeto |
| `dedicada-64gb` | 64 GB | 16 | base grande com busca textual (Base Empresarial) |
| `dedicada-128gb` | 128 GB | 24 | working set inteiro em RAM |

Todos os perfis assumem **NVMe local** e a máquina dedicada ao Postgres. O
número no nome é o **orçamento de RAM do Postgres**, não a RAM do host: se o
host também rodar Redis ou Meilisearch, some os limites de container deles
([fórmula](docs/perfis.md#fórmula-de-reserva)).

**Guia completo — arquivo de cada perfil, carga-alvo,
justificativa de cada parâmetro, coexistência com outros serviços, limitações,
quando migrar e máquinas equivalentes por provedor:
[docs/perfis.md](docs/perfis.md).** Preparação do host (disco, kernel, huge
pages, filesystem): [docs/host.md](docs/host.md).

> ⚠️ **Um perfil não é só tuning do Postgres.** Ele inclui o limite de memória e
> o `/dev/shm`, que são recursos do container — por isso os dois vêm junto no
> arquivo do perfil (`PG_MEMORY_LIMIT` e `PG_SHM_BYTES`), e é aí que um perfil
> costuma se perder pela metade. A receita única (Compose ou painel) está em
> **[docs/deploy.md](docs/deploy.md)**; quando algo der errado,
> **[docs/troubleshooting.md](docs/troubleshooting.md)**.

## Variáveis de tuning

Os valores por perfil estão em [docs/perfis.md](docs/perfis.md); o default de
cada env abaixo é o valor do perfil `dedicada-8gb`.

### Conexões

| Env | Default | O que controla |
|---|---|---|
| `PG_MAX_CONNECTIONS` | `100` | conexões simultâneas |

### Memória

| Env | Default | O que controla |
|---|---|---|
| `PG_SHARED_BUFFERS` | `2GB` | cache de páginas do Postgres |
| `PG_EFFECTIVE_CACHE_SIZE` | `6GB` | estimativa de cache total (informa o planner) |
| `PG_WORK_MEM` | `16MB` | memória por operação de sort/hash |
| `PG_HASH_MEM_MULTIPLIER` | `2.0` | multiplicador de `work_mem` só para nós de hash |
| `PG_MAINTENANCE_WORK_MEM` | `512MB` | memória p/ VACUUM/CREATE INDEX |
| `PG_AUTOVACUUM_WORK_MEM` | `-1` | teto por worker de autovacuum (`-1` herda o acima) |
| `PG_HUGE_PAGES` | `try` | huge pages (só rende se o host reservar) |
| `PG_MAX_LOCKS_PER_TRANSACTION` | `64` | subir só com esquema particionado |

### Planner e IO

| Env | Default | O que controla |
|---|---|---|
| `PG_RANDOM_PAGE_COST` | `1.1` | custo de leitura aleatória (NVMe local) |
| `PG_EFFECTIVE_IO_CONCURRENCY` | `200` | prefetch de bitmap heap scan |
| `PG_MAINTENANCE_IO_CONCURRENCY` | `200` | prefetch de VACUUM/ANALYZE |
| `PG_IO_COMBINE_LIMIT` | `256kB` | tamanho máximo de IO combinado (teto do PG17) |
| `PG_DEFAULT_STATISTICS_TARGET` | `100` | granularidade das estatísticas do planner |
| `PG_JIT` | `off` | JIT (`on` só para sessões analíticas) |

### Paralelismo

| Env | Default | O que controla |
|---|---|---|
| `PG_MAX_WORKER_PROCESSES` | `4` | teto global de workers |
| `PG_MAX_PARALLEL_WORKERS` | `4` | workers paralelos de query |
| `PG_MAX_PARALLEL_WORKERS_PER_GATHER` | `2` | paralelismo por query |
| `PG_MAX_PARALLEL_MAINTENANCE_WORKERS` | `2` | paralelismo de manutenção |
| `PG_PARALLEL_SETUP_COST` | `1000` | custo estimado de iniciar workers |
| `PG_PARALLEL_TUPLE_COST` | `0.1` | custo estimado por tupla transferida |

### Guarda de `/dev/shm`

As hash tables de Parallel Hash Join vivem em `/dev/shm`, que em container tem
**64 MB** por default. No start, [`shm-guard.sh`](shm-guard.sh) compara o
`/dev/shm` real com o pico que o perfil exige e age antes que uma query quebre
no meio — rede de segurança, não substituto da
[receita de deploy](docs/deploy.md#a-receita).

| Env | Default | O que controla |
|---|---|---|
| `PG_SHM_PREFLIGHT` | `adapt` | `adapt` reduz o paralelismo até caber; `fail` aborta o start; `warn` só avisa; `off` desliga a checagem |
| `PG_SHM_HASH_NODES` | `2` | nós de hash simultâneos assumidos no cálculo do pico |

### WAL e checkpoints

| Env | Default | O que controla |
|---|---|---|
| `PG_MAX_WAL_SIZE` / `PG_MIN_WAL_SIZE` | `8GB` / `2GB` | espaçamento de checkpoints |
| `PG_WAL_BUFFERS` | `32MB` | buffer de WAL |
| `PG_WAL_COMPRESSION` | `zstd` | compressão de WAL |
| `PG_CHECKPOINT_TIMEOUT` | `15min` | intervalo entre checkpoints |
| `PG_CHECKPOINT_COMPLETION_TARGET` | `0.9` | espalhamento da escrita do checkpoint |
| `PG_SYNCHRONOUS_COMMIT` | `on` | `off` só durante o ETL, conscientemente |

### Autovacuum

| Env | Default | O que controla |
|---|---|---|
| `PG_AUTOVACUUM_VACUUM_COST_LIMIT` | `1000` | orçamento de IO do autovacuum (default do PG é 200) |
| `PG_AUTOVACUUM_VACUUM_COST_DELAY` | `2ms` | pausa entre lotes |
| `PG_AUTOVACUUM_MAX_WORKERS` | `3` | workers simultâneos |
| `PG_AUTOVACUUM_NAPTIME` | `30s` | intervalo entre rodadas do launcher |
| `PG_AUTOVACUUM_VACUUM_SCALE_FACTOR` | `0.1` | agressividade do autovacuum |
| `PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR` | `0.05` | agressividade do auto-analyze |
| `PG_AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR` | `0.1` | vacuum de tabelas append-only |

### Busca textual, timeouts e diagnóstico

| Env | Default | O que controla |
|---|---|---|
| `PG_GIN_PENDING_LIST_LIMIT` | `4MB` | pending list dos índices GIN com `fastupdate` |
| `PG_STATEMENT_TIMEOUT` | `0` | teto de duração de query (desligado) |
| `PG_IDLE_IN_TRANSACTION_SESSION_TIMEOUT` | `60s` | mata transação ociosa |
| `PG_SHARED_PRELOAD_LIBRARIES` | `pg_stat_statements` | bibliotecas pré-carregadas |
| `PG_STAT_STATEMENTS_MAX` | `5000` | queries distintas rastreadas |
| `PG_TRACK_IO_TIMING` | `on` | tempos de IO em pg_stat_statements/EXPLAIN |
| `PG_LOG_MIN_DURATION_STATEMENT` | `2000` | loga queries acima de N ms |
| `PG_LOG_TEMP_FILES` | `10MB` | loga derramamento de `work_mem` |
| `PG_LOG_LOCK_WAITS` | `on` | loga esperas por lock |
| `PG_LOG_AUTOVACUUM_MIN_DURATION` | `10s` | loga autovacuums demorados |

### Backup físico

| Env | Default | O que controla |
|---|---|---|
| `PG_ARCHIVE_MODE` / `PG_ARCHIVE_COMMAND` | `off` / `/bin/true` | WAL archiving (pgBackRest — ver `backup/`) |

## Implantação

**Docker Compose direto no host** é a forma recomendada
([por quê](docs/estrategia-deploy.md)); se um painel for obrigatório, use-o em
modo Compose stack com o mesmo YAML — nunca em modo banco gerenciado
([docs/deploy.md](docs/deploy.md#se-for-obrigatório-usar-dokploy-ou-coolify)).
Todos os perfis são de máquina dedicada com NVMe local.

1. Escolher o perfil pelo working set
   ([como escolher](docs/perfis.md#como-escolher)). Se o host for compartilhar
   com Redis/Meilisearch, dimensionar a máquina pela
   [fórmula de reserva](docs/perfis.md#fórmula-de-reserva).
2. **Preparar o host antes de instalar** ([docs/host.md](docs/host.md)):
   validar o disco com `fio`/`pg_test_fsync`, aplicar os sysctl, desligar THP e
   confirmar que o data-root do Docker está no NVMe — é onde o volume nomeado
   vive.
3. Copiar o [compose de produção](docker-compose.yml) e preencher o `.env`:
   bloco `PG_*` do perfil ([docs/perfis.md](docs/perfis.md)), senhas,
   `PG_SHM_BYTES` e `PG_MEMORY_LIMIT` da
   [tabela de recursos](docs/perfis.md#recursos-do-container). `docker compose up -d`.
   Os dados ficam no volume `bdh_pg_data`; nada a criar antes.
4. Primeira subida em volume vazio executa o initdb (extensões + role).
5. Rodar a **[verificação pós-deploy](docs/deploy.md#verificação-pós-deploy)** —
   quatro comandos que separam um perfil aplicado de um aplicado pela metade.
6. Ativar backups: snapshot do provedor + pgBackRest com `PG_ARCHIVE_MODE=on` e
   `PG_ARCHIVE_COMMAND` (ver [`backup/`](backup/)).

## Métricas

[`docker-compose.metrics.yml`](docker-compose.metrics.yml) é um overlay
**opcional** que acrescenta o `postgres_exporter` ao mesmo projeto Compose:

```bash
docker compose -f docker-compose.yml -f docker-compose.metrics.yml up -d
```

O serviço `postgres` **não é tocado** — há um teste na CI que compara a definição
com e sem o overlay e falha se algo mudar. Ligar métricas não pode recriar um
container de banco de centenas de GB.

Dois pré-requisitos, ambos automatizados por `setup.sh --metrics-only`:

1. a role `metrics_read` (`pg_monitor`, sem acesso a dados) —
   [`initdb/03-role-metrics.sh`](initdb/03-role-metrics.sh) roda no `initdb` numa
   instalação nova, e via `docker exec` num cluster que já existe;
2. a senha em `.env.metrics` (e **não** no `.env`: qualquer variável a mais no
   `.env` recria o container do banco).

Vários coletores estão desligados de propósito — `stat_user_tables` e
`stat_statements` são bombas de cardinalidade neste perfil de carga —, e outros
que vêm desligados por default estão ligados, como o `stat_checkpointer`, sem o
qual o efeito do `checkpoint_timeout` dos perfis é invisível no PG17.

O detalhe de cada decisão, o custo medido e o troubleshooting estão em
[docs/metricas.md](docs/metricas.md).

## Validação local

```bash
# Defaults (= perfil dedicada-8gb):
docker compose -f docker-compose.local.yml up --build -d

# Um perfil maior "em miniatura" (memória reduzida, resto igual):
PG_SHARED_BUFFERS=512MB PG_EFFECTIVE_CACHE_SIZE=1GB PG_MAX_WAL_SIZE=2GB \
PG_MAX_PARALLEL_WORKERS=16 PG_AUTOVACUUM_VACUUM_COST_LIMIT=6000 \
    docker compose -f docker-compose.local.yml up --build -d

# Nenhuma entrada inválida ou ignorada na conf gerada:
docker compose -f docker-compose.local.yml exec postgres \
    psql -U postgres -d dados_cnpj -c \
    "SELECT sourceline, name, setting, applied, error FROM pg_file_settings
      WHERE NOT applied OR error IS NOT NULL;"

# Valores efetivos:
docker compose -f docker-compose.local.yml exec postgres \
    psql -U postgres -d dados_cnpj \
    -c "SELECT name, setting FROM pg_settings WHERE name IN
        ('shared_buffers','effective_cache_size','random_page_cost',
         'io_combine_limit','max_parallel_workers','autovacuum_vacuum_cost_limit',
         'shared_preload_libraries','jit','track_io_timing');"
```

> As imagens do GHCR são públicas (pull sem autenticação); o repositório
> permanece privado.
