# infra/postgres — imagem customizada do PostgreSQL

Hoje a produção roda `postgres:17` cru no Dokploy: sem arquivo de
configuração (`shared_buffers` de 128 MB para 116 GB de dados), sem limites
de recursos e com initdb padrão. Esta pasta versiona **toda a configuração
de instância** em imagens Docker por perfil — a única tarefa manual que
resta é trocar a imagem no Dokploy.

**Fronteira:** schema/DDL/índices/views pertencem ao `rfb-cnpj-etl`.
Aqui vive só a instância: imagem, `postgresql.conf`, extensões disponíveis,
recursos, backup físico.

## Perfis

| Perfil | Máquina-alvo | shared_buffers | Uso |
|---|---|---|---|
| `atual` | CCX13 compartilhado (8 GB p/ tudo; ~4 GB p/ PG) | 2GB | substitui a config manual de hoje (F4) |
| `dedicada-64` | CCX43 — 16 vCPU, 64 GB, NVMe local | 16GB | instância dedicada (F7), rota c2 |
| `dedicada-128` | AX102 — 128 GB DDR5, NVMe local | 32GB | instância dedicada (F7), rota c1 |

Parâmetros completos em `conf/<perfil>.conf`. Comuns aos três:
`shared_preload_libraries=pg_stat_statements`, `wal_compression=zstd`,
`idle_in_transaction_session_timeout=60s`, `log_min_duration_statement=2000`.
Nos dedicados: `random_page_cost=1.1` (NVMe), paralelismo 12/4, autovacuum
mais agressivo e `archive_command` do pgBackRest comentado (ver `backup/`).

## Imagens

Publicadas pela CI (`.github/workflows/build-publish.yml`) no GHCR a cada
push na `main` que toque `postgres/`:

```
ghcr.io/<owner>/baseempresarial-postgres:17-atual
ghcr.io/<owner>/baseempresarial-postgres:17-dedicada-64
ghcr.io/<owner>/baseempresarial-postgres:17-dedicada-128
```

> Substitua `OWNER` nos composes pelo owner real do GitHub após o primeiro
> push. Se o package ficar privado, o Dokploy precisa de um registry
> credential (Settings → Registry) para puxar do GHCR.

Build local de um perfil:

```bash
docker build --build-arg PROFILE=atual -t baseempresarial-postgres:17-atual postgres/
```

## initdb (somente volume novo)

`initdb/` roda **apenas na primeira inicialização** (volume vazio): cria as
extensões (`pg_trgm`, `unaccent`, `pg_stat_statements`, `btree_gin`) e o
role `dados_read` (timeouts de 15 s/60 s, `SELECT` em `public`, senha via
env `DADOS_READ_PASSWORD`). **No banco de produção existente nada disso
executa** — lá vale o script de higiene `rfb-cnpj-etl/sql/prod_hygiene.sql`
(tarefa F6).

## Implantação no Dokploy

### Perfil `atual` (tarefa F4 — instância de hoje)

1. **Pré-condição:** backup da F1 existente e testado.
2. Dokploy → projeto `baseempresarial` → ambiente `production` → serviço
   `postgres` → aba **Advanced**: trocar o campo **Docker Image** de
   `postgres:17` para `ghcr.io/<owner>/baseempresarial-postgres:17-atual`.
3. **Conferir o volume:** `baseempresarial-postgres-ujnn8y-data` deve
   permanecer montado em `/var/lib/postgresql/data` — é onde vivem os
   116 GB. Não recriar, não renomear.
4. Definir limites de recursos do serviço: **Memory Limit 4 GB /
   Reservation 2 GB**.
5. **Redeploy** (~30 s de indisponibilidade do banco).
6. Validar:

   ```sql
   SHOW shared_buffers;              -- 2GB
   SHOW shared_preload_libraries;    -- pg_stat_statements
   SHOW random_page_cost;            -- 1.5
   SELECT count(*) FROM estabelecimento;  -- contagem de amostra intacta
   ```

Rollback: voltar o campo Docker Image para `postgres:17` e Redeploy.

### Perfis dedicados (tarefa F7 — instância nova)

1. Provisionar a máquina da rota escolhida (F5) com rede privada/vSwitch e
   firewall que exponha o 5432 **apenas** à rede privada.
2. Preparar o bind no NVMe local: `mkdir -p /data/pgdata` (nunca volume de
   rede).
3. Usar `docker-compose.dedicada-64.yml` (ou `-128`) como referência: no
   Dokploy, criar o serviço com a imagem do perfil, montar `/data/pgdata`
   em `/var/lib/postgresql/data`, `shm_size` 4 GB, limite de memória
   56G/112G, envs `POSTGRES_PASSWORD` e `DADOS_READ_PASSWORD`.
4. Primeira subida em volume vazio executa o initdb (extensões + role).
5. Validar `pg_settings` como acima (esperado: `shared_buffers` 16GB/32GB,
   `random_page_cost` 1.1).
6. Ativar backups: snapshot Hetzner do servidor + pgBackRest (`backup/`).

## Validação local

```bash
# Perfil atual completo:
PROFILE=atual docker compose -f docker-compose.local.yml up --build -d

# Perfis dedicados (memória sobrescrita — valida o restante da conf):
PROFILE=dedicada-64 LOW_MEM_OVERRIDE="-c shared_buffers=512MB -c effective_cache_size=1GB" \
    docker compose -f docker-compose.local.yml up --build -d

docker compose -f docker-compose.local.yml exec postgres \
    psql -U postgres -d dados_cnpj \
    -c "SELECT name, setting FROM pg_settings WHERE name IN
        ('shared_buffers','random_page_cost','shared_preload_libraries','jit','max_parallel_workers');"
```
