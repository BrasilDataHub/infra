# postgres — imagem PostgreSQL da organização

`ghcr.io/brasildatahub/postgres:17` — o PostgreSQL padrão dos projetos
BrasilDataHub (baseempresarial, baseescolar, basehospitalar, ...).

É uma **imagem única**: o `postgresql.conf` é gerado no start do container a
partir de variáveis de ambiente `PG_*` (com defaults seguros para um host
compartilhado pequeno). Retunar para outra máquina é só trocar envs no
deploy — nenhum rebuild, nenhuma variação de imagem.

Base fixa da imagem (igual em qualquer cenário):
`shared_preload_libraries=pg_stat_statements`, `wal_compression=zstd`,
`checkpoint_completion_target=0.9`, log de queries lentas e initdb com
extensões (`pg_trgm`, `unaccent`, `pg_stat_statements`, `btree_gin`) + role
de leitura `dados_read` (timeouts de servidor 15 s/60 s, senha via env
`DADOS_READ_PASSWORD`). O initdb roda **apenas** na primeira inicialização
(volume vazio); para bancos existentes, use o script de higiene do projeto
(ex.: `cnpj-pipeline/sql/prod_hygiene.sql`).

## Variáveis de tuning

| Env | Default | O que controla |
|---|---|---|
| `PG_MAX_CONNECTIONS` | `100` | conexões simultâneas |
| `PG_SHARED_BUFFERS` | `2GB` | cache de páginas do Postgres (~25% da RAM da instância) |
| `PG_EFFECTIVE_CACHE_SIZE` | `4GB` | estimativa de cache total (RAM disponível p/ o banco) |
| `PG_WORK_MEM` | `32MB` | memória por operação de sort/hash |
| `PG_MAINTENANCE_WORK_MEM` | `512MB` | memória p/ VACUUM/CREATE INDEX |
| `PG_RANDOM_PAGE_COST` | `1.5` | custo de leitura aleatória (`1.1` em NVMe local) |
| `PG_EFFECTIVE_IO_CONCURRENCY` | `100` | IO paralelo (`200` em NVMe local) |
| `PG_DEFAULT_STATISTICS_TARGET` | `100` | granularidade das estatísticas do planner |
| `PG_JIT` | `off` | JIT (`on` só com CPU sobrando) |
| `PG_MAX_WORKER_PROCESSES` | `8` | teto global de workers |
| `PG_MAX_PARALLEL_WORKERS` | `8` | workers paralelos de query |
| `PG_MAX_PARALLEL_WORKERS_PER_GATHER` | `2` | paralelismo por query |
| `PG_MAX_PARALLEL_MAINTENANCE_WORKERS` | `2` | paralelismo de manutenção |
| `PG_MAX_WAL_SIZE` / `PG_MIN_WAL_SIZE` | `4GB` / `512MB` | espaçamento de checkpoints |
| `PG_WAL_COMPRESSION` | `zstd` | compressão de WAL |
| `PG_AUTOVACUUM_VACUUM_SCALE_FACTOR` | `0.2` | agressividade do autovacuum |
| `PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR` | `0.1` | agressividade do auto-analyze |
| `PG_IDLE_IN_TRANSACTION_SESSION_TIMEOUT` | `60s` | mata transação ociosa |
| `PG_LOG_MIN_DURATION_STATEMENT` | `2000` | loga queries acima de N ms |
| `PG_SHARED_PRELOAD_LIBRARIES` | `pg_stat_statements` | bibliotecas pré-carregadas |
| `PG_ARCHIVE_MODE` / `PG_ARCHIVE_COMMAND` | `off` / `/bin/true` | WAL archiving (pgBackRest — ver `backup/`) |

## Cenários por máquina-alvo

Cada cenário é um **artefato versionado**: um arquivo de env (`env.<cenário>`,
fonte de verdade dos parâmetros `PG_*`) e um compose de referência
(`docker-compose.<cenário>.yml`, com volume, limites de recurso e rede do
cenário). No Dokploy, cole o conteúdo do arquivo de env no painel de
Environment; fora do Dokploy, use o compose diretamente.

### 1. Compartilhada 8 GB (caso atual do baseempresarial — CCX13, volume de rede)

Arquivos: [`env.compartilhada-8gb`](env.compartilhada-8gb) +
[`docker-compose.compartilhada-8gb.yml`](docker-compose.compartilhada-8gb.yml).

Host dividido com app/Redis/Meilisearch; ~4 GB para o Postgres.
**Os defaults da imagem já são este cenário** — basta não definir nada;
o arquivo de env existe como registro explícito.
Recursos do container: **limite de memória 4 GB / reserva 2 GB**, `shm_size`
1 GB; o compose preserva o volume Dokploy existente
(`baseempresarial-postgres-ujnn8y-data` — é onde vivem os 116 GB, nunca
recriar).

### 2. Dedicada 64 GB (ex.: CCX43 — 16 vCPU, NVMe local)

Arquivos: [`env.dedicada-64`](env.dedicada-64) +
[`docker-compose.dedicada-64.yml`](docker-compose.dedicada-64.yml).

Recursos do container: limite de memória **56 GB**, `shm_size` 4 GB,
PGDATA em **bind no NVMe local** (`/data/pgdata`) — nunca volume de rede;
porta 5432 exposta **somente** à rede privada (vSwitch/firewall).

### 3. Dedicada 128 GB (ex.: AX102 — Ryzen 7950X3D, NVMe local)

Arquivos: [`env.dedicada-128`](env.dedicada-128) +
[`docker-compose.dedicada-128.yml`](docker-compose.dedicada-128.yml).

Igual ao cenário 2, trocando `PG_SHARED_BUFFERS=32GB` e
`PG_EFFECTIVE_CACHE_SIZE=96GB`; limite de memória **112 GB**.

## Implantação no Dokploy

### Instância atual do baseempresarial (tarefa F4)

1. **Pré-condição:** backup da F1 existente e testado.
2. Dokploy → projeto `baseempresarial` → ambiente `production` → serviço
   `postgres` → aba **Advanced**: trocar o campo **Docker Image** de
   `postgres:17` para `ghcr.io/brasildatahub/postgres:17`.
3. Environment: nenhum `PG_*` é obrigatório (defaults = cenário 1);
   definir `DADOS_READ_PASSWORD` se quiser o role de leitura em instâncias
   novas (na atual o role vem da F6).
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

### Instância dedicada (tarefa F7)

1. Provisionar a máquina (decisão F5) com rede privada/vSwitch e firewall
   expondo o 5432 **apenas** à rede privada; `mkdir -p /data/pgdata` no
   NVMe local.
2. Criar o serviço com `ghcr.io/brasildatahub/postgres:17`, montar
   `/data/pgdata` em `/var/lib/postgresql/data` e colar o bloco de envs do
   cenário 2 ou 3 + `POSTGRES_PASSWORD`/`DADOS_READ_PASSWORD`.
3. Primeira subida em volume vazio executa o initdb (extensões + role).
4. Validar `pg_settings` (esperado: `shared_buffers` 16GB/32GB,
   `random_page_cost` 1.1).
5. Ativar backups: snapshot Hetzner + pgBackRest com
   `PG_ARCHIVE_MODE=on` e `PG_ARCHIVE_COMMAND` (ver `backup/`).

## Validação local

```bash
# Defaults (cenário 1):
docker compose -f docker-compose.local.yml up --build -d

# Cenário dedicado "em miniatura" (memória reduzida, resto igual):
PG_SHARED_BUFFERS=512MB PG_RANDOM_PAGE_COST=1.1 PG_MAX_PARALLEL_WORKERS=12 \
    docker compose -f docker-compose.local.yml up --build -d

docker compose -f docker-compose.local.yml exec postgres \
    psql -U postgres -d dados_cnpj \
    -c "SELECT name, setting FROM pg_settings WHERE name IN
        ('shared_buffers','random_page_cost','shared_preload_libraries','jit','max_parallel_workers');"
```

> As imagens do GHCR são públicas (pull sem autenticação); o repositório
> permanece privado.
