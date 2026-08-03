# monitoring

## Papel

Observabilidade da infraestrutura BrasilDataHub: Prometheus, Alertmanager, Grafana, blackbox e coletores de máquina. É o único módulo que observa os outros.

Exporters de Postgres, Redis e Meilisearch vivem no diretório do serviço observado. Tudo é opcional: nada sobe sem `--metrics`.

| Onde | O quê |
|---|---|
| [`../postgres/docker-compose.metrics.yml`](../postgres/docker-compose.metrics.yml) | `postgres_exporter` + role `metrics_read` |
| [`../redis/docker-compose.metrics.yml`](../redis/docker-compose.metrics.yml) | `redis_exporter` |
| [`../meilisearch/docker-compose.metrics.yml`](../meilisearch/docker-compose.metrics.yml) | liga `/metrics` nativo |
| `monitoring/` | Prometheus, Alertmanager, Grafana, blackbox, node exporter, cAdvisor |

## Componentes / imagem

| Imagem | Conteúdo |
|---|---|
| `ghcr.io/brasildatahub/prometheus` | config e regras embutidas |
| `ghcr.io/brasildatahub/grafana` | provisioning e dashboards |
| `ghcr.io/brasildatahub/alertmanager` | roteamento, inibição, janela de silêncio ETL |
| `ghcr.io/brasildatahub/blackbox-exporter` | módulos das classes de SLO |

Rede compartilhada `bdh_metrics` (declarada **sem** `external: true`): exporters ficam na rede do projeto + `bdh_metrics`; Prometheus coleta pelo nome do serviço Compose.

```
projeto postgres          projeto redis            projeto monitoring
┌─────────────────┐       ┌─────────────────┐      ┌──────────────────────┐
│ postgres        │       │ redis           │      │ prometheus ── grafana│
│ postgres-exporter       │ redis-exporter  │      │ node-exporter        │
└────────┼────────┘       └────────┼────────┘      └──────┼───────────────┘
         └──────────────── bdh_metrics ──────────────────┘
```

Nenhum exporter publica porta no host (all-in-one). Alertmanager **recusa subir** sem destino de notificação.

Módulos blackbox (mesma URL pode aparecer em módulos distintos):

| Módulo | Pergunta | Falha significa |
|---|---|---|
| `borda_hit` | a borda está servindo? | Cache Rule caiu ou resposta incachável |
| `condicional_304` | `Last-Modified` emitido? | crawl sem 304 |
| `anonima_sem_cookie` | rota pública sem sessão? | estado de login vazando para cache público |

Dashboards (pasta BrasilDataHub, não editáveis pela UI):

| Dashboard | Origem |
|---|---|
| Visão geral — BrasilDataHub | próprio |
| OpenSearch — motor de busca | próprio |
| Meilisearch — busca | próprio |
| Node Exporter Full | grafana.com 1860 |
| PostgreSQL Database | grafana.com 9628 |
| Redis | grafana.com 763 |

Comunidade vendorizada por [`grafana/vendorizar.sh`](grafana/vendorizar.sh); detalhes em [`grafana/dashboards/UPSTREAM.md`](grafana/dashboards/UPSTREAM.md). Alertas: [`prometheus/rules/`](prometheus/rules/), docs em [`docs/alertas.md`](docs/alertas.md).

## Perfis e configuração

| Perfil | Séries ativas | Retenção | `PROM_MEMORY_LIMIT` | Quando usar |
|---|---|---|---|---|
| `metricas-512mb` | ~3 mil | 30d / 2GB | **512M** | default; um host com os três serviços |
| `metricas-2gb` | ~15 mil | 90d / 20GB | **2G** | cAdvisor, ou 2–4 hosts |
| `metricas-8gb` | ~80 mil | 180d / 200GB | **8G** | 5–15 hosts |

`--metrics-profile auto` → `metricas-512mb`; sobe para `metricas-2gb` com `--metrics-containers`. `metricas-8gb` nunca é automático.

As duas retenções (tempo e tamanho) são sempre declaradas. Com coexistência Postgres, somar ~2 GB (~3 GB com cAdvisor) à [fórmula de coexistência](../postgres/docs/perfis.md#fórmula-de-reserva).

Rótulo `host` vai no **arquivo de alvos** (gravado no TSDB). `external_labels: host` no `prometheus.yml` não substitui — só entra em remote_write/federação/Alertmanager. Os dois convivem: external labels preenchem `absent()`.

## Deploy / operação

```bash
sudo bash setup.sh --auto --metrics          # instalação nova
sudo bash setup.sh --metrics-only            # acrescentar sem recriar dados
```

`--metrics-only` implica `--force` mas suprime `--force-recreate` (Postgres/Redis preservados; Meilisearch recria por mudança de env).

À mão:

```bash
BASE=https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/monitoring
curl -fsSL "$BASE/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$BASE/profiles/metricas-512mb.env" -o .env

cat >> .env <<'EOF'
GRAFANA_ADMIN_PASSWORD=uma-senha-longa-e-aleatoria
MON_HOSTNAME=vps-bdh-01
COMPOSE_PROFILES=node          # +containers para o cAdvisor
EOF
chmod 600 .env

mkdir -p targets secrets && touch secrets/meili-metrics.key

printf '[{"targets":["postgres-exporter:9187"]}]\n' > targets/postgres.json
printf '[{"targets":["redis-exporter:9121"]}]\n'    > targets/redis.json
printf '[{"targets":["node-exporter:9100"]}]\n'     > targets/node.json

docker compose up -d
```

`touch secrets/meili-metrics.key` é obrigatório: o job Meilisearch usa `credentials_file` e o Prometheus recusa a config inteira se o arquivo não existir.

Alvos em `file_sd_configs` (recarga a quente). Serviço ausente = sem arquivo = job sem alvo (não `up == 0`).

```bash
bdh metrics
bdh logs monitoring
curl -X POST http://127.0.0.1:9090/-/reload
```

Acesso (bind em loopback):

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 usuario@host
# http://127.0.0.1:3000 — admin / secrets/credentials.env
```

Atualizar alvos / rótulos:

```bash
bash setup.sh --update
bash setup.sh --update --metrics-scrape postgres=10.0.0.5:9187@bdh-data,...
```

Acrescentar rótulo encerra séries antigas e cria novas (`rate()`/`increase()` errados por poucos minutos nesse instante).

Prometheus em outro host: overlays `*/docker-compose.metrics-remote.yml` e `docker-compose.remote.yml`; `METRICS_BIND_IP` obrigatória sem default. Ver [`targets/`](targets/README.md).

macOS: `setup.sh` não liga node exporter nem cAdvisor (leem `/proc` da VM; sem `CONFIG_PSI`). Prometheus, Grafana e exporters de serviço funcionam.

```bash
bash test/prometheus-config.test.sh
docker build -t bdh-prometheus:local prometheus/
docker build -t bdh-grafana:local grafana/
```

## Variáveis e segredos

Perfis em [`profiles/`](profiles/) cobrem `PROM_*`, `GRAFANA_*` e limites. Segredos/host abaixo.

### Alertmanager — destino (ao menos um obrigatório)

| Variável | Descrição |
|---|---|
| `ALERTMANAGER_SLACK_WEBHOOK` | webhook Slack |
| `ALERTMANAGER_WEBHOOK_URL` | webhook genérico |
| `ALERTMANAGER_EMAIL_TO` | exige `ALERTMANAGER_SMTP_HOST` e `ALERTMANAGER_EMAIL_FROM` |

### Slack e e-mail

| Variável | Default | Descrição |
|---|---|---|
| `ALERTMANAGER_SLACK_CHANNEL` | `#alertas` | |
| `ALERTMANAGER_SMTP_HOST` | — | `host:porta` |
| `ALERTMANAGER_EMAIL_FROM` | — | |
| `ALERTMANAGER_SMTP_USER` / `_PASSWORD` | — | |
| `ALERTMANAGER_SMTP_TLS` | `true` | |

### Janela de ETL

Silencia notificação (não remove da UI) de: `IOSaturado`, `CacheHitBaixo`, `MuitosArquivosTemporarios`, `CheckpointsForcadosDemais`, `PostgresConexoesPertoDoLimite`.

| Variável | Default | Descrição |
|---|---|---|
| `ALERTMANAGER_ETL_TIMEZONE` | `America/Sao_Paulo` | |
| `ALERTMANAGER_ETL_DAYS_OF_MONTH` | `1:7` | primeira semana |
| `ALERTMANAGER_ETL_WEEKDAY` | `saturday` | |
| `ALERTMANAGER_ETL_START` / `_END` | `00:00` / `07:00` | |

### Agrupamento

| Variável | Default |
|---|---|
| `ALERTMANAGER_RESOLVE_TIMEOUT` | `10m` |
| `ALERTMANAGER_GROUP_WAIT` | `45s` |
| `ALERTMANAGER_GROUP_INTERVAL` | `5m` |
| `ALERTMANAGER_REPEAT_INTERVAL` | `4h` |
| `ALERTMANAGER_REPEAT_CRITICAL` | `1h` |

### Container

| Variável | Default | Descrição |
|---|---|---|
| `ALERTMANAGER_PORT` | `9093` | |
| `ALERTMANAGER_VOLUME` | `bdh_alertmanager_data` | |
| `BLACKBOX_PORT` | `9115` | |
| `MONITORING_BIND_IP` | `127.0.0.1` | Grafana/Prometheus; **separada** de `BIND_IP` |
| `METRICS_BIND_IP` | — (sem default) | overlays remotos |
| `NODE_TEXTFILE_DIR` | `/var/lib/node_exporter/textfile` | produtores e node_exporter devem concordar |
| `MON_HOSTNAME` | `desconhecido` | rótulo `host` |
| `GRAFANA_ADMIN_PASSWORD` | gerada | `secrets/credentials.env` |
| `GRAFANA_ROOT_URL` | `http://localhost:3000` | atrás de proxy |

## Restrições

- Prometheus sem autenticação — bind em `127.0.0.1`; mudar `MONITORING_BIND_IP` exige firewall.
- `/metrics` dos exporters sem auth; remoto sem rede privada depende de `--allow-from`.
- Sem `meili-metrics.key`, Prometheus recusa a config inteira.
- Com `external: true` na rede, `docker network prune` quebra o `up` do banco.

## Links

- [`targets/README.md`](targets/README.md)
- [`docs/alertas.md`](docs/alertas.md)
- [`grafana/dashboards/UPSTREAM.md`](grafana/dashboards/UPSTREAM.md)
- [Fórmula de coexistência](../postgres/docs/perfis.md#fórmula-de-reserva)
- [Rede / DOCKER-USER](../postgres/docs/host.md#rede)
