# Perfis de dimensionamento do PostgreSQL

Guia dos perfis de configuração da imagem `ghcr.io/brasildatahub/postgres:17`.
Os perfis servem a **todos os projetos da organização** — Base Empresarial
(~116 GB, 200M+ linhas), Base Escolar (~170 mil escolas do Censo Escolar,
alguns GB) e Base Hospitalar — e a projetos futuros. Por isso são definidos
por **características da máquina** (RAM, vCPUs), nunca por um fornecedor
específico.

- [Premissas do catálogo](#premissas-do-catálogo)
- [Carga-alvo](#carga-alvo)
- [Tabela-resumo](#tabela-resumo)
- [Como escolher](#como-escolher)
- [Parâmetros](#parâmetros)
- [Os perfis](#os-perfis)
- [Coexistência com outros serviços no mesmo host](#coexistência-com-outros-serviços-no-mesmo-host)
- [Justificativas](#justificativas)
- [Limitações transversais](#limitações-transversais)
- [Máquinas equivalentes por provedor](#máquinas-equivalentes-por-provedor)
- [Validação de um perfil implantado](#validação-de-um-perfil-implantado)

## Premissas do catálogo

A imagem é **única**: o `postgresql.conf` é gerado no start do container a
partir de envs `PG_*` (ver `generate-config.sh`). Trocar de perfil é trocar
envs no deploy — nenhum rebuild. Cada perfil é um **arquivo `.env` versionado**
em [`postgres/profiles/`](../profiles/), que você copia para o lado do compose
([receita](deploy.md#a-receita)). O mesmo arquivo é o que o
[`setup.sh`](../../README.md#setup-automatizado-de-vps) baixa — este guia
explica os valores, não os duplica.

Quatro premissas valem para **todos** os perfis, sem exceção:

1. **Armazenamento NVMe local.** Não há perfil para volume de rede. É o que
   sustenta `random_page_cost=1.1` e `effective_io_concurrency=200+`; block
   storage de rede tem latência de ms e IOPS por cota, e transforma busca
   textual em base grande num problema de IO que nenhum tuning resolve. Se for
   inevitável, suba `PG_RANDOM_PAGE_COST` para 1.5–2.0 e trate os números deste
   guia como otimistas. Como os dados vivem num volume nomeado, o disco que
   importa é o do **data-root do Docker** — confirme com
   `docker info -f '{{.DockerRootDir}}'`. Requisitos e pré-voo:
   [host.md](host.md).
2. **Máquina dedicada ao Postgres.** A máquina pode hospedar outros containers
   de infraestrutura da org (Redis, Meilisearch) — ver
   [Coexistência](#coexistência-com-outros-serviços-no-mesmo-host) —, mas nunca
   dividir a CPU com a aplicação ou com vizinhos de outro cliente. Em produção,
   vCPU dedicada, não burstable.
3. **Carga com leitura dominante** (web/OLTP + busca + analítica ocasional),
   descrita em [Carga-alvo](#carga-alvo).
4. **O número no nome do perfil é o orçamento de RAM do Postgres, não a RAM do
   host.** Sem vizinhos os dois coincidem. Com vizinhos, cresce o host — o
   perfil não muda: `RAM_host ≥ orçamento_pg + Σ(limite de container dos vizinhos)`.

Tudo o que não está no bloco de um perfil usa os defaults da imagem, que são
**exatamente o perfil `dedicada-8gb`** — o menor do catálogo. Subir o container
sem env nenhuma produz esse perfil.

## Carga-alvo

Os valores deste catálogo são calibrados para o padrão dos projetos da org, cuja
expressão mais exigente é a Base Empresarial:

- base de **mais de 100 GB** (~116 GB) e 200M+ linhas no total;
- `estabelecimento` com ~**72M linhas**; tabelas de relacionamento entre
  empresas e atividades econômicas com **100M+ linhas**; mesmo as menores têm
  dezenas de milhões;
- tabela desnormalizada de busca de ~10–12 GB;
- website com **busca textual** (`pg_trgm` + GIN, `unaccent`) e **filtros
  avançados** — leitura intensiva, consultas complexas, muitas combinações
  distintas de predicado;
- **carga mensal (ETL)** que reescreve tabelas inteiras e recria índices de GB,
  convivendo com o tráfego de produção.

Isso orienta as escolhas: cache grande e planner que confia em index scan;
paralelismo generoso; WAL e checkpoints dimensionados para reescrita em massa;
autovacuum agressivo o bastante para tabelas de dezenas de milhões de linhas.

## Tabela-resumo

| Perfil | Orçamento PG | vCPU | shared_buffers | effective_cache_size | work_mem | Paralelismo (workers/gather) | Uso típico |
|---|---|---|---|---|---|---|---|
| `dedicada-8gb` | 8 GB | 2–4 | 2GB | 6GB | 16MB | 4/2 | produção pequena (Base Escolar), staging |
| `dedicada-16gb` | 16 GB | 8 | 5GB | 12GB | 32MB | 8/4 | bases de dezenas de GB |
| `dedicada-32gb` | 32 GB | 8–16 | 10GB | 24GB | 48MB | 8/4 | centenas de GB; consolidação multi-projeto |
| `dedicada-64gb` | 64 GB | 16 | 24GB | 48GB | 64MB | 16/4 | base grande com busca textual (Base Empresarial) |
| `dedicada-128gb` | 128 GB | 24 | 48GB | 96GB | 96MB | 24/6 | working set inteiro em RAM |
| `compartilhada-14gb` | 14 GB | 12 (**6 efetivas**) | 8GB | 15GB | 96MB | 8/4 | host de 31 GiB dividido com motor de busca |

Os cinco `dedicada-*` assumem NVMe local e **máquina dedicada**. Se o host
também rodar Redis ou Meilisearch, some o limite de container deles à RAM da
máquina ([fórmula](#fórmula-de-reserva)).

`compartilhada-14gb` é o primeiro perfil que assume o contrário, e o nome é
parte da correção: até 07/2026 a Base Empresarial rodava `dedicada-16gb` num
host que **nunca foi dedicado** — dividido com o Meilisearch (12 GiB) e com o
Redis. O nome errado é o que faz alguém somar os limites e concluir que cabe.

Duas particularidades dele, e as duas são consequência de dividir a máquina:

- **`work_mem` de 96 MB com `max_connections` de 60**, e não 100. É um par
  indivisível com o PgBouncer: 100 × 96 MB = 9,6 GB de pior caso não cabe num
  limite de 14 GiB; 60 × 96 MB = 5,8 GB cabe. Subir um sem o outro é a via
  rápida para o OOM-killer.
- **`shared_buffers` de 8 GiB só depois de o vizinho sair.** Aplicado com o
  Meilisearch ainda no ar, 14 + 12 + 2 já passa dos 31 GiB do host.

## Como escolher

A pergunta central não é "quantos dados eu tenho", e sim **qual é o working
set** — o subconjunto de dados e índices que as consultas tocam com frequência.

1. **O working set cabe em `shared_buffers` + page cache?** Se sim, o perfil
   atende com folga. Se é várias vezes maior que a RAM, as consultas viram IO e
   nenhum tuning compensa — suba de perfil.
2. **Workload.** Todos os perfis assumem carga mista com leitura dominante. Para
   analítica pesada recorrente, os perfis de 32 GB para cima atendem melhor pelo
   paralelismo; para OLTP puro de alta concorrência, considere um pooler (ver
   [Limitações transversais](#limitações-transversais)).
3. **Referências concretas da org.** Base Escolar (~170 mil escolas, alguns GB)
   roda confortavelmente em `dedicada-8gb`/`dedicada-16gb`. Base Empresarial
   (116 GB, índices de busca de dezenas de GB) precisa de `dedicada-64gb` ou
   superior para servir busca textual com working set em RAM.

## Parâmetros

### Base fixa da imagem

Não varia por perfil e **não entra em nenhum bloco de env** — é decisão de
engenharia da org, não de dimensionamento. Sobrescrever é possível, mas deve ser
exceção justificada.

| Parâmetro | Valor | Por quê |
|---|---|---|
| `random_page_cost` | 1.1 | NVMe local é premissa do catálogo ([§](#planner-e-io-1)) |
| `io_combine_limit` | 256kB | teto do PG17; menos round-trips no NVMe |
| `jit` | off | piora OLTP; sessões analíticas usam `SET jit = on` |
| `checkpoint_timeout` / `checkpoint_completion_target` | 15min / 0.9 | menos full-page writes, escrita espalhada |
| `wal_compression` | zstd | corta volume de WAL a custo baixo de CPU |
| `synchronous_commit` | on | `off` só durante o ETL, conscientemente |
| `huge_pages` | try | só rende se o host reservar ([host.md](host.md)) |
| `gin_pending_list_limit` | 4MB | ver [Busca textual](#busca-textual) |
| `autovacuum_vacuum_cost_delay` | 2ms | o controle real é o `cost_limit` |
| `statement_timeout` / `idle_in_transaction_session_timeout` | 0 / 60s | o role `dados_read` tem os seus (15s/60s) |
| `max_locks_per_transaction` | 64 | subir só com esquema particionado |
| `shared_preload_libraries` | pg_stat_statements | diagnóstico |
| `track_io_timing` | on | sem ele não se separa tempo de IO de CPU |
| `log_min_duration_statement` | 2000 | queries lentas |
| `log_temp_files` | 10MB | denuncia derramamento de `work_mem` |
| `log_lock_waits` / `log_checkpoints` | on / on | contenção e ritmo de checkpoint |
| `log_autovacuum_min_duration` | 10s | mostra se o autovacuum acompanha a carga |
| extensões do initdb | `pg_trgm`, `unaccent`, `pg_stat_statements`, `btree_gin` | só na primeira inicialização |

### Varia por perfil

`✱` marca os parâmetros dominantes — os que decidem o comportamento do perfil.

#### Conexões

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `MAX_CONNECTIONS` | 100 | 100 | 150 | 200 | 300 | acima disso, pooler |

#### Memória

Porquês em [Memória](#memória-1).

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `SHARED_BUFFERS` | 2GB | 5GB | 10GB | 24GB | 48GB | 25% no 8gb, ~⅓ nos demais |
| ✱ | `EFFECTIVE_CACHE_SIZE` | 6GB | 12GB | 24GB | 48GB | 96GB | 75% do orçamento |
| ✱ | `WORK_MEM` | 16MB | 32MB | 48MB | 64MB | 96MB | (orç − sb) ÷ (3 × max_conn) |
| | `HASH_MEM_MULTIPLIER` | 2.0 | 2.0 | 2.0 | 3.0 | 3.0 | folga só para nós de hash |
| ✱ | `MAINTENANCE_WORK_MEM` | 512MB | 1GB | 2GB | 4GB | 8GB | build de GIN; PG17 usa >1GB de fato |
| | `AUTOVACUUM_WORK_MEM` | -1 | -1 | 512MB | 1GB | 2GB | teto por worker de autovacuum |

#### Planner e IO

Porquês em [Planner e IO](#planner-e-io-1).

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| | `EFFECTIVE_IO_CONCURRENCY` | 200 | 200 | 200 | 300 | 300 | prefetch de bitmap scan em NVMe |
| | `MAINTENANCE_IO_CONCURRENCY` | 200 | 200 | 200 | 300 | 300 | prefetch de VACUUM/ANALYZE |
| | `DEFAULT_STATISTICS_TARGET` | 100 | 100 | 200 | 200 | 200 | histogramas mais finos em tabelas grandes |

#### Paralelismo

Porquês em [Paralelismo](#paralelismo-1).

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `MAX_WORKER_PROCESSES` | 4 | 8 | 8 | 16 | 24 | = nº de vCPU |
| ✱ | `MAX_PARALLEL_WORKERS` | 4 | 8 | 8 | 16 | 24 | = nº de vCPU |
| | `MAX_PARALLEL_WORKERS_PER_GATHER` | 2 | 4 | 4 | 4 | 6 | ≈ vCPU ÷ 4, mín. 2 |
| | `MAX_PARALLEL_MAINTENANCE_WORKERS` | 2 | 2 | 4 | 4 | 6 | ≈ vCPU ÷ 4, mín. 2 |
| | `PARALLEL_SETUP_COST` | 1000 | 1000 | 500 | 500 | 500 | barateia o plano paralelo |
| | `PARALLEL_TUPLE_COST` | 0.1 | 0.1 | 0.05 | 0.05 | 0.05 | idem |

#### WAL e checkpoints

Porquês em [WAL e checkpoints](#wal-e-checkpoints-1).

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `MAX_WAL_SIZE` | 8GB | 16GB | 32GB | 48GB | 64GB | absorve a reescrita do ETL |
| | `MIN_WAL_SIZE` | 2GB | 4GB | 8GB | 8GB | 16GB | mantém segmentos pré-alocados |
| | `WAL_BUFFERS` | 32MB | 32MB | 64MB | 64MB | 64MB | default (-1) trava em 16MB |

#### Autovacuum

Porquês em [Autovacuum](#autovacuum-1).

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| ✱ | `AUTOVACUUM_VACUUM_COST_LIMIT` | 1000 | 2000 | 4000 | 6000 | 8000 | tira o freio do default (200) |
| | `AUTOVACUUM_MAX_WORKERS` | 3 | 4 | 4 | 6 | 6 | tabelas gigantes em paralelo |
| | `AUTOVACUUM_NAPTIME` | 30s | 30s | 15s | 15s | 15s | latência até o vacuum começar |
| | `AUTOVACUUM_VACUUM_SCALE_FACTOR` | 0.1 | 0.1 | 0.05 | 0.02 | 0.02 | % de dead tuples que dispara |
| | `AUTOVACUUM_ANALYZE_SCALE_FACTOR` | 0.05 | 0.05 | 0.02 | 0.01 | 0.01 | idem para estatísticas |
| | `AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR` | 0.1 | 0.1 | 0.1 | 0.05 | 0.05 | visibility map em tabelas append-only |

#### Diagnóstico

| | Env (`PG_`) | 8gb | 16gb | 32gb | 64gb | 128gb | Regra |
|---|---|---|---|---|---|---|---|
| | `STAT_STATEMENTS_MAX` | 5000 | 5000 | 10000 | 10000 | 10000 | nº de query IDs distintos |

#### Recursos do container

Não são envs do Postgres — são configuração do serviço no deploy, e viajam
**junto** com o bloco: subir `shared_buffers` sem subir o limite aproxima o
OOM-killer.

| | 8gb | 16gb | 32gb | 64gb | 128gb | compart.-14gb |
|---|---|---|---|---|---|---|
| Limite de memória (`PG_MEMORY_LIMIT`) | 7G | 14G | 28G | 56G | 120G | 14G |
| `/dev/shm` | 1 GB | 2 GB | 4 GB | 4 GB | 8 GB | 4 GB |
| em bytes (`PG_SHM_BYTES`)¹ | 1073741824 | 2147483648 | 4294967296 | 4294967296 | 8589934592 | 4294967296 |

¹ o mount `tmpfs` da [receita de deploy](deploy.md#a-receita) só aceita bytes.

> ⚠️ **Estes dois valores são a parte do perfil que mais se perde no caminho** —
> não são envs do Postgres, então copiar o bloco `PG_*` não os leva junto. Um
> perfil aplicado só pelas envs parece correto em `pg_settings` e quebra horas
> depois, na primeira query paralela pesada. Ver **[deploy.md](deploy.md)**.

## Os perfis

### `dedicada-8gb` — produção pequena

| Orçamento PG | vCPU | Disco | Container |
|---|---|---|---|
| 8 GB | 2–4 | NVMe local | 7G · `/dev/shm` 1 GB |

**Objetivo.** O menor perfil de produção séria, e os **defaults da imagem**:
subir o container sem env nenhuma produz exatamente este perfil.

**Quando usar.** Bases de até ~20–30 GB com working set de poucos GB — o caso do
Base Escolar (~170 mil escolas) e do Base Hospitalar no início; staging fiel de
projetos maiores; réplicas de leitura pequenas.

**Cargas adequadas.** OLTP leve/moderado, APIs de consulta, dashboards sobre
bases pequenas. Não é perfil para analítica pesada nem cargas em massa
frequentes.

**Limitações.** `work_mem` apertado penaliza sorts e hashes grandes; sem espaço
para picos de manutenção concorrentes.

**Migrar para 16 GB quando:** o working set passar de ~5 GB (cache hit ratio
abaixo de ~99%), ou sorts derramarem para disco com frequência (`log_temp_files`
já registra isso no log).

**Arquivo do perfil:** [`profiles/dedicada-8gb.env`](../profiles/dedicada-8gb.env) (são os defaults da imagem; o arquivo serve como registro explícito no deploy) — traz o bloco `PG_*` e também o limite de memória e o `/dev/shm` do container.

```bash
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/postgres/profiles/dedicada-8gb.env -o .env
# depois acrescente POSTGRES_DB, POSTGRES_PASSWORD e DADOS_READ_PASSWORD
```

### `dedicada-16gb` — o ponto de entrada confortável

| Orçamento PG | vCPU | Disco | Container |
|---|---|---|---|
| 16 GB | 8 | NVMe local | 14G · `/dev/shm` 2 GB |

**Objetivo.** Folga real de cache e manutenção para bases de dezenas de GB — o
melhor custo-benefício para projetos da org que já têm tráfego.

**Quando usar.** Bases de ~30–80 GB com working set de até ~10 GB; o destino
natural de Base Escolar/Base Hospitalar quando crescerem; consolidação de 2–3
bancos pequenos de projetos distintos.

**Muda em relação ao `dedicada-8gb`:** `shared_buffers` 2→5GB ·
`effective_cache_size` 6→12GB · `work_mem` 16→32MB · `maintenance_work_mem`
512MB→1GB · paralelismo 4→8 workers e gather 2→4 · `max_wal_size` 8→16GB ·
`autovacuum_vacuum_cost_limit` 1000→2000.

**Limitações.** Com 8 vCPU, uma agregação pesada em paralelo ainda compete com o
tráfego.

**Migrar para 32 GB quando:** consultas analíticas recorrentes disputarem CPU
com o OLTP, ou o working set passar de ~10 GB.

**Arquivo do perfil:** [`profiles/dedicada-16gb.env`](../profiles/dedicada-16gb.env) — traz o bloco `PG_*` e também o limite de memória e o `/dev/shm` do container.

```bash
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/postgres/profiles/dedicada-16gb.env -o .env
# depois acrescente POSTGRES_DB, POSTGRES_PASSWORD e DADOS_READ_PASSWORD
```

### `dedicada-32gb` — equilíbrio para crescer

| Orçamento PG | vCPU | Disco | Container |
|---|---|---|---|
| 32 GB | 8–16 | NVMe local | 28G · `/dev/shm` 4 GB |

**Objetivo.** Serve tráfego enquanto roda agregação, e comporta várias bases
médias juntas.

**Quando usar.** Bases de ~80–300 GB com working set de até ~20 GB;
**consolidação multi-projeto** (Base Escolar + Base Hospitalar + futuros no
mesmo servidor, cada um no seu database); a instância única de um projeto médio
em produção.

**Muda em relação ao `dedicada-16gb`:** `max_connections` 100→150 ·
`shared_buffers` 5→10GB · `effective_cache_size` 12→24GB · `work_mem` 32→48MB ·
`maintenance_work_mem` 1→2GB · `autovacuum_work_mem` passa a ser fixado (512MB) ·
`default_statistics_target` 100→200 · custos de paralelismo reduzidos ·
`max_wal_size` 16→32GB · autovacuum mais agressivo (0.05/0.02, cost_limit 4000).

**Limitações.** Para bases do porte do Base Empresarial (índices trigram de
dezenas de GB), o cache ainda é insuficiente — busca textual pesada continuará
tocando disco.

**Migrar para 64 GB quando:** o produto principal depender de busca
textual/trigram sobre dezenas de milhões de linhas, ou o working set agregado
passar de ~20 GB.

**Arquivo do perfil:** [`profiles/dedicada-32gb.env`](../profiles/dedicada-32gb.env) — traz o bloco `PG_*` e também o limite de memória e o `/dev/shm` do container.

```bash
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/postgres/profiles/dedicada-32gb.env -o .env
# depois acrescente POSTGRES_DB, POSTGRES_PASSWORD e DADOS_READ_PASSWORD
```

### `dedicada-64gb` — produção de base grande

| Orçamento PG | vCPU | Disco | Container |
|---|---|---|---|
| 64 GB | 16 | NVMe local | 56G · `/dev/shm` 4 GB |

**Objetivo.** O perfil de produção do **Base Empresarial**: os índices críticos
de busca (GIN trigram, btrees compostos, a tabela desnormalizada de ~10–12 GB)
residentes em RAM.

**Quando usar.** Bases de centenas de GB cujo working set (índices de busca +
tabelas quentes) fica em ~30–40 GB; carga mensal pesada (ETL de 200M+ linhas)
convivendo com produção.

**Muda em relação ao `dedicada-32gb`:** `max_connections` 150→200 ·
`shared_buffers` 10→24GB · `effective_cache_size` 24→48GB · `work_mem` 48→64MB
com `hash_mem_multiplier` 2.0→3.0 · `maintenance_work_mem` 2→4GB ·
`autovacuum_work_mem` 512MB→1GB · IO concurrency 200→300 · paralelismo 8→16
workers · `max_wal_size` 32→48GB · autovacuum 0.02/0.01, insert 0.05, cost_limit
6000.

**Limitações.** Working sets muito acima de ~40 GB (ex.: todos os índices da
base inteira) ainda excedem o cache. Escritas continuam limitadas por WAL/fsync.

**Migrar para 128 GB quando:** o hit ratio cair com o crescimento mensal da
base, ou novas cargas ampliarem o working set além dos ~40 GB.

**Arquivo do perfil:** [`profiles/dedicada-64gb.env`](../profiles/dedicada-64gb.env) — traz o bloco `PG_*` e também o limite de memória e o `/dev/shm` do container.

```bash
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/postgres/profiles/dedicada-64gb.env -o .env
# depois acrescente POSTGRES_DB, POSTGRES_PASSWORD e DADOS_READ_PASSWORD
```

### `dedicada-128gb` — working set inteiro em RAM

| Orçamento PG | vCPU | Disco | Container |
|---|---|---|---|
| 128 GB | 24 | NVMe local | 120G · `/dev/shm` 8 GB |

**Objetivo.** Teto do catálogo: praticamente toda a parte quente de uma base
grande (dados + índices) residente em memória; o disco sai do caminho crítico
das leituras.

**Quando usar.** Base Empresarial com folga para anos de crescimento; servidor
único consolidando uma base grande + projetos menores; cargas analíticas pesadas
sobre a base completa.

**Muda em relação ao `dedicada-64gb`:** `max_connections` 200→300 ·
`shared_buffers` 24→48GB · `effective_cache_size` 48→96GB · `work_mem` 64→96MB ·
`maintenance_work_mem` 4→8GB · `autovacuum_work_mem` 1→2GB · paralelismo 16→24
workers e gather 4→6 · `max_wal_size` 48→64GB.

**Limitações.** Custo; escritas continuam limitadas por WAL/fsync (RAM não
acelera commit); acima disso o caminho é sharding/réplicas, não mais RAM.

**Arquivo do perfil:** [`profiles/dedicada-128gb.env`](../profiles/dedicada-128gb.env) — traz o bloco `PG_*` e também o limite de memória e o `/dev/shm` do container.

```bash
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/postgres/profiles/dedicada-128gb.env -o .env
# depois acrescente POSTGRES_DB, POSTGRES_PASSWORD e DADOS_READ_PASSWORD
```

## Coexistência com outros serviços no mesmo host

A máquina é dedicada ao Postgres no sentido de não dividir CPU com a aplicação,
mas pode hospedar outros containers de infraestrutura da org — Redis
([perfis](../../redis/README.md)) e Meilisearch
([perfis](../../meilisearch/README.md)).

### Fórmula de reserva

```
RAM_host ≥ orçamento_pg + Σ(limite de container dos vizinhos)

vCPU_pg  = vCPU_host − 1 (SO/Docker) − 1 (Redis) − MEILI_MAX_INDEXING_THREADS
           ⇒ PG_MAX_WORKER_PROCESSES ≤ vCPU_pg
```

Some sempre o **limite de container** do vizinho, não o `maxmemory` nem o
`MAX_INDEXING_MEMORY`: é o teto que o kernel pode de fato deixar residente. A
reserva do SO já está embutida no perfil — o limite do container do Postgres é
~87% do orçamento.

> O [`setup.sh`](../../README.md#como-o---auto-dimensiona-a-máquina) aplica
> esta fórmula sozinho: com os perfis em `auto` (o default), ele escolhe os
> vizinhos pela RAM, soma os limites e dimensiona o Postgres com o que sobra. Os
> perfis de vizinho que ele escolhe são os desta tabela, e o resultado de cada
> tamanho de máquina está no README da raiz. Esta seção continua valendo para
> quem monta o deploy à mão ou quer conferir a decisão do script.

| Vizinho | Perfil | Limite de container | Pico de CPU |
|---|---|---|---|
| Redis | `cache-256mb` / `cache-512mb` / `cache-1gb` / `cache-2gb` | 512M / 1G / 2G / 3G | 1 vCPU (single-thread; +1 breve no AOF rewrite) |
| Meilisearch | `busca-512mb` / `busca-1gb` / `busca-4gb` / `busca-16gb` | 512M / 1G / 4G¹ / 16G¹ | `MEILI_MAX_INDEXING_THREADS` (1/1/2/4) |
| Observabilidade² | `metricas-512mb` / `metricas-2gb` / `metricas-8gb` | ~1,3G / ~3,2G / ~9,7G | picos curtos de 1 vCPU na compactação do TSDB |

¹ valor **de pico de indexação**; em regime cai para ~1,5× o índice quente.

² soma de todos os containers de [`monitoring/`](../../monitoring/) mais os
exporters: Prometheus + Grafana + node exporter (+128M) + exporters de Postgres
(+128M) e Redis (+64M). Com o cAdvisor ligado (`COMPOSE_PROFILES=containers`),
some mais ~512M. A monitoração é **opcional** e só existe com `--metrics`.

> ⚠️ O volume do Prometheus fica no mesmo NVMe do `PGDATA`. Uma explosão de
> cardinalidade nas métricas enche o disco e derruba o **banco**, não o
> Prometheus — é o pior modo de falha dessa combinação. Por isso os perfis de
> métricas sempre declaram `PROM_RETENTION_SIZE` além de `PROM_RETENTION_TIME`,
> e o `bdh metrics` mostra as séries por job. Acima de `metricas-2gb`, considere
> disco ou máquina dedicada para o TSDB.

### Combinações prováveis

| Cenário | Perfil PG | Vizinhos (limites) | RAM host mínima | Plano a contratar |
|---|---|---|---|---|
| Postgres sozinho *(caso base)* | qualquer | — | = orçamento | — |
| Base Escolar consolidada | `dedicada-8gb` | redis `cache-256mb` + meili `busca-512mb` | 9 GB | 16 GB |
| Base Escolar + observabilidade | `dedicada-8gb` | os acima + `metricas-512mb` | 10,3 GB | 16 GB |
| Projeto médio consolidado | `dedicada-16gb` | redis `cache-512mb` + meili `busca-4gb` | 21 GB | 32 GB |
| Projeto médio + observabilidade | `dedicada-16gb` | os acima + `metricas-512mb` | 22,3 GB | 32 GB |
| Multi-projeto | `dedicada-32gb` | redis `cache-1gb` + meili `busca-4gb` | 38 GB | 48–64 GB |
| Base Empresarial — host único | `dedicada-64gb` | redis `cache-512mb` + meili `busca-16gb` | 81 GB | 96 GB |
| **Base Empresarial — Postgres isolado** ✅ | `dedicada-64gb` | Redis/Meili em outra máquina | 64 GB | 64 GB + host pequeno |

**Recomendação para a carga-alvo:** em base >100 GB com busca textual, **separe
o Meilisearch em outra máquina**. Não é questão de RAM — a indexação do Meili
despeja o page cache do Postgres, que é exatamente o ativo pelo qual se paga o
`dedicada-64gb`. O sintoma é confuso ("a busca ficou lenta *depois* da
reindexação") e a única mitigação no mesmo host é agendamento.

### Retrofit: o host já existe

Único caso em que os valores do perfil mudam. Não interpole: reescale a memória
e herde o resto do perfil imediatamente **inferior**.

```
orçamento_pg'        = RAM_host − Σ(limite dos vizinhos)
shared_buffers       = mesma % do perfil × orçamento_pg'
effective_cache_size = 75% × orçamento_pg'
limite do container  = 87% × orçamento_pg'
demais parâmetros    = do perfil imediatamente INFERIOR
```

Errar `effective_cache_size` para cima é o mais perigoso: o planner passa a
escolher index scans que na prática vão ao disco.

### IO e CPU compartilhados

O NVMe é único e disputado por checkpoint do Postgres, AOF rewrite do Redis,
indexação do Meilisearch e backup (`pgbackrest` com `process-max` e compressão
`zst` também consome CPU). O Docker não reserva IOPS por padrão, então a
mitigação é **escalonar janelas**: reindexação, full backup e ETL em horários
distintos.

## Justificativas

Cada bloco abaixo traz a regra, o motivo do valor nesta carga e **o sinal
observável de que está errado**.

### Memória

- **`shared_buffers`.** A regra clássica é 25% da RAM. Nos perfis de 16 GB para
  cima este catálogo usa ~⅓ do orçamento: com leitura dominante e NVMe, servir a
  página direto do buffer pool evita a cópia do page cache, e o custo (checkpoints
  mais pesados) é absorvido por `checkpoint_timeout=15min` e
  `completion_target=0.9`. Acima de ~40% o double buffering passa a desperdiçar
  memória — 48GB é o teto do catálogo.
  *Sinal de erro:* cache hit ratio < 0.99 com o disco ocupado, ou checkpoints
  com `write` longo demais no log.
- **`effective_cache_size`.** Não aloca nada; informa ao planner quanto cache
  existe (shared_buffers + page cache). 75% do orçamento. Errar para baixo produz
  seq scans desnecessários; errar para cima produz index scans que vão ao disco.
  *Sinal de erro:* planos com seq scan em tabela grande quando existe índice
  seletivo.
- **`work_mem`.** Vale **por operação** de sort/hash, não por conexão — uma query
  pode usar várias. A fórmula `(orçamento − shared_buffers) ÷ (3 × max_connections)`
  protege contra OOM no pior caso. Para relatórios pontuais, prefira
  `SET work_mem` na sessão a subir o global.
  *Sinal de erro:* `log_temp_files` registrando arquivos temporários com
  frequência.
- **`hash_mem_multiplier`.** Dá folga só aos nós de hash (join e agregação), que
  dominam os filtros avançados sobre tabelas grandes, sem inflar o limite de todo
  sort. 3.0 nos perfis de 64 GB+ significa até 3× `work_mem` por nó de hash.
- **`maintenance_work_mem` e o PG17.** Até o PG16 o VACUUM não usava mais que
  ~1 GB na prática. O PG17 removeu esse teto (novo TID store, que ainda consome
  bem menos memória), então valores de 4–8 GB passam a reduzir de fato as passadas
  de index-vacuum e a encurtar a criação de índices grandes.
- **`autovacuum_work_mem`.** Com `-1`, **cada** worker de autovacuum herda
  `maintenance_work_mem`. Como o teto de 1 GB caiu no PG17, deixar `-1` num perfil
  com `maintenance_work_mem=8GB` e 6 workers autoriza 48 GB de pico. Por isso os
  perfis de 32 GB para cima fixam o valor à parte.

### Planner e IO

- **`random_page_cost = 1.1`.** O default 4.0 vem da era dos discos giratórios e
  induz o planner a evitar index scans que hoje são baratos. Em NVMe local, a
  leitura aleatória custa quase o mesmo que a sequencial.
- **`effective_io_concurrency`.** Número de requisições de prefetch em bitmap
  heap scans. 200 é o consenso para NVMe; 300 nos perfis grandes, onde há mais
  filas de IO em uso simultâneo. Retorno decrescente acima disso.
- **`maintenance_io_concurrency`.** O default upstream é **10** — estrangula o
  prefetch de VACUUM e ANALYZE justamente nas tabelas em que eles mais custam.
- **`io_combine_limit`.** O PG17 combina leituras em streaming (seq scan,
  ANALYZE); 256kB é o teto (`PG_IOV_MAX` = 32 blocos de 8kB).
  *Nota de compatibilidade:* o PG18 introduziu `io_max_combine_limit` (default
  128kB, só ajustável no start), que limita este valor **em silêncio** — numa
  futura atualização da imagem, os dois precisam subir juntos.
- **`default_statistics_target`.** Tabelas de dezenas de milhões de linhas com
  distribuição enviesada (município, CNAE) precisam de histogramas mais finos.
  200 é global; para colunas específicas, prefira
  `ALTER TABLE … ALTER COLUMN … SET STATISTICS` — ver [Fora do escopo da
  imagem](#fora-do-escopo-da-imagem).
- **`jit = off`.** O JIT beneficia analítica longa e frequentemente **piora**
  OLTP (compilar custa mais que executar). Sessões analíticas reativam com
  `SET jit = on`.

### Paralelismo

Regra: `max_worker_processes = max_parallel_workers = nº de vCPU`;
`per_gather ≈ vCPU ÷ 4` (mínimo 2); `maintenance ≈ vCPU ÷ 4` (mínimo 2). Mais
workers que vCPUs só cria fila.

`parallel_setup_cost` e `parallel_tuple_cost` reduzidos nos perfis grandes
baratearam o plano paralelo: com tabelas de dezenas de milhões de linhas, o
custo fixo de iniciar workers é irrelevante perto do ganho.

**`CREATE INDEX` paralelo não vale para GIN no PG17** — só B-tree e BRIN (GIN
paralelo chegou no PG18). Na carga mensal, o que acelera a recriação dos índices
trigram é `maintenance_work_mem`, não `max_parallel_maintenance_workers`.

*Sinal de erro:* `EXPLAIN` mostrando `Workers Planned` maior que
`Workers Launched` de forma consistente — não há slots livres.

### WAL e checkpoints

- **`max_wal_size`.** A carga mensal reescreve tabelas inteiras; WAL apertado
  força checkpoints em cascata no pior momento. É parâmetro de **reload**
  (SIGHUP): pode ser dobrado durante o ETL sem restart.
  *Sinal de erro:* no log, `checkpoints are occurring too frequently`.
- **`checkpoint_timeout = 15min`.** O default de 5 min reescreve as mesmas
  páginas em full-page writes repetidos. O custo de aumentar é um crash recovery
  mais longo.
- **`wal_buffers`.** O default `-1` calcula 1/32 de `shared_buffers` mas trava em
  16 MB. Cargas de escrita em massa se beneficiam de 32–64 MB.
- **`wal_compression = zstd`.** Reduz volume de WAL a custo baixo de CPU;
  especialmente valioso nas cargas mensais, cheias de full page writes.
- **`synchronous_commit`.** `off` durante o ETL acelera commits sem risco de
  corrupção — perde-se apenas as últimas transações confirmadas num crash. Nunca
  deixar `off` em regime.

### Autovacuum

- **`autovacuum_vacuum_cost_limit` é o ajuste de maior impacto deste catálogo.**
  O default (`-1`, que herda 200) limita o autovacuum a algo em torno de 40 MB/s
  de páginas sujas — um freio desenhado para discos giratórios. Em NVMe, com
  tabelas de 70M+ linhas, é a causa clássica de bloat: o autovacuum simplesmente
  não consegue acompanhar a taxa de atualização. O `cost_limit` é **dividido
  entre os workers ativos**, por isso escala junto com `autovacuum_max_workers`.
- **Scale factors menores nos perfis grandes.** O default (20% da tabela em dead
  tuples) significa 14M de linhas mortas numa tabela de 72M antes do primeiro
  vacuum. 0.02/0.01 mantém bloat e estatísticas sob controle com vacuums menores
  e mais frequentes.
- **`autovacuum_vacuum_insert_scale_factor`.** Tabelas append-only — como as de
  relacionamento entre empresas e atividades — nunca acumulam dead tuples e por
  isso nunca disparariam vacuum pelo critério clássico. Sem vacuum, o visibility
  map não é atualizado e **index-only scans deixam de funcionar**.
- **`log_autovacuum_min_duration = 10s`.** Sem isso não há como saber se o
  autovacuum está acompanhando.
  *Sinal de erro:* `pg_stat_user_tables.n_dead_tup` crescendo de forma monotônica
  numa tabela grande, ou `last_autovacuum` antigo demais.

### Busca textual

O que a imagem controla:

- **`gin_pending_list_limit` (4MB).** Com `fastupdate=on` (default dos índices
  GIN), as inserções vão para uma pending list que é **varrida linearmente a cada
  busca** até ser mesclada. Em carga de leitura dominante isso penaliza
  exatamente o caminho crítico. Manter o limite baixo reduz o tamanho da varredura.
- **`work_mem` e o bitmap.** Num bitmap heap scan, o bitmap em si é limitado por
  `work_mem`; quando estoura, ele vira **lossy** e o Postgres precisa reverificar
  o predicado linha a linha nas páginas marcadas. É o gargalo clássico de busca
  trigram sobre dezenas de milhões de linhas, e o motivo de `work_mem` e
  `hash_mem_multiplier` importarem aqui mais do que numa carga OLTP comum.
  *Sinal de erro:* `EXPLAIN (ANALYZE)` reportando `Heap Blocks: exact=… lossy=…`
  com valor alto em `lossy`.

#### Fora do escopo da imagem

Estes ajustes valem tanto quanto os de servidor para esta carga, mas são **DDL**
e vivem no repositório de ETL do projeto, não aqui:

- `fastupdate=off` nos índices GIN de busca (`ALTER INDEX … SET (fastupdate = off)`)
  — a solução definitiva para o problema da pending list em índice de leitura;
- `ALTER TABLE … ALTER COLUMN … SET STATISTICS 1000` nas colunas de filtro com
  distribuição enviesada, em vez de subir o `default_statistics_target` global e
  encarecer todo ANALYZE;
- autovacuum por tabela nas gigantes
  (`ALTER TABLE … SET (autovacuum_vacuum_scale_factor = 0.005, autovacuum_vacuum_threshold = 50000)`)
  — em tabelas de 72M linhas, até 0.02 é muita coisa;
- `CREATE STATISTICS` para correlações entre colunas de filtro (UF × município,
  por exemplo), que o planner não estima bem sozinho.

## Limitações transversais

- **Conexões.** Os perfis assumem pool de conexões do lado da aplicação. Se o
  número de clientes simultâneos crescer além de algumas centenas, adote
  **PgBouncer** em vez de subir `max_connections` — conexões Postgres são caras
  (memória e contenção de latch).
- **Huge pages.** `huge_pages=try` só tem efeito se o host reservar hugepages; em
  `shared_buffers` ≥ 16GB o ganho de TLB é mensurável. Ver [host.md](host.md).
- **`/dev/shm` e paralelismo.** Com `dynamic_shared_memory_type=posix`, os
  segmentos de memória compartilhada dos workers saem de `/dev/shm`; em
  container, o default é 64 MB. `/dev/shm` insuficiente derruba queries
  paralelas com um erro que aponta para o lugar errado, e o risco **cresce com
  o perfil** — o pico é `(workers+1) × work_mem × hash_mem_multiplier × nós de
  hash`, então migrar para uma máquina maior torna o estouro mais provável, não
  menos. Foi assim que a Base Empresarial perdeu 6h43 de ETL em 25/07/2026.
  Aplique o mount `tmpfs` da [receita de deploy](deploy.md#a-receita); sintoma e
  correção em [troubleshooting.md](troubleshooting.md#1-could-not-resize-shared-memory-segment).
  Desde 2026-07 a imagem detecta a situação no start e degrada o paralelismo em
  vez de quebrar (`PG_SHM_PREFLIGHT`, ver [shm-guard.sh](../shm-guard.sh)).
- **Parâmetros que exigem restart:** `shared_buffers`, `max_connections`,
  `max_worker_processes`, `autovacuum_max_workers`, `wal_buffers`, `huge_pages`,
  `shared_preload_libraries`, `pg_stat_statements.max`,
  `max_locks_per_transaction`. Como o conf é regerado no start do container, todo
  redeploy já é um restart. Ajustáveis a quente (reload): `max_wal_size`,
  `work_mem`, `random_page_cost`, `effective_cache_size` e os scale factors do
  autovacuum.
- **Réplicas e HA** estão fora do escopo destes perfis; ver `backup/` para PITR
  com pgBackRest.

## Máquinas equivalentes por provedor

Os perfis são definidos por RAM/vCPU — a tabela abaixo é apenas um **atalho de
pesquisa**. Catálogos e nomes de planos mudam com frequência; confira o catálogo
atual antes de contratar. Priorize sempre: (1) **NVMe local** (requisito, não
preferência), (2) vCPU dedicada em produção, (3) rede privada entre as máquinas
do projeto.

| Perfil | Hetzner (cloud/dedicado) | Netcup | DigitalOcean | Linode (Akamai) | Vultr |
|---|---|---|---|---|---|
| dedicada-8gb | CX32/CPX31 | VPS/RS 1000 | Basic 8GB ou g-2vcpu-8gb | Dedicated 8GB | Cloud Compute 8GB |
| dedicada-16gb | CPX41; CCX23 (vCPU dedicada) | RS 2000 | g-4vcpu-16gb / m-2vcpu-16gb | Dedicated 16GB | Optimized 16GB |
| dedicada-32gb | CPX51; CCX33 | RS 4000 | g-8vcpu-32gb / m-4vcpu-32gb | Dedicated 32GB | Optimized 32GB |
| dedicada-64gb | CCX43; dedicados AX41-NVMe/EX44 | RS 8000 | g-16vcpu-64gb / m-8vcpu-64gb | Dedicated 64GB / High Memory | Optimized 64GB |
| dedicada-128gb | CCX53; dedicados AX102/EX101 | — (topo da linha RS costuma parar antes) | m-16vcpu-128gb | High Memory 128GB | Bare metal |

Notas:

- **Confirme o tipo de disco do plano.** Vários planos cloud entregam block
  storage de rede como disco do sistema; nesses casos o catálogo não se aplica sem
  as ressalvas de [Premissas](#premissas-do-catálogo). Verifique antes de instalar
  com o pré-voo de [host.md](host.md).
- Nas linhas *cloud*, planos com **vCPU compartilhada** (Hetzner CX/CPX, DO Basic,
  Netcup VPS) servem para os perfis pequenos e ambientes não críticos; para
  produção com carga sustentada, prefira as linhas de vCPU dedicada (Hetzner CCX,
  DO General Purpose/Memory, Linode Dedicated, Netcup RS).
- **Servidores dedicados** (Hetzner AX/EX e equivalentes) entregam NVMe local
  muito superior por custo nos perfis 64/128 GB — ao preço de provisionamento
  mais lento e sem snapshot gerenciado. Prefira RAID1 de dois NVMe à unidade
  única: NVMe de consumo falha, e o PITR não elimina a janela de perda.

## Validação de um perfil implantado

Primeiro, confirme que o conf gerado foi aceito inteiro — uma env com valor
inválido aparece aqui antes de virar um comportamento estranho:

```sql
SELECT sourceline, name, setting, applied, error
  FROM pg_file_settings
 WHERE NOT applied OR error IS NOT NULL;   -- deve voltar vazio
```

Depois, compare os valores efetivos com o arquivo do perfil:

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

Depois de 24–48 h de tráfego, os dois indicadores que decidem migração de perfil:

```sql
-- Cache hit ratio (alvo: > 0.99 em produção estável)
SELECT sum(blks_hit)::float / nullif(sum(blks_hit) + sum(blks_read), 0)
  FROM pg_stat_database;

-- Queries dominadas por IO (exige track_io_timing=on)
SELECT query, total_exec_time, shared_blk_read_time
  FROM pg_stat_statements ORDER BY shared_blk_read_time DESC LIMIT 10;
```

E o indicador que diz se o autovacuum está acompanhando a carga:

```sql
SELECT relname, n_live_tup, n_dead_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup, 0), 4) AS ratio,
       last_autovacuum
  FROM pg_stat_user_tables
 WHERE n_dead_tup > 100000
 ORDER BY n_dead_tup DESC LIMIT 10;
```
