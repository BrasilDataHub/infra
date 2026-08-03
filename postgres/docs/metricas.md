# Métricas do PostgreSQL

O que o `postgres_exporter` coleta, quanto custa e quais coletores estão
ligados/desligados. Stack: [`../../monitoring/`](../../monitoring/).

Pré-requisitos já na imagem: `pg_stat_statements` e `track_io_timing = on`
(`generate-config.sh`).

## Role `metrics_read`

| | |
|---|---|
| Privilégio | `pg_monitor` |
| Acesso a dados | **nenhum** |
| `statement_timeout` | `10s` |
| `idle_in_transaction_session_timeout` | `30s` |
| `CONNECTION LIMIT` | `5` |

Timeouts: scrape travado segura snapshot e atrasa autovacuum no ETL.
`CONNECTION LIMIT` protege `max_connections` (100 no `dedicada-8gb`) de restart
loop do exporter.

Script único idempotente:
[`../initdb/03-role-metrics.sh`](../initdb/03-role-metrics.sh).

- **Instalação nova:** roda no `initdb` após `02-role-dados-read.sh`.
- **Cluster existente:**

```bash
docker exec -i -e PG_METRICS_PASSWORD='...' \
    "$(docker ps -q --filter label=org.brasildatahub.service=postgres)" \
    bash -s < 03-role-metrics.sh
```

`setup.sh --metrics` faz o mesmo. Conferência:

```sql
SELECT rolname FROM pg_auth_members m
  JOIN pg_roles r ON r.oid = m.roleid
 WHERE member = 'metrics_read'::regrole;      -- deve listar pg_monitor
```

### Senha em `.env.metrics`

Como `DATA_SOURCE_PASS`, **não** no `.env`. Acrescentar variável ao `.env` muda
o hash do serviço e o Compose **recria o container do banco**. Com segredo à
parte, só o exporter é criado. CI testa essa regressão.

Redis: `redis_exporter` lê `REDIS_PASSWORD` já no `.env`.

## Coletores

Contra defaults do `postgres_exporter v0.20.1`.

### Desligados

| Coletor | Motivo |
|---|---|
| `stat_user_tables`, `statio_user_tables` | ~10 séries por tabela/partição a cada scrape |
| `replication`, `replication_slots`, `stat_replication` | sem réplica na org |
| `stat_statements` | default; **não ligue** — ver abaixo |

Custo de desligar `stat_user_tables`: perde `n_dead_tup` / `last_autovacuum` por
tabela. Reabilitar: remover `--no-collector.*` do overlay e observar
`count by (job) ({__name__=~".+"})`.

### Ligados (off por default no upstream)

| Coletor | Motivo |
|---|---|
| `stat_checkpointer` | PG17 moveu checkpoint para fora de `pg_stat_bgwriter` |
| `long_running_transactions` | ETL segurando `xmin` → bloat |
| `database_wraparound` | carga em massa → risco real |
| `stat_activity_autovacuum` | autovacuum vs ETL no mesmo IO |
| `postmaster` | uptime |

### `stat_statements` fora

`queryid` vira **label**. Com `pg_stat_statements.max` 5.000–10.000, ETL cria
séries que nunca mais recebem amostra. Extensão continua pré-carregada para
`psql`. Ligar como série temporal só por horas, com consciência do custo.

### `auto-discover-databases`

Desligado (deprecated no upstream). Multiplicaria séries × nº de bancos.

## Custo

| | |
|---|---|
| Séries | ~600 |
| Duração dos coletores | 0,6–5 ms cada |
| Scrape interval | **30s** (global é 15s) |
| `--collection-timeout` | `8s` (< `scrape_timeout` 10s) |

Janelas `rate()` nos dashboards de Postgres: ≥ `2m` (saudável = 4× scrape).
Timeout menor que scrape → coleta parcial em vez de scrape inteiro cair.

Vigiar:

```promql
pg_scrape_collector_duration_seconds{collector="database"}
```

`pg_database_size()` faz `stat()` em cada arquivo. Se >~1s consistente:
`--no-collector.database` (tamanho também via `node_filesystem_*`).

## Troubleshooting

- **`up == 0` + erro de autenticação:** role/senha — rode `03-role-metrics.sh`
  com senha de `.env.metrics`.
- **`WARN … postgres_exporter.yml: no such file`:** ruído esperado; config via
  flags/envs.
- **Painel "PostgreSQL Database" vazio:** depende de `stat_user_tables` ou
  métricas pré-PG17 — ver
  [`UPSTREAM.md`](../../monitoring/grafana/dashboards/UPSTREAM.md).
- **Séries por job explodiram:** `bdh metrics`; suspeite `stat_statements` ou
  `stat_user_tables` ligados e esquecidos.
