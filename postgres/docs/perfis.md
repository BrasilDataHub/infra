# Perfis de dimensionamento do PostgreSQL

Guia dos perfis de configuração da imagem `ghcr.io/brasildatahub/postgres:17`.
Os perfis servem a **todos os projetos da organização** — Base Empresarial
(~116 GB, 200M+ linhas), Base Escolar (~170 mil escolas do Censo Escolar,
alguns GB) e Base Hospitalar — e a projetos futuros. Por isso são definidos
por **características da máquina** (RAM, vCPUs, tipo de armazenamento), nunca
por um fornecedor específico.

## Como o catálogo funciona

- A imagem é **única**: o `postgresql.conf` é gerado no start do container a
  partir de envs `PG_*` (ver `generate-config.sh`). Trocar de perfil é trocar
  envs no deploy — nenhum rebuild.
- Cada perfil é um **bloco de envs documentado neste guia**, pronto para
  copiar e colar: em painéis como o Dokploy, cole no Environment do serviço;
  fora deles, cole no `environment:`/`.env` do seu compose (template de
  referência em [Compose de referência](#compose-de-referência)).
- Tudo que não está no bloco do perfil usa os defaults da imagem, que são o
  cenário compartilhado (o mais conservador).

## Tabela-resumo

| Perfil | Máquina-alvo | shared_buffers | effective_cache_size | work_mem | Paralelismo (workers/gather) | Uso típico |
|---|---|---|---|---|---|---|
| `compartilhada-8gb` | host de 8 GB **dividido** com app/cache/etc. | 2GB | 4GB | 32MB | 8/2 | sobrevivência num host único |
| `dedicada-8gb` | 8 GB, 2–4 vCPU, SSD/NVMe, só Postgres | 2GB | 6GB | 16MB | 4/2 | produção pequena, staging |
| `dedicada-16gb` | 16 GB, ~4 vCPU, SSD/NVMe | 4GB | 12GB | 32MB | 4/2 | produção de bases de dezenas de GB |
| `dedicada-32gb` | 32 GB, ~8 vCPU, SSD/NVMe | 8GB | 24GB | 48MB | 8/4 | centenas de GB com tráfego moderado; várias bases |
| `dedicada-64gb` | 64 GB, ~16 vCPU, NVMe local | 16GB | 48GB | 64MB | 12/4 | produção de base grande com busca textual intensiva |
| `dedicada-128gb` | 128 GB, 16–24 vCPU, NVMe local | 32GB | 96GB | 64MB | 12/4 | working set de base grande inteiro em RAM |

## Como escolher

A pergunta central não é "quantos dados eu tenho", e sim **qual é o working
set** — o subconjunto de dados e índices que as consultas tocam com
frequência. A regra prática:

1. **Working set cabe em `shared_buffers` + page cache?** Se sim, o perfil
   atende com folga. Se o working set é várias vezes maior que a RAM, as
   consultas viram IO e nenhum tuning compensa — suba de perfil.
2. **Workload**: todos os perfis assumem carga **mista web/OLTP com leitura
   dominante** (o padrão dos projetos da org: API + páginas SSR + buscas).
   Para analítica pesada recorrente, os perfis maiores (32 GB+) atendem
   melhor pelo paralelismo; para OLTP puro de alta concorrência, considere
   um pooler (ver [Limitações transversais](#limitações-transversais)).
3. **Referências concretas da org**: Base Escolar (~170 mil escolas, alguns
   GB no total) roda confortavelmente em `dedicada-8gb`/`dedicada-16gb`.
   Base Empresarial (116 GB, índices de busca de dezenas de GB) precisa de
   `dedicada-64gb` ou superior para servir busca textual com working set em
   RAM.

---

## Perfil `compartilhada-8gb`

**Objetivo.** Manter o Postgres estável e previsível num host que ele **não
controla**: 8 GB divididos com aplicação, Redis, Meilisearch e o próprio
sistema, sobrando um orçamento de ~4 GB para o banco. É o perfil dos
**defaults da imagem** — implantar sem env nenhuma produz este cenário.

**Quando usar.**
- Projeto começando, tudo num host único (é o cenário atual do Base
  Empresarial até a migração).
- Ambientes de desenvolvimento/homologação onde o banco divide a máquina.

**Parâmetros e porquês.**

| Parâmetro | Valor | Porquê |
|---|---|---|
| `shared_buffers` | 2GB | ~25% do orçamento efetivo ×2 — deliberadamente agressivo dentro dos 4 GB porque o page cache do SO está sendo disputado pelos vizinhos |
| `effective_cache_size` | 4GB | informa ao planner que **não** há um page cache grande disponível |
| `work_mem` | 32MB | teto seguro com poucas conexões simultâneas reais |
| `maintenance_work_mem` | 512MB | manutenção não pode roubar memória do host |
| `random_page_cost` | 1.5 | assume volume de rede/SSD compartilhado, não NVMe local |
| `effective_io_concurrency` | 100 | idem — IO dividido com vizinhos |
| `jit` | off | com 2 vCPU disputados, o custo de compilar supera o ganho |
| `max_wal_size` | 4GB | checkpoints mais frequentes, porém picos de disco menores |

Bloco do perfil (**são os defaults da imagem** — colar é opcional, serve
como registro explícito no deploy):

```env
PG_SHARED_BUFFERS=2GB
PG_EFFECTIVE_CACHE_SIZE=4GB
PG_WORK_MEM=32MB
PG_MAINTENANCE_WORK_MEM=512MB
PG_RANDOM_PAGE_COST=1.5
PG_EFFECTIVE_IO_CONCURRENCY=100
PG_JIT=off
PG_MAX_WAL_SIZE=4GB
```

Recursos do container: limite de memória **4G** / reserva 2G, `shm_size` 1gb.

**Benefícios.** Não derruba o host: o banco convive com os vizinhos sem OOM.
Zero configuração (defaults).

**Limitações.**
- Consultas analíticas e buscas trigram em tabelas grandes **vão ao disco** —
  este perfil não sustenta working set de dezenas de GB.
- A performance flutua com o comportamento dos vizinhos (cache do SO
  disputado, IO compartilhado).
- Sem headroom para manutenção pesada (REINDEX, VACUUM FULL) em horário de
  tráfego.

**Quando migrar.** Qualquer um destes sinais: p95 de consultas indexadas
piora em horário de pico sem mudança de código; `pg_stat_statements` mostra
tempo de IO dominante em queries que cabem em índice; a carga/manutenção
mensal invade a janela de tráfego. O próximo passo natural é o menor perfil
dedicado que comporte o working set — não necessariamente o maior.

---

## Perfis dedicados

Premissas comuns a todos: máquina **exclusiva** do Postgres, armazenamento
**SSD/NVMe local** (ver [Armazenamento](#armazenamento-nvme-local-vs-volume-de-rede)),
carga mista web/OLTP com leitura dominante. Todos herdam da imagem:
`wal_compression=zstd`, `checkpoint_completion_target=0.9`, `jit=off`,
`track_io_timing=on`, `pg_stat_statements` pré-carregado, timeouts do role
de leitura.

### `dedicada-8gb` — produção pequena

**Objetivo.** O menor perfil de produção séria: banco com a máquina para si,
ainda que modesta (8 GB, 2–4 vCPU).

**Quando usar.** Bases de até ~20–30 GB com working set de poucos GB —
o caso do **Base Escolar** (~170 mil escolas) e do Base Hospitalar no início;
staging fiel de projetos maiores; réplicas de leitura pequenas.

**Cargas adequadas.** OLTP leve/moderado, APIs de consulta, dashboards sobre
bases pequenas. Não é perfil para analítica pesada nem cargas em massa
frequentes.

| Parâmetro | Valor | Porquê |
|---|---|---|
| `shared_buffers` | 2GB | 25% da RAM — a regra clássica da comunidade |
| `effective_cache_size` | 6GB | ~75% da RAM: com a máquina dedicada, o resto vira page cache |
| `work_mem` | 16MB | (RAM − shared_buffers) ÷ (3 × max_connections): 100 conexões com margem contra OOM |
| `maintenance_work_mem` | 512MB | suficiente para índices de bases pequenas |
| `random_page_cost` / `effective_io_concurrency` | 1.1 / 200 | SSD/NVMe: leitura aleatória quase tão barata quanto sequencial |
| paralelismo | 4 workers / 2 por gather | espelha 2–4 vCPUs — mais que isso só cria fila |
| `max_wal_size` | 4GB | dimensionado ao disco pequeno |
| autovacuum scale factors | 0.1 / 0.05 | metade do default: tabelas pequenas, vacuum barato e mais frequente |

```env
PG_MAX_CONNECTIONS=100
PG_SHARED_BUFFERS=2GB
PG_EFFECTIVE_CACHE_SIZE=6GB
PG_WORK_MEM=16MB
PG_MAINTENANCE_WORK_MEM=512MB
PG_RANDOM_PAGE_COST=1.1
PG_EFFECTIVE_IO_CONCURRENCY=200
PG_MAX_WORKER_PROCESSES=4
PG_MAX_PARALLEL_WORKERS=4
PG_MAX_PARALLEL_WORKERS_PER_GATHER=2
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=2
PG_MAX_WAL_SIZE=4GB
PG_MIN_WAL_SIZE=1GB
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.1
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.05
```

Recursos do container: limite de memória **7G**, `shm_size` 1gb.

**Benefícios.** Latência estável (sem vizinhos); custo mínimo de produção
dedicada. **Limitações.** `work_mem` apertado penaliza sorts/hashes grandes;
sem espaço para picos de manutenção concorrentes.

**Migrar para 16 GB quando:** o working set passar de ~5 GB (cache hit ratio
de `pg_stat_database` caindo abaixo de ~99%), ou sorts derramando para disco
com frequência (`log_temp_files`/`pg_stat_statements`).

### `dedicada-16gb` — o ponto de entrada confortável

**Objetivo.** Folga real de cache e manutenção para bases de dezenas de GB —
o melhor custo-benefício para projetos da org que já têm tráfego.

**Quando usar.** Bases de ~30–80 GB com working set de até ~10 GB; o destino
natural de Base Escolar/Base Hospitalar quando crescerem; consolidação de
2–3 bancos pequenos de projetos distintos.

**Cargas adequadas.** OLTP moderado + consultas analíticas ocasionais
(relatórios, agregações); produção e homologação.

| Parâmetro | Valor | Porquê |
|---|---|---|
| `shared_buffers` | 4GB | 25% da RAM |
| `effective_cache_size` | 12GB | 75% da RAM |
| `work_mem` | 32MB | mesma fórmula, mais folga por conexão |
| `maintenance_work_mem` | 1GB | REINDEX/VACUUM de tabelas médias sem derramar |
| `max_wal_size` | 8GB | checkpoints mais espaçados nas cargas |
| demais | = 8gb | mesma máquina-alvo de 4 vCPU |

```env
PG_MAX_CONNECTIONS=100
PG_SHARED_BUFFERS=4GB
PG_EFFECTIVE_CACHE_SIZE=12GB
PG_WORK_MEM=32MB
PG_MAINTENANCE_WORK_MEM=1GB
PG_RANDOM_PAGE_COST=1.1
PG_EFFECTIVE_IO_CONCURRENCY=200
PG_MAX_WORKER_PROCESSES=4
PG_MAX_PARALLEL_WORKERS=4
PG_MAX_PARALLEL_WORKERS_PER_GATHER=2
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=2
PG_MAX_WAL_SIZE=8GB
PG_MIN_WAL_SIZE=1GB
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.1
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.05
```

Recursos do container: limite de memória **14G**, `shm_size` 2gb.

**Benefícios.** Working set típico inteiro em RAM; manutenção fora do caminho
crítico. **Limitações.** 4 vCPUs limitam o paralelismo — uma agregação pesada
compete com o tráfego.

**Migrar para 32 GB quando:** consultas analíticas recorrentes disputarem CPU
com o OLTP (paralelismo saturado), ou o working set passar de ~10 GB.

### `dedicada-32gb` — equilíbrio para crescer

**Objetivo.** O primeiro perfil com paralelismo de verdade (8 vCPU): serve
tráfego enquanto roda agregação, e comporta várias bases médias juntas.

**Quando usar.** Bases de ~80–300 GB com working set de até ~20 GB;
**consolidação multi-projeto** (Base Escolar + Base Hospitalar + futuros no
mesmo servidor, cada um no seu database); a instância única de um projeto
médio em produção.

**Cargas adequadas.** OLTP com picos, analítica regular (relatórios diários,
MVs), ETLs mensais de porte médio.

| Parâmetro | Valor | Porquê |
|---|---|---|
| `shared_buffers` | 8GB | 25% da RAM |
| `effective_cache_size` | 24GB | 75% da RAM |
| `max_connections` | 150 | mais aplicações/serviços simultâneos |
| `work_mem` | 48MB | fórmula com 150 conexões |
| `maintenance_work_mem` | 2GB | índices grandes em uma passada |
| paralelismo | 8 workers / 4 por gather | espelha as 8 vCPUs; agregações usam metade da máquina no máximo |
| `max_wal_size` / `min_wal_size` | 8GB / 2GB | cargas médias sem tempestade de checkpoints |
| autovacuum scale factors | 0.05 / 0.02 | a partir daqui as tabelas são grandes: 20% de dead tuples (default) seria GB demais entre vacuums |

```env
PG_MAX_CONNECTIONS=150
PG_SHARED_BUFFERS=8GB
PG_EFFECTIVE_CACHE_SIZE=24GB
PG_WORK_MEM=48MB
PG_MAINTENANCE_WORK_MEM=2GB
PG_RANDOM_PAGE_COST=1.1
PG_EFFECTIVE_IO_CONCURRENCY=200
PG_MAX_WORKER_PROCESSES=8
PG_MAX_PARALLEL_WORKERS=8
PG_MAX_PARALLEL_WORKERS_PER_GATHER=4
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=2
PG_MAX_WAL_SIZE=8GB
PG_MIN_WAL_SIZE=2GB
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.05
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.02
```

Recursos do container: limite de memória **28G**, `shm_size` 2gb.

**Benefícios.** Analítica e OLTP convivem; consolidar projetos reduz custo
por projeto. **Limitações.** Para bases do porte do Base Empresarial
(índices trigram de dezenas de GB), o cache ainda é insuficiente — busca
textual pesada continuará tocando disco.

**Migrar para 64 GB quando:** o produto principal depender de busca
textual/trigram sobre dezenas de milhões de linhas, ou o working set agregado
passar de ~20 GB.

### `dedicada-64gb` — produção de base grande

**Objetivo.** O perfil de produção do **Base Empresarial** pós-migração:
os índices críticos de busca (GIN trigram, btrees compostos, a tabela
`busca_estabelecimento` de ~10–12 GB) residentes em RAM.

**Quando usar.** Bases de centenas de GB cujo working set (índices de busca +
tabelas quentes) fica em ~30–40 GB; carga mensal pesada (ETL de 200M+ linhas)
convivendo com produção.

**Cargas adequadas.** Busca textual em escala, OLTP + analítica simultâneos,
ETL mensal com janela apertada.

| Parâmetro | Valor | Porquê |
|---|---|---|
| `shared_buffers` | 16GB | 25% da RAM — acima disso o ganho é marginal e o custo de checkpoint cresce |
| `effective_cache_size` | 48GB | 75%: o planner passa a preferir index scans que tocam muitos blocos |
| `max_connections` | 200 | múltiplos serviços (website, indexadores, sitemap) |
| `work_mem` | 64MB | fórmula com 200 conexões; sessões de relatório podem elevar via `SET work_mem` |
| `maintenance_work_mem` | 2GB | criação dos índices trigram de GB na carga mensal |
| `default_statistics_target` | 200 | tabelas de dezenas de milhões de linhas com distribuição enviesada (cidade, CNAE) precisam de histogramas mais finos |
| paralelismo | 16 wp / 12 pw / 4 gather / 4 maint | espelha as 16 vCPUs, reservando margem p/ backends normais |
| `max_wal_size` / `min_wal_size` | 16GB / 2GB | a carga mensal reescreve tabelas inteiras — checkpoints espaçados |
| autovacuum scale factors | 0.05 / 0.02 | 72M de linhas × 20% = 14M de dead tuples seria inaceitável |

```env
PG_MAX_CONNECTIONS=200
PG_SHARED_BUFFERS=16GB
PG_EFFECTIVE_CACHE_SIZE=48GB
PG_WORK_MEM=64MB
PG_MAINTENANCE_WORK_MEM=2GB
PG_RANDOM_PAGE_COST=1.1
PG_EFFECTIVE_IO_CONCURRENCY=200
PG_DEFAULT_STATISTICS_TARGET=200
PG_MAX_WORKER_PROCESSES=16
PG_MAX_PARALLEL_WORKERS=12
PG_MAX_PARALLEL_WORKERS_PER_GATHER=4
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=4
PG_MAX_WAL_SIZE=16GB
PG_MIN_WAL_SIZE=2GB
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.05
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.02
```

Recursos do container: limite de memória **56G**, `shm_size` 4gb.

**Benefícios.** Busca textual sub-segundo com cache quente; ETL e produção
convivem. **Limitações.** Working sets muito acima de ~40 GB (ex.: todos os
índices da base toda) ainda excedem o cache.

**Migrar para 128 GB quando:** o hit ratio cair com o crescimento mensal da
base, ou novas cargas (réplicas analíticas, mais projetos grandes no mesmo
servidor) ampliarem o working set além dos ~40 GB.

### `dedicada-128gb` — working set inteiro em RAM

**Objetivo.** Teto do catálogo: praticamente toda a parte quente de uma base
grande (dados + índices) residente em memória; o disco sai do caminho crítico
das leituras.

**Quando usar.** Base Empresarial com folga para anos de crescimento;
servidor único consolidando uma base grande + projetos menores; cargas
analíticas pesadas sobre a base completa.

**Cargas adequadas.** Tudo que o 64 GB atende, mais analítica ad hoc sobre a
base inteira sem degradar a produção.

| Parâmetro | Valor | Porquê |
|---|---|---|
| `shared_buffers` | 32GB | 25% da RAM (o teto prático recomendado — acima disso, double buffering com o page cache e checkpoints caros) |
| `effective_cache_size` | 96GB | 75% da RAM |
| `maintenance_work_mem` | 4GB | **revisado nesta versão**: no PostgreSQL 17 o VACUUM passou a usar de fato mais de 1 GB (novo TID store) — em tabelas de dezenas de GB isso reduz passadas de index-vacuum e encurta a manutenção |
| demais | = 64gb | a máquina-alvo tem CPU semelhante; a diferença é RAM |

```env
PG_MAX_CONNECTIONS=200
PG_SHARED_BUFFERS=32GB
PG_EFFECTIVE_CACHE_SIZE=96GB
PG_WORK_MEM=64MB
PG_MAINTENANCE_WORK_MEM=4GB
PG_RANDOM_PAGE_COST=1.1
PG_EFFECTIVE_IO_CONCURRENCY=200
PG_DEFAULT_STATISTICS_TARGET=200
PG_MAX_WORKER_PROCESSES=16
PG_MAX_PARALLEL_WORKERS=12
PG_MAX_PARALLEL_WORKERS_PER_GATHER=4
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=4
PG_MAX_WAL_SIZE=16GB
PG_MIN_WAL_SIZE=2GB
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.05
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.02
```

Recursos do container: limite de memória **112G**, `shm_size` 4gb.

**Benefícios.** Latência de leitura desacoplada do disco; margem para crescer
sem re-tuning. **Limitações.** Custo; escritas continuam limitadas por
WAL/fsync (RAM não acelera commit); acima disso o caminho é sharding/réplicas,
não mais RAM.

---

## Justificativas transversais (recomendações da comunidade aplicadas)

- **`shared_buffers` = 25% da RAM** — recomendação clássica da documentação
  oficial e do pgtune. Menos que isso desperdiça a máquina dedicada; muito
  mais que isso causa double buffering (Postgres e SO cacheando as mesmas
  páginas) e checkpoints mais caros. O teto prático do catálogo é 32GB.
- **`effective_cache_size` ≈ 75% da RAM** — não aloca nada; apenas informa ao
  planner quanto cache (shared_buffers + page cache) existe, tornando index
  scans mais atraentes. Errar para baixo produz seq scans desnecessários.
- **`work_mem` pela fórmula (RAM − shared_buffers) ÷ (3 × max_connections)** —
  work_mem é **por operação de sort/hash**, não por conexão; uma query pode
  usar vários. A fórmula (usada pelo pgtune) protege contra OOM no pior caso.
  Para relatórios pontuais, prefira `SET work_mem` na sessão a subir o global.
- **`random_page_cost` = 1.1 e `effective_io_concurrency` = 200 em SSD/NVMe** —
  o default 4.0 vem da era dos discos giratórios e induz o planner a evitar
  index scans que hoje são baratos. No perfil compartilhado ficam 1.5/100
  (IO disputado/volume de rede).
- **`jit = off` em todos os perfis** — o JIT beneficia analítica longa e
  frequentemente **piora** OLTP (compilar custa mais que executar). Sessões
  analíticas podem reativar com `SET jit = on`.
- **`wal_compression = zstd`** (PG15+) — reduz volume de WAL a custo de CPU
  baixo; especialmente valioso nas cargas mensais com full page writes.
- **`checkpoint_completion_target = 0.9`** — default upstream desde o PG14,
  mantido explícito: espalha a escrita do checkpoint pelo intervalo.
- **Autovacuum mais agressivo (0.05/0.02) nos perfis grandes** — o default
  (20% da tabela em dead tuples) significa milhões de linhas mortas em
  tabelas de 70M+; scale factors menores mantêm o bloat e as estatísticas sob
  controle com vacuums menores e mais frequentes.
- **`track_io_timing = on`** (novo nesta revisão) — sem ele,
  `pg_stat_statements`/`EXPLAIN (BUFFERS)` não separam tempo de IO de tempo
  de CPU, cegando exatamente o diagnóstico que motivou `pg_stat_statements`
  na imagem. Custo desprezível em clock sources modernos (verificável com
  `pg_test_timing`).
- **`maintenance_work_mem` e o PG17** — até o PG16 o VACUUM não usava mais
  que ~1 GB na prática; o PG17 removeu esse teto (TID store novo). Por isso o
  perfil 128 GB subiu para 4GB; nos perfis menores o valor segue limitado
  pela RAM.

### Limitações transversais

- **Conexões**: os perfis assumem pool de conexões do lado da aplicação
  (Laravel/psycopg com pool). Se o número de clientes simultâneos crescer
  além de algumas centenas, adote **PgBouncer** em vez de subir
  `max_connections` — conexões Postgres são caras (memória e latch contention).
- **Huge pages**: `huge_pages=try` (default) só tem efeito se o host
  reservar hugepages; em `shared_buffers` ≥ 16GB vale configurar o host
  (`vm.nr_hugepages`) — ganho de TLB mensurável. Não é imposto pela imagem
  por depender do host.
- **Réplicas/HA**: fora do escopo destes perfis; ver `backup/` para
  PITR com pgBackRest.

---

## Armazenamento: NVMe local vs volume de rede

O tipo de disco importa **mais que a RAM** a partir do momento em que o
working set não cabe em cache:

- **NVMe local** (o alvo dos perfis dedicados): latência de dezenas de µs;
  é o que sustenta `random_page_cost=1.1`.
- **Block storage de rede** (volumes anexáveis dos provedores cloud):
  latência de ms e IOPS limitados por cota — aceitável para os perfis
  pequenos, ruim para busca textual em base grande. Se for inevitável, suba
  `PG_RANDOM_PAGE_COST` para 1.5–2.0 e trate os números de latência dos
  perfis como otimistas.
- Em **servidores dedicados (bare metal)** com NVMe, prefira RAID1 de dois
  NVMe à unidade única — NVMe de consumo falha, e PITR (ver `backup/`)
  não elimina a janela de perda.

## Máquinas equivalentes por provedor (referência, não vínculo)

Os perfis são definidos por RAM/vCPU/disco — a tabela abaixo é apenas um
**atalho de pesquisa**. Catálogos e nomes de planos mudam com frequência;
confira o catálogo atual do provedor antes de contratar. Priorize sempre:
(1) vCPU dedicada em produção (não compartilhada/burstable), (2) NVMe local,
(3) rede privada entre as máquinas do projeto.

| Perfil | Hetzner (cloud/dedicado) | Netcup | DigitalOcean | Linode (Akamai) | Vultr |
|---|---|---|---|---|---|
| dedicada-8gb | CX32/CPX31 (cloud) | VPS/RS 1000 | Basic 8GB ou g-2vcpu-8gb | Dedicated 8GB | Cloud Compute 8GB |
| dedicada-16gb | CX42/CPX41; CCX23 (vCPU dedicada) | RS 2000 | g-4vcpu-16gb / m-2vcpu-16gb | Dedicated 16GB | Optimized 16GB |
| dedicada-32gb | CX52/CPX51; CCX33 | RS 4000 | g-8vcpu-32gb / m-4vcpu-32gb | Dedicated 32GB | Optimized 32GB |
| dedicada-64gb | CCX43; dedicados AX41-NVMe/EX44 | RS 8000 | g-16vcpu-64gb / m-8vcpu-64gb | Dedicated 64GB / High Memory | Optimized 64GB |
| dedicada-128gb | CCX53; dedicados AX102/EX101 | — (topo da linha RS costuma parar antes) | m-16vcpu-128gb | High Memory 128GB | Bare metal |

Notas:
- Nas linhas *cloud* dos provedores, os planos com **vCPU compartilhada**
  (Hetzner CX/CPX, DO Basic, Netcup VPS) servem para os perfis pequenos e
  ambientes não críticos; para produção com carga sustentada, prefira as
  linhas de **vCPU dedicada** (Hetzner CCX, DO General Purpose/Memory,
  Linode Dedicated, Netcup RS).
- **Servidores dedicados** (Hetzner AX/EX e equivalentes) entregam NVMe
  local muito superior por custo nos perfis 64/128 GB — ao preço de
  provisionamento mais lento e sem snapshot gerenciado.

## Compose de referência

Os composes diferem entre perfis apenas em três pontos: bloco de envs,
limite de memória e `shm_size`. Copie o template, cole o bloco do perfil e
ajuste os dois valores pela tabela:

| Perfil | Limite de memória | `shm_size` |
|---|---|---|
| dedicada-8gb | 7G | 1gb |
| dedicada-16gb | 14G | 2gb |
| dedicada-32gb | 28G | 2gb |
| dedicada-64gb | 56G | 4gb |
| dedicada-128gb | 112G | 4gb |

```yaml
# Template para máquina DEDICADA (qualquer perfil dedicada-*).
services:
  postgres:
    image: ghcr.io/brasildatahub/postgres:17
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB:?defina POSTGRES_DB}
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?defina POSTGRES_PASSWORD}
      DADOS_READ_PASSWORD: ${DADOS_READ_PASSWORD:-}
      # >>> cole aqui o bloco PG_* do perfil escolhido <<<
    volumes:
      # bind no SSD/NVMe LOCAL — nunca volume de rede (ver seção Armazenamento)
      - /data/pgdata:/var/lib/postgresql/data
    ports:
      # exclusivamente o IP privado — nunca 0.0.0.0
      - "${PRIVATE_IP:?defina PRIVATE_IP}:5432:5432"
    shm_size: 4gb                # <- tabela acima
    deploy:
      resources:
        limits:
          memory: 56G            # <- tabela acima
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s
```

Para o cenário **compartilhado** do baseempresarial (instância atual no
Dokploy), a diferença é o volume — o Docker volume **existente** com os
116 GB, que nunca deve ser recriado — e os limites menores:

```yaml
# Cenário compartilhado do baseempresarial (perfil compartilhada-8gb).
services:
  postgres:
    image: ghcr.io/brasildatahub/postgres:17
    restart: unless-stopped
    environment:
      POSTGRES_DB: dados_cnpj
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?defina POSTGRES_PASSWORD}
      DADOS_READ_PASSWORD: ${DADOS_READ_PASSWORD:-}
      # perfil compartilhada-8gb = defaults da imagem; nenhuma env PG_* necessária
    volumes:
      - baseempresarial-postgres-data:/var/lib/postgresql/data
    ports:
      - "15432:5432"
    shm_size: 1gb
    deploy:
      resources:
        limits:
          memory: 4G
        reservations:
          memory: 2G
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d dados_cnpj"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

volumes:
  baseempresarial-postgres-data:
    external: true
    name: baseempresarial-postgres-ujnn8y-data
```

## Validação de um perfil implantado

```bash
psql -U postgres -d <database> -c "
  SELECT name, setting, unit FROM pg_settings WHERE name IN
  ('shared_buffers','effective_cache_size','work_mem','maintenance_work_mem',
   'random_page_cost','effective_io_concurrency','max_parallel_workers',
   'max_wal_size','autovacuum_vacuum_scale_factor','track_io_timing',
   'shared_preload_libraries','jit');"
```

Compare com o `env.<perfil>` correspondente. Depois de 24–48 h de tráfego,
os dois indicadores que decidem migração de perfil:

```sql
-- Cache hit ratio (alvo: > 0.99 em produção estável)
SELECT sum(blks_hit)::float / nullif(sum(blks_hit) + sum(blks_read), 0)
  FROM pg_stat_database;

-- Queries dominadas por IO (exige track_io_timing=on)
SELECT query, total_exec_time, shared_blk_read_time
  FROM pg_stat_statements ORDER BY shared_blk_read_time DESC LIMIT 10;
```
