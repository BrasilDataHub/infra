# Procedência dos dashboards

Três JSONs vêm do grafana.com e são **gerados** por `../vendorizar.sh` — não
editar à mão. Os outros três são nossos (o script não os toca).

| Arquivo | Origem | Revisão | Licença |
|---|---|---|---|
| `node.json` | [grafana.com/dashboards/1860](https://grafana.com/grafana/dashboards/1860) — Node Exporter Full | 45 | Apache-2.0 |
| `postgres.json` | [grafana.com/dashboards/9628](https://grafana.com/grafana/dashboards/9628) — PostgreSQL Database | 8 | Apache-2.0 |
| `redis.json` | [grafana.com/dashboards/763](https://grafana.com/grafana/dashboards/763) — Redis (redis_exporter 1.x) | 6 | MIT |
| `bdh-visao-geral.json` | escrito para esta operação | — | — |
| `opensearch.json` | escrito para esta operação | — | — |
| `meilisearch.json` | escrito para esta operação | — | — |

## Re-vendorizar

```bash
cd monitoring/grafana && ./vendorizar.sh
git diff --stat dashboards/
```

O script: remove `__inputs` / `__requires` / `__elements`; troca datasource pelo
uid `bdh-prometheus`; zera `id` e fixa `uid`/`version`; no 9628 reescreve
métricas de checkpoint para PG17. Revise o diff — revisão nova pode referenciar
coletores desligados.
