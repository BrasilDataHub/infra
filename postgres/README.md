# postgres — imagem PostgreSQL da organização

`ghcr.io/brasildatahub/postgres:17` — o PostgreSQL padrão dos projetos
BrasilDataHub (baseempresarial, baseescolar, basehospitalar, ...).

É uma **imagem única**: o `postgresql.conf` é gerado no start do container a
partir de variáveis de ambiente `PG_*` (com defaults seguros para um host
compartilhado pequeno). Retunar para outra máquina é só trocar envs no
deploy — nenhum rebuild, nenhuma variação de imagem.

Base fixa da imagem (igual em qualquer perfil):
`shared_preload_libraries=pg_stat_statements`, `track_io_timing=on`,
`wal_compression=zstd`, `checkpoint_completion_target=0.9`, log de queries
lentas e initdb com extensões (`pg_trgm`, `unaccent`, `pg_stat_statements`,
`btree_gin`) + role de leitura `dados_read` (timeouts de servidor 15 s/60 s,
senha via env `DADOS_READ_PASSWORD`). O initdb roda **apenas** na primeira
inicialização (volume vazio); para bancos existentes, use o script de
higiene do projeto (ex.: `cnpj-pipeline/sql/prod_hygiene.sql`).

## Perfis de dimensionamento

Os perfis são definidos por **características da máquina** (RAM, vCPUs,
tipo de disco), independentes de fornecedor, e servem a todos os projetos
da org. Cada perfil = `env.<perfil>` (parâmetros) +
`docker-compose.<perfil>.yml` (referência de deploy).

| Perfil | Máquina-alvo | Uso típico |
|---|---|---|
| [`compartilhada-8gb`](env.compartilhada-8gb) | host de 8 GB **dividido** com app/cache (defaults da imagem) | início de projeto num host único |
| [`dedicada-8gb`](env.dedicada-8gb) | 8 GB / 2–4 vCPU / SSD, só Postgres | produção pequena (ex.: Base Escolar), staging |
| [`dedicada-16gb`](env.dedicada-16gb) | 16 GB / 4 vCPU / SSD | bases de dezenas de GB |
| [`dedicada-32gb`](env.dedicada-32gb) | 32 GB / 8 vCPU / SSD | centenas de GB; consolidação multi-projeto |
| [`dedicada-64gb`](env.dedicada-64gb) | 64 GB / 16 vCPU / NVMe local | base grande com busca textual (Base Empresarial) |
| [`dedicada-128gb`](env.dedicada-128gb) | 128 GB / 16–24 vCPU / NVMe local | working set inteiro em RAM |

**Guia completo — objetivo, cenários, justificativa de cada parâmetro,
limitações, quando migrar de perfil e máquinas equivalentes por provedor
(Hetzner, Netcup, DigitalOcean, Linode etc.): [docs/perfis.md](docs/perfis.md).**

## Variáveis de tuning

| Env | Default | O que controla |
|---|---|---|
| `PG_MAX_CONNECTIONS` | `100` | conexões simultâneas |
| `PG_SHARED_BUFFERS` | `2GB` | cache de páginas do Postgres (~25% da RAM da instância) |
| `PG_EFFECTIVE_CACHE_SIZE` | `4GB` | estimativa de cache total (RAM disponível p/ o banco) |
| `PG_WORK_MEM` | `32MB` | memória por operação de sort/hash |
| `PG_MAINTENANCE_WORK_MEM` | `512MB` | memória p/ VACUUM/CREATE INDEX |
| `PG_RANDOM_PAGE_COST` | `1.5` | custo de leitura aleatória (`1.1` em SSD/NVMe local) |
| `PG_EFFECTIVE_IO_CONCURRENCY` | `100` | IO paralelo (`200` em SSD/NVMe local) |
| `PG_DEFAULT_STATISTICS_TARGET` | `100` | granularidade das estatísticas do planner |
| `PG_JIT` | `off` | JIT (`on` só para sessões analíticas) |
| `PG_MAX_WORKER_PROCESSES` | `8` | teto global de workers |
| `PG_MAX_PARALLEL_WORKERS` | `8` | workers paralelos de query |
| `PG_MAX_PARALLEL_WORKERS_PER_GATHER` | `2` | paralelismo por query |
| `PG_MAX_PARALLEL_MAINTENANCE_WORKERS` | `2` | paralelismo de manutenção |
| `PG_MAX_WAL_SIZE` / `PG_MIN_WAL_SIZE` | `4GB` / `512MB` | espaçamento de checkpoints |
| `PG_WAL_COMPRESSION` | `zstd` | compressão de WAL |
| `PG_AUTOVACUUM_VACUUM_SCALE_FACTOR` | `0.2` | agressividade do autovacuum |
| `PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR` | `0.1` | agressividade do auto-analyze |
| `PG_IDLE_IN_TRANSACTION_SESSION_TIMEOUT` | `60s` | mata transação ociosa |
| `PG_TRACK_IO_TIMING` | `on` | tempos de IO em pg_stat_statements/EXPLAIN |
| `PG_LOG_MIN_DURATION_STATEMENT` | `2000` | loga queries acima de N ms |
| `PG_SHARED_PRELOAD_LIBRARIES` | `pg_stat_statements` | bibliotecas pré-carregadas |
| `PG_ARCHIVE_MODE` / `PG_ARCHIVE_COMMAND` | `off` / `/bin/true` | WAL archiving (pgBackRest — ver `backup/`) |

## Implantação no Dokploy

### Instância atual do baseempresarial (tarefa F4 — perfil `compartilhada-8gb`)

1. **Pré-condição:** backup da F1 existente e testado.
2. Dokploy → projeto `baseempresarial` → ambiente `production` → serviço
   `postgres` → aba **Advanced**: trocar o campo **Docker Image** de
   `postgres:17` para `ghcr.io/brasildatahub/postgres:17`.
3. Environment: nenhum `PG_*` é obrigatório (defaults = perfil
   compartilhado); definir `DADOS_READ_PASSWORD` se quiser o role de leitura
   em instâncias novas (na atual o role vem da F6).
4. **Conferir o volume:** `baseempresarial-postgres-ujnn8y-data` deve
   permanecer montado em `/var/lib/postgresql/data` — é onde vivem os
   116 GB. Não recriar, não renomear.
5. Limites de recursos do serviço: **Memory Limit 4 GB / Reservation 2 GB**.
6. **Redeploy** (~30 s de indisponibilidade do banco).
7. Validar:

   ```sql
   SHOW shared_buffers;              -- 2GB
   SHOW shared_preload_libraries;    -- pg_stat_statements
   SHOW random_page_cost;            -- 1.5
   SELECT count(*) FROM estabelecimento;  -- contagem de amostra intacta
   ```

Rollback: voltar o campo Docker Image para `postgres:17` e Redeploy.

### Instância dedicada (qualquer projeto/perfil)

1. Provisionar a máquina (RAM/vCPU/disco do perfil escolhido — ver
   [docs/perfis.md](docs/perfis.md)) com rede privada e firewall expondo o
   5432 **apenas** à rede privada; `mkdir -p /data/pgdata` no disco local.
2. Criar o serviço com `ghcr.io/brasildatahub/postgres:17`, montar
   `/data/pgdata` em `/var/lib/postgresql/data` e colar o conteúdo do
   `env.<perfil>` + `POSTGRES_DB`/`POSTGRES_PASSWORD`/`DADOS_READ_PASSWORD`.
3. Primeira subida em volume vazio executa o initdb (extensões + role).
4. Validar `pg_settings` (query pronta em
   [docs/perfis.md](docs/perfis.md#validação-de-um-perfil-implantado)).
5. Ativar backups: snapshot do provedor + pgBackRest com
   `PG_ARCHIVE_MODE=on` e `PG_ARCHIVE_COMMAND` (ver `backup/`).

## Validação local

```bash
# Defaults (perfil compartilhado):
docker compose -f docker-compose.local.yml up --build -d

# Um perfil dedicado "em miniatura" (memória reduzida, resto igual):
PG_SHARED_BUFFERS=512MB PG_RANDOM_PAGE_COST=1.1 PG_MAX_PARALLEL_WORKERS=12 \
    docker compose -f docker-compose.local.yml up --build -d

docker compose -f docker-compose.local.yml exec postgres \
    psql -U postgres -d dados_cnpj \
    -c "SELECT name, setting FROM pg_settings WHERE name IN
        ('shared_buffers','random_page_cost','shared_preload_libraries','jit','max_parallel_workers','track_io_timing');"
```

> As imagens do GHCR são públicas (pull sem autenticação); o repositório
> permanece privado.
