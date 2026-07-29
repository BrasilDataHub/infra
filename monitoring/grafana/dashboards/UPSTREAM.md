# Procedência dos dashboards

Três destes arquivos vêm do grafana.com e são **gerados** por `../vendorizar.sh`
— não os edite à mão: rode o script de novo e commite o resultado. Os outros três
são nossos, e esses sim são editados à mão (o `vendorizar.sh` não os toca).

| Arquivo | Origem | Revisão | Licença |
|---|---|---|---|
| `node.json` | [grafana.com/dashboards/1860](https://grafana.com/grafana/dashboards/1860) — Node Exporter Full | 45 | Apache-2.0 |
| `postgres.json` | [grafana.com/dashboards/9628](https://grafana.com/grafana/dashboards/9628) — PostgreSQL Database | 8 | Apache-2.0 |
| `redis.json` | [grafana.com/dashboards/763](https://grafana.com/grafana/dashboards/763) — Redis (redis_exporter 1.x) | 6 | MIT |
| `bdh-visao-geral.json` | escrito para esta operação | — | — |
| `opensearch.json` | escrito para esta operação | — | — |
| `meilisearch.json` | escrito para esta operação | — | — |

Vendorizados em 2026-07-27, contra `postgres_exporter v0.20.1`,
`redis_exporter v1.87.0` e `node_exporter v1.12.1`.

## O que o `vendorizar.sh` altera

1. Remove `__inputs`, `__requires` e `__elements` — blocos que só o import
   interativo do Grafana entende. Deixá-los faz o provisioning por arquivo
   carregar painéis apontando para um datasource inexistente, e o dashboard abre
   **em branco, sem erro nenhum**.
2. Troca toda referência de datasource pelo uid fixo `bdh-prometheus`.
3. Zera `id`, fixa `uid` e `version`.
4. Só no 9628: corrige as métricas de checkpoint para o PostgreSQL 17 (abaixo).

## Painéis que ficam vazios, e por quê

Isto é esperado — não é defeito de instalação.

**`postgres.json` (9628)** foi publicado antes do PostgreSQL 17, que moveu os
contadores de checkpoint de `pg_stat_bgwriter` para `pg_stat_checkpointer`. O
`vendorizar.sh` corrige três séries automaticamente:

| No dashboard original | Reescrito para |
|---|---|
| `pg_stat_bgwriter_buffers_checkpoint_total` | `pg_stat_checkpointer_buffers_written_total` |
| `pg_stat_bgwriter_checkpoint_write_time_total` | `pg_stat_checkpointer_write_time_total` |
| `pg_stat_bgwriter_checkpoint_sync_time_total` | `pg_stat_checkpointer_sync_time_total` |

Duas continuam sem dado, porque no PG17 foram para `pg_stat_io` e o
`postgres_exporter 0.20.1` ainda não expõe essa view:

- `pg_stat_bgwriter_buffers_backend_total`
- `pg_stat_bgwriter_buffers_backend_fsync_total`

Além disso, todo painel do 9628 que dependa de estatística **por tabela** fica
vazio: os coletores `stat_user_tables` e `statio_user_tables` estão desligados de
propósito, porque geram ~10 séries por tabela e por partição. A justificativa
completa está em `postgres/docs/metricas.md`.

O dashboard **Visão geral BrasilDataHub** (`bdh-visao-geral.json`) cobre o que
importa desta operação sem depender de nada disso — é por ele que se começa.

## Atualizando

```bash
cd monitoring/grafana && ./vendorizar.sh
git diff --stat dashboards/
```

Revise o diff: uma revisão nova pode passar a usar métricas de coletores que
desligamos, e o sintoma seria mais um painel vazio.
