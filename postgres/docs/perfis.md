# Perfis de dimensionamento do PostgreSQL

Perfis da imagem `ghcr.io/brasildatahub/postgres:17`, por **RAM e vCPU** da
máquina. Arquivos em [`postgres/profiles/`](../profiles/); trocar de perfil é
trocar envs no deploy ([receita](deploy.md#receita)). Defaults da imagem =
`dedicada-8gb`.

## Premissas

1. **NVMe local.** Sustenta `random_page_cost=1.1` e `effective_io_concurrency=200+`.
   Se inevitável volume de rede: `PG_RANDOM_PAGE_COST` 1.5–2.0. Disco que importa
   = data-root do Docker (`docker info -f '{{.DockerRootDir}}'`). Ver [host.md](host.md).
2. **Máquina dedicada ao Postgres** (pode coabitar Redis/Meilisearch —
   [coexistência](#coexistência-com-outros-serviços-no-mesmo-host)); nunca a
   aplicação. Produção: vCPU dedicada.
3. **Leitura dominante** (OLTP + busca + analítica ocasional) — ver carga-alvo.
4. **O número no nome é o orçamento de RAM do Postgres**, não a RAM do host.
   Com vizinhos: `RAM_host ≥ orçamento_pg + Σ(limite de container dos vizinhos)`.

## Carga-alvo

Calibrado pelo caso mais exigente (Base Empresarial):

- base >100 GB (~116 GB), 200M+ linhas; `estabelecimento` ~72M; relacionamentos 100M+
- tabela desnormalizada de busca ~10–12 GB
- busca textual (`pg_trgm` + GIN, `unaccent`) + filtros avançados
- ETL mensal reescrevendo tabelas e índices de GB, convivendo com produção

## Tabela-resumo

| Perfil | Orçamento PG | vCPU | shared_buffers | effective_cache_size | work_mem | Paralelismo (workers/gather) | Uso típico |
|---|---|---|---|---|---|---|---|
| `dedicada-8gb` | 8 GB | 2–4 | 2GB | 6GB | 16MB | 4/2 | produção pequena, staging |
| `dedicada-16gb` | 16 GB | 8 | 5GB | 12GB | 32MB | 8/4 | bases de dezenas de GB |
| `dedicada-32gb` | 32 GB | 8–16 | 10GB | 24GB | 48MB | 8/4 | centenas de GB; multi-projeto |
| `dedicada-64gb` | 64 GB | 16 | 24GB | 48GB | 64MB | 16/4 | base grande com busca textual |
| `dedicada-128gb` | 128 GB | 24 | 48GB | 96GB | 96MB | 24/6 | working set inteiro em RAM |
| `compartilhada-14gb` | 14 GB | 12 (**6 efetivas**) | 8GB | 15GB | 96MB | 8/4 | host 31 GiB dividido com motor de busca |

Com Redis/Meilisearch no mesmo host, some o limite deles ([fórmula](#fórmula-de-reserva)).

`compartilhada-14gb` — particularidades:

- `work_mem` 96 MB com `max_connections` **60** (não 100): 100 × 96 MB = 9,6 GB
  não cabe em 14 GiB; 60 × 96 MB = 5,8 GB cabe. Par indivisível com PgBouncer.
- `shared_buffers` 8 GiB só depois de o vizinho sair: 14 + 12 + 2 > 31 GiB.

## Como escolher

Pergunta central: **qual é o working set?**

1. Cabe em `shared_buffers` + page cache? Se for várias vezes a RAM → suba de perfil.
2. Workload misto leitura dominante. Analítica pesada → 32 GB+. OLTP de alta
   concorrência → pooler ([limitações](#limitações-transversais)).
3. Referências: Base Escolar (alguns GB) → `dedicada-8gb`/`16gb`. Base
   Empresarial (116 GB, índices de busca) → `dedicada-64gb`+.

### E se a máquina não tem o tamanho de nenhum perfil?

Catálogo discreto; `--auto` escolhe por faixa com piso:

| Máquina dedicada | Perfil | Limite do container | Fora do limite |
|---|---|---|---|
| 24 GB | `dedicada-16gb` | 14G | ~9 GiB |
| 48 GB | `dedicada-32gb` | 28G | ~19 GiB |
| 96 GB | `dedicada-64gb` | 56G | ~38 GiB |
| 256 GB | `dedicada-128gb` (teto) | 120G | ~131 GiB |

Sobra acima do limite vira **page cache** (útil). `effective_cache_size` fica
dimensionado para a máquina menor — planner pode preferir seq scan. Se incomodar:
[Retrofit](#retrofit-o-host-já-existe).

| Serviço | Memória acima do limite |
|---|---|
| **Postgres** | page cache — sobra útil |
| **OpenSearch** / **Meilisearch** | ativo principal (`mmap`); heap OS fixo 4 GiB |
| **Redis** | ociosa — `maxmemory` é teto; limite ≈ 2× por causa do fork do AOF |

### CPU

`cpus: "0"` (sem teto) em Postgres/Redis/Meilisearch. Exceção: OpenSearch
`OS_CPU_LIMIT=6` (divide host com Postgres). Paralelismo do Postgres segue o
**perfil**, não os núcleos da máquina — ver Retrofit.

## Parâmetros

### Base fixa da imagem

Não entra em bloco de env:

| Parâmetro | Valor |
|---|---|
| `random_page_cost` | 1.1 |
| `io_combine_limit` | 256kB |
| `jit` | off (`SET jit = on` em sessão analítica) |
| `checkpoint_timeout` / `checkpoint_completion_target` | 15min / 0.9 |
| `wal_compression` | zstd |
| `synchronous_commit` | on (`off` só no ETL, consciente) |
| `huge_pages` | try |
| `gin_pending_list_limit` | 4MB |
| `autovacuum_vacuum_cost_delay` | 2ms |
| `statement_timeout` / `idle_in_transaction_session_timeout` | 0 / 60s |
| `max_locks_per_transaction` | 64 |
| `shared_preload_libraries` | pg_stat_statements |
| `track_io_timing` | on |
| `log_min_duration_statement` | 2000 |
| `log_temp_files` | 10MB |
| `log_lock_waits` / `log_checkpoints` | on / on |
| `log_autovacuum_min_duration` | 10s |
| extensões initdb | `pg_trgm`, `unaccent`, `pg_stat_statements`, `btree_gin` |

### Varia por perfil

`✱` = parâmetros dominantes.

#### Conexões

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `MAX_CONNECTIONS` | 100 | 100 | 150 | 200 | 300 | acima disso, pooler |

#### Memória

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `SHARED_BUFFERS` | 2GB | 5GB | 10GB | 24GB | 48GB | 25% no 8gb, ~⅓ nos demais |
| ✱ | `EFFECTIVE_CACHE_SIZE` | 6GB | 12GB | 24GB | 48GB | 96GB | 75% do orçamento |
| ✱ | `WORK_MEM` | 16MB | 32MB | 48MB | 64MB | 96MB | `(orç − sb) ÷ (3 × max_conn)` |
| | `HASH_MEM_MULTIPLIER` | 2.0 | 2.0 | 2.0 | 3.0 | 3.0 | folga só para nós de hash |
| ✱ | `MAINTENANCE_WORK_MEM` | 512MB | 1GB | 2GB | 4GB | 8GB | build de GIN; PG17 usa >1GB |
| | `AUTOVACUUM_WORK_MEM` | -1 | -1 | 512MB | 1GB | 2GB | teto por worker |

#### Planner e IO

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| | `EFFECTIVE_IO_CONCURRENCY` | 200 | 200 | 200 | 300 | 300 | prefetch bitmap scan NVMe |
| | `MAINTENANCE_IO_CONCURRENCY` | 200 | 200 | 200 | 300 | 300 | prefetch VACUUM/ANALYZE |
| | `DEFAULT_STATISTICS_TARGET` | 100 | 100 | 200 | 200 | 200 | histogramas em tabelas grandes |

#### Paralelismo

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `MAX_WORKER_PROCESSES` | 4 | 8 | 8 | 16 | 24 | = nº de vCPU |
| ✱ | `MAX_PARALLEL_WORKERS` | 4 | 8 | 8 | 16 | 24 | = nº de vCPU |
| | `MAX_PARALLEL_WORKERS_PER_GATHER` | 2 | 4 | 4 | 4 | 6 | ≈ vCPU ÷ 4, mín. 2 |
| | `MAX_PARALLEL_MAINTENANCE_WORKERS` | 2 | 2 | 4 | 4 | 6 | ≈ vCPU ÷ 4, mín. 2 |
| | `PARALLEL_SETUP_COST` | 1000 | 1000 | 500 | 500 | 500 | barateia plano paralelo |
| | `PARALLEL_TUPLE_COST` | 0.1 | 0.1 | 0.05 | 0.05 | 0.05 | idem |

#### WAL e checkpoints

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `MAX_WAL_SIZE` | 8GB | 16GB | 32GB | 48GB | 64GB | absorve reescrita do ETL |
| | `MIN_WAL_SIZE` | 2GB | 4GB | 8GB | 8GB | 16GB | segmentos pré-alocados |
| | `WAL_BUFFERS` | 32MB | 32MB | 64MB | 64MB | 64MB | default (-1) trava em 16MB |

#### Autovacuum

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `AUTOVACUUM_VACUUM_COST_LIMIT` | 1000 | 2000 | 4000 | 6000 | 8000 | default 200 é freio de HDD |
| | `AUTOVACUUM_MAX_WORKERS` | 3 | 4 | 4 | 6 | 6 | tabelas gigantes em paralelo |
| | `AUTOVACUUM_NAPTIME` | 30s | 30s | 15s | 15s | 15s | latência até começar |
| | `AUTOVACUUM_VACUUM_SCALE_FACTOR` | 0.1 | 0.1 | 0.05 | 0.02 | 0.02 | % dead tuples |
| | `AUTOVACUUM_ANALYZE_SCALE_FACTOR` | 0.05 | 0.05 | 0.02 | 0.01 | 0.01 | idem estatísticas |
| | `AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR` | 0.1 | 0.1 | 0.1 | 0.05 | 0.05 | visibility map append-only |

#### Diagnóstico

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| | `STAT_STATEMENTS_MAX` | 5000 | 5000 | 10000 | 10000 | 10000 | query IDs distintos |

#### Recursos do container

Viajam **junto** com o bloco `PG_*`:

| | 8gb | 16gb | 32gb | 64gb | 128gb | compart.-14gb |
|---|---|---|---|---|---|---|
| Limite de memória (`PG_MEMORY_LIMIT`) | 7G | 14G | 28G | 56G | 120G | 14G |
| `/dev/shm` | 1 GB | 2 GB | 4 GB | 4 GB | 8 GB | 4 GB |
| em bytes (`PG_SHM_BYTES`) | 1073741824 | 2147483648 | 4294967296 | 4294967296 | 8589934592 | 4294967296 |

Mount `tmpfs` da [receita](deploy.md#receita) só aceita bytes. Sem esses dois
recursos, `pg_settings` parece certo e queries paralelas quebram — ver
[deploy.md](deploy.md).

## Os perfis

Cada `.env` traz `PG_*` + `PG_MEMORY_LIMIT` + `PG_SHM_BYTES`. Acrescente
`POSTGRES_DB`, `POSTGRES_PASSWORD`, `DADOS_READ_PASSWORD`.

| Perfil | Orçamento | vCPU | Container | Quando | Migrar quando |
|---|---|---|---|---|---|
| [`dedicada-8gb`](../profiles/dedicada-8gb.env) | 8 GB | 2–4 | 7G · shm 1 GB | bases ~20–30 GB, working set poucos GB; defaults da imagem | working set >~5 GB ou sorts em disco frequentes |
| [`dedicada-16gb`](../profiles/dedicada-16gb.env) | 16 GB | 8 | 14G · shm 2 GB | bases ~30–80 GB, working set até ~10 GB | analítica vs OLTP ou working set >~10 GB |
| [`dedicada-32gb`](../profiles/dedicada-32gb.env) | 32 GB | 8–16 | 28G · shm 4 GB | bases ~80–300 GB; consolidação multi-projeto | busca trigram dezenas de M linhas ou WS >~20 GB |
| [`dedicada-64gb`](../profiles/dedicada-64gb.env) | 64 GB | 16 | 56G · shm 4 GB | centenas de GB, WS ~30–40 GB; ETL 200M+ + produção | hit ratio cai ou WS >~40 GB |
| [`dedicada-128gb`](../profiles/dedicada-128gb.env) | 128 GB | 24 | 120G · shm 8 GB | working set quente em RAM; consolidação | acima: sharding/réplicas, não mais RAM |

Deltas principais entre perfis (além das tabelas acima):

- **8→16:** sb 2→5GB, ecs 6→12GB, wm 16→32MB, mwm 512MB→1GB, workers 4→8, gather 2→4, wal 8→16GB, cost_limit 1000→2000
- **16→32:** conn 100→150, sb 5→10GB, ecs 12→24GB, wm 32→48MB, mwm 1→2GB, av_wm 512MB, stats 100→200, custos paralelo ↓, wal 16→32GB, av 0.05/0.02 cost 4000
- **32→64:** conn 150→200, sb 10→24GB, ecs 24→48GB, wm 48→64MB, hash_mult 2→3, mwm 2→4GB, av_wm 1GB, IO 200→300, workers 8→16, wal 32→48GB, av 0.02/0.01 insert 0.05 cost 6000
- **64→128:** conn 200→300, sb 24→48GB, ecs 48→96GB, wm 64→96MB, mwm 4→8GB, av_wm 2GB, workers 16→24, gather 4→6, wal 48→64GB

```bash
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/postgres/profiles/dedicada-16gb.env -o .env
```

## Coexistência com outros serviços no mesmo host

### Fórmula de reserva

```
RAM_host ≥ orçamento_pg + Σ(limite de container dos vizinhos)

vCPU_pg  = vCPU_host − 1 (SO/Docker) − 1 (Redis) − MEILI_MAX_INDEXING_THREADS
           ⇒ PG_MAX_WORKER_PROCESSES ≤ vCPU_pg
```

Some o **limite de container**, não `maxmemory` nem `MAX_INDEXING_MEMORY`.
Reserva do SO embutida: limite do container Postgres ≈ **87%** do orçamento.

O [`setup.sh --auto`](../../README.md#como-o---auto-dimensiona-a-máquina) aplica
esta fórmula sozinho.

| Vizinho | Perfil | Limite de container | Pico de CPU |
|---|---|---|---|
| Redis | `cache-256mb` / `512mb` / `1gb` / `2gb` | 512M / 1G / 2G / 3G | 1 vCPU (+1 breve no AOF rewrite) |
| Meilisearch | `busca-512mb` / `1gb` / `4gb` / `16gb` | 512M / 1G / 4G¹ / 16G¹ | `MEILI_MAX_INDEXING_THREADS` (1/1/2/4) |
| Observabilidade² | `metricas-512mb` / `2gb` / `8gb` | ~1,3G / ~3,2G / ~9,7G | picos curtos 1 vCPU (compactação TSDB) |

¹ pico de indexação; em regime ~1,5× o índice quente.

² soma monitoring + exporters (node +128M, postgres +128M, redis +64M). Com
cAdvisor (`COMPOSE_PROFILES=containers`): +~512M. Só com `--metrics`.

> ⚠️ Volume do Prometheus no mesmo NVMe do `PGDATA`: explosão de cardinalidade
> derruba o **banco**. Perfis declaram `PROM_RETENTION_SIZE` além de
> `PROM_RETENTION_TIME`. Acima de `metricas-2gb`, considere disco/máquina
> dedicada para o TSDB.

### Combinações

| Cenário | Perfil PG | Vizinhos (limites) | RAM host mín. | Plano |
|---|---|---|---|---|
| Postgres sozinho | qualquer | — | = orçamento | — |
| Base Escolar consolidada | `dedicada-8gb` | redis 512M + meili 512M | 9 GB | 16 GB |
| + observabilidade | `dedicada-8gb` | acima + metricas ~1,3G | 10,3 GB | 16 GB |
| Projeto médio | `dedicada-16gb` | redis 1G + meili 4G | 21 GB | 32 GB |
| + observabilidade | `dedicada-16gb` | acima + ~1,3G | 22,3 GB | 32 GB |
| Multi-projeto | `dedicada-32gb` | redis 2G + meili 4G | 38 GB | 48–64 GB |
| Base Empresarial — host único | `dedicada-64gb` | redis 1G + meili 16G | 81 GB | 96 GB |
| Base Empresarial — PG isolado | `dedicada-64gb` | Redis/Meili noutra máquina | 64 GB | 64 GB + host pequeno |

Em base >100 GB com busca textual, **separe o Meilisearch**: indexação despeja o
page cache do Postgres.

### Retrofit: o host já existe

Único caso em que valores do perfil mudam. Não interpole — reescale memória e
herde o resto do perfil imediatamente **inferior**:

```
orçamento_pg'        = RAM_host − Σ(limite dos vizinhos)
shared_buffers       = mesma % do perfil × orçamento_pg'
effective_cache_size = 75% × orçamento_pg'
limite do container  = 87% × orçamento_pg'
demais parâmetros    = do perfil imediatamente INFERIOR
```

Errar `effective_cache_size` para cima: planner escolhe index scans que vão ao disco.

### IO e CPU compartilhados

NVMe único disputado por checkpoint, AOF rewrite, indexação Meili e
`pgbackrest` (`process-max` + `zst`). Mitigação: **escalonar janelas**
(reindexação, full backup, ETL).

## Regras e sinais

### Memória

- **`shared_buffers`:** 25% no 8gb; ~⅓ nos demais (leitura dominante + NVMe).
  Teto ~40% / 48GB. *Erro:* hit ratio < 0.99 com disco ocupado; checkpoints com
  `write` longo.
- **`effective_cache_size`:** não aloca; 75% do orçamento. *Erro:* seq scan com
  índice seletivo (baixo) ou index scan ao disco (alto).
- **`work_mem`:** por operação, não por conexão.
  Fórmula: `(orçamento − shared_buffers) ÷ (3 × max_connections)`.
  Preferir `SET work_mem` na sessão. *Erro:* `log_temp_files` frequente.
- **`hash_mem_multiplier`:** 3.0 em 64GB+ → até 3× `work_mem` por nó de hash.
- **`maintenance_work_mem`:** PG17 removeu teto ~1 GB do VACUUM — 4–8 GB passam
  a reduzir passadas de index-vacuum.
- **`autovacuum_work_mem`:** com `-1`, cada worker herda `maintenance_work_mem`.
  Em 32GB+ fixar à parte (ex.: 8GB × 6 workers = 48 GB de pico).

### Planner e IO

- **`random_page_cost = 1.1`:** default 4.0 é de HDD.
- **`effective_io_concurrency`:** 200 (300 nos grandes); retorno decrescente acima.
- **`maintenance_io_concurrency`:** default upstream 10 — estreito demais.
- **`io_combine_limit`:** 256kB = teto PG17 (`PG_IOV_MAX` = 32 × 8kB). PG18 tem
  `io_max_combine_limit` (default 128kB) que limita em silêncio.
- **`default_statistics_target`:** 200 global; colunas enviesadas →
  `ALTER TABLE … SET STATISTICS`.
- **`jit = off`:** piora OLTP; `SET jit = on` em sessão analítica.

### Paralelismo

`max_worker_processes = max_parallel_workers = vCPU`;
`per_gather ≈ vCPU ÷ 4` (mín. 2); `maintenance ≈ vCPU ÷ 4` (mín. 2).

Custos de setup/tuple reduzidos nos perfis grandes. **`CREATE INDEX` paralelo
não vale para GIN no PG17** (só B-tree/BRIN) — acelerar trigram = `maintenance_work_mem`.

*Erro:* `Workers Planned` > `Workers Launched` de forma consistente.

### WAL e checkpoints

- **`max_wal_size`:** reload (SIGHUP); dobrar no ETL sem restart. *Erro:*
  `checkpoints are occurring too frequently`.
- **`checkpoint_timeout = 15min`:** default 5 min multiplica full-page writes.
- **`wal_buffers`:** default `-1` trava em 16 MB; cargas em massa: 32–64 MB.
- **`wal_compression = zstd`.**
- **`synchronous_commit`:** `off` só no ETL; nunca em regime.

### Autovacuum

- **`autovacuum_vacuum_cost_limit`:** maior impacto do catálogo. Default ~40 MB/s
  de páginas sujas. Dividido entre workers ativos.
- Scale factors menores nos grandes: default 20% = 14M dead tuples numa tabela
  de 72M antes do vacuum.
- **`autovacuum_vacuum_insert_scale_factor`:** tabelas append-only nunca
  acumulam dead tuples — sem vacuum o visibility map não atualiza e
  **index-only scans deixam de funcionar**.
- *Erro:* `n_dead_tup` monotônico; `last_autovacuum` antigo.

### Busca textual

- **`gin_pending_list_limit` 4MB:** pending list varrida linearmente a cada busca.
- Bitmap heap scan limitado por `work_mem`; estouro → bitmap **lossy**.
  *Erro:* `EXPLAIN (ANALYZE)` com `Heap Blocks: … lossy=` alto.

Fora do escopo da imagem (DDL no ETL):

- `ALTER INDEX … SET (fastupdate = off)` em GIN de busca
- `SET STATISTICS 1000` em colunas enviesadas
- autovacuum por tabela nas gigantes (`scale_factor = 0.005`, `threshold = 50000`)
- `CREATE STATISTICS` para correlações (UF × município)

## Limitações transversais

- **Conexões:** pool na app; acima de algumas centenas → **PgBouncer**, não subir
  `max_connections`.
- **Huge pages:** só se o host reservar; ganho mensurável com `shared_buffers` ≥ 16GB
  ([host.md](host.md)).
- **`/dev/shm`:** com `dynamic_shared_memory_type=posix`, pico =
  `(workers+1) × work_mem × hash_mem_multiplier × nós de hash`. Default Docker
  64 MB. Mount `tmpfs` da [receita](deploy.md#receita); `PG_SHM_PREFLIGHT`
  ([shm-guard.sh](../shm-guard.sh)). Ver [troubleshooting.md](troubleshooting.md#1-could-not-resize-shared-memory-segment).
- **Restart obrigatório:** `shared_buffers`, `max_connections`,
  `max_worker_processes`, `autovacuum_max_workers`, `wal_buffers`, `huge_pages`,
  `shared_preload_libraries`, `pg_stat_statements.max`,
  `max_locks_per_transaction`. Reload: `max_wal_size`, `work_mem`,
  `random_page_cost`, `effective_cache_size`, scale factors do autovacuum.
- **Réplicas/HA:** fora do escopo; PITR em `backup/`.

## Máquinas equivalentes (atalho)

Priorize: (1) NVMe local, (2) vCPU dedicada em produção, (3) rede privada.
Confirme o catálogo atual do provedor antes de contratar.

| Perfil | Hetzner | Netcup | DigitalOcean | Linode | Vultr |
|---|---|---|---|---|---|
| 8gb | CX32/CPX31 | VPS/RS 1000 | Basic 8GB / g-2vcpu-8gb | Dedicated 8GB | Cloud Compute 8GB |
| 16gb | CPX41; CCX23 | RS 2000 | g-4vcpu-16gb / m-2vcpu-16gb | Dedicated 16GB | Optimized 16GB |
| 32gb | CPX51; CCX33 | RS 4000 | g-8vcpu-32gb / m-4vcpu-32gb | Dedicated 32GB | Optimized 32GB |
| 64gb | CCX43; AX41-NVMe/EX44 | RS 8000 | g-16vcpu-64gb / m-8vcpu-64gb | Dedicated/HM 64GB | Optimized 64GB |
| 128gb | CCX53; AX102/EX101 | — | m-16vcpu-128gb | High Memory 128GB | Bare metal |

CX/CPX, DO Basic, Netcup VPS: ok para perfis pequenos / não críticos. Produção
sustentada: CCX, DO GP/Memory, Linode Dedicated, Netcup RS. Dedicados 64/128 GB:
preferir RAID1 de dois NVMe.

## Validação de um perfil implantado

```sql
SELECT sourceline, name, setting, applied, error
  FROM pg_file_settings
 WHERE NOT applied OR error IS NOT NULL;   -- deve voltar vazio
```

```bash
psql -U postgres -d <database> -c "
  SELECT name, setting, unit FROM pg_settings WHERE name IN
  ('shared_buffers','effective_cache_size','work_mem','hash_mem_multiplier',
   'maintenance_work_mem','autovacuum_work_mem','random_page_cost',
   'effective_io_concurrency','maintenance_io_concurrency','io_combine_limit',
   'max_parallel_workers','max_parallel_workers_per_gather','max_wal_size',
   'checkpoint_timeout','autovacuum_vacuum_cost_limit',
   'autovacuum_vacuum_scale_factor','autovacuum_vacuum_insert_scale_factor',
   'track_io_timing','shared_preload_libraries','jit') ORDER BY name;"
```

Após tráfego estável:

```sql
-- Cache hit ratio (alvo: > 0.99)
SELECT sum(blks_hit)::float / nullif(sum(blks_hit) + sum(blks_read), 0)
  FROM pg_stat_database;

-- Queries dominadas por IO (track_io_timing=on)
SELECT query, total_exec_time, shared_blk_read_time
  FROM pg_stat_statements ORDER BY shared_blk_read_time DESC LIMIT 10;

-- Autovacuum acompanhando?
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup, 0), 4) AS ratio,
       last_autovacuum
  FROM pg_stat_user_tables
 WHERE n_dead_tup > 100000
 ORDER BY n_dead_tup DESC LIMIT 10;
```
