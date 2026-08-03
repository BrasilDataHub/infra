# targets/

## Papel

Diretório de alvos do Prometheus via `file_sd_configs`. Vazio no repositório de propósito: os alvos são do host, não da imagem. No servidor: `/opt/brasildatahub/services/monitoring/targets/`, montado read-only; recarga a quente sem restart.

## Componentes / imagem

Um arquivo JSON por serviço presente no host:

```json
[{"targets": ["postgres-exporter:9187"], "labels": {"host": "bdh-data"}}]
```

| Arquivo | Conteúdo | rótulo `host` |
|---|---|---|
| `postgres.json` | `postgres-exporter:9187` | sim |
| `redis.json` | `redis-exporter:9121` | sim |
| `meilisearch.json` | `meilisearch:7700` (nativo) | sim |
| `opensearch.json` | `opensearch:9200` (plugin na imagem) | sim |
| `node.json` | `node-exporter:9100` | sim |
| `cadvisor.json` | `cadvisor:8080` | sim |
| `blackbox.json` | URLs das sondas (formato próprio) | **não** |

Endereços = nomes de **serviço** Compose na rede `bdh_metrics` (não nomes de container).

## Perfis e configuração

### Rótulo `host`

Único rótulo de máquina gravado no TSDB. Sem ele: inventário da visão geral vazio, `ServidorSemColeta` sem agrupamento, painéis de disco sem origem.

Não confundir com `external_labels: host` no `prometheus.yml` (não grava no TSDB; só remote_write/federação/Alertmanager). Os dois convivem: external labels preenchem alertas `absent()`.

Valor = `hostname` cru (igual a `node_uname_info.nodename`). Apelido quando o hostname não serve (Swarm, nomes de provedor):

```bash
bash setup.sh --update --host-label bdh-apps
```

Vence o hostname só nos alvos **locais**; remotos usam `@apelido` de `--metrics-scrape`. Mesmo valor vai para `MON_HOSTNAME` (node_exporter).

`blackbox.json` sem `host`: alvo é URL, não máquina.

Serviço inexistente → sem arquivo → job sem alvo (não `up == 0` permanente). `setup.sh --metrics` escreve conforme serviços selecionados.

```bash
bdh metrics
```

### Prometheus em outro host

| Cenário | Como fica |
|---|---|
| All-in-one | nomes de serviço Compose; nada publica porta |
| Um host por serviço | `--metrics-publish` nos exporters; `--metrics-scrape` no coletor |
| Misto | glob `<job>*.json` mistura local e remoto |

Alvo remoto:

```json
[{"targets": ["10.0.0.5:9187"], "labels": {"host": "host-de-dados"}}]
```

```bash
bash setup.sh --update --metrics-scrape \
  postgres=10.0.0.5:9187@host-de-dados,redis=10.0.0.5:9121@host-de-dados,\
node=10.0.0.5:9100@host-de-dados
```

IPv6: `node=[fe80::1]:9100@host-de-dados`. Usar hostname real como apelido. Arquivos `*-remoto` são do script (reescreve/apaga no `--update`); alvos manuais: outro sufixo (`postgres-extra.json`).

Publicar no host remoto:

```bash
METRICS_BIND_IP=<ip-do-bdh-data> docker compose \
  -f docker-compose.yml \
  -f docker-compose.metrics.yml \
  -f docker-compose.metrics-remote.yml up -d
```

`METRICS_BIND_IP` sem default. Sem rede privada: firewall `--allow-from` (sonda `PortaDeDadosAlcancavelDeFora`).

### `blackbox.json`

```json
[
  { "targets": ["https://basedosdados.exemplo.br/"],
    "labels": { "module": "borda_hit", "classe": "borda-hit" } },

  { "targets": ["https://basedosdados.exemplo.br/"],
    "labels": { "module": "condicional_304", "classe": "condicional-304" } },

  { "targets": ["https://basedosdados.exemplo.br/empresa/00000000000191"],
    "labels": { "module": "empresa_por_cnpj", "classe": "empresa-cnpj" } },

  { "targets": ["https://basedosdados.exemplo.br/brasil/sp/sao-paulo/comercio"],
    "labels": { "module": "hub_territorial", "classe": "hub-cidade-cnae" } },

  { "targets": ["https://basedosdados.exemplo.br/api/v1/autocomplete?q=padaria"],
    "labels": { "module": "autocomplete", "classe": "autocomplete" } },

  { "targets": ["https://basedosdados.exemplo.br/buscar?q=padaria"],
    "labels": { "module": "busca", "classe": "busca-avancada" } },

  { "targets": ["https://basedosdados.exemplo.br/"],
    "labels": { "module": "anonima_sem_cookie", "classe": "regressao-cabecalho" } }
]
```

Mesma URL em módulos distintos: `borda_hit` exige `cf-cache-status: HIT`; `condicional_304` exige 304; `anonima_sem_cookie` falha com `Set-Cookie`.

Porta que deve estar fechada:

```json
[{ "targets": ["<ip-do-bdh-data>:15432"],
   "labels": { "module": "tcp_conecta", "esperado": "fechado" } }]
```

Sondar de host fora da allow-list.

## Deploy / operação

Escrita automática: `setup.sh --metrics` / `--update`. Conferência: `bdh metrics`. Recarga Prometheus: `curl -X POST http://127.0.0.1:9090/-/reload`.

## Variáveis e segredos

Nenhum segredo neste diretório. Chave Meilisearch: `../secrets/meili-metrics.key`. Remoto: `METRICS_BIND_IP` no compose do exporter.

## Restrições

- `/metrics` sem autenticação; remoto sem rede privada = firewall ao IP do par.
- Apelido ≠ hostname real quebra links do dashboard (painel e `bdh metrics` denunciam).
- Acrescentar rótulo encerra séries antigas (`rate()`/`increase()` por poucos minutos).

## Links

- [`../README.md`](../README.md)
- [`../docs/alertas.md`](../docs/alertas.md)
