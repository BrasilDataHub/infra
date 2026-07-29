# targets/

Este diretório está **vazio no repositório** de propósito: os alvos são do host,
não da imagem. No servidor ele fica em
`/opt/brasildatahub/services/monitoring/targets/` e é montado read-only no
Prometheus, que o relê a quente — acrescentar um arquivo aqui não exige restart.

Um arquivo por serviço que existe no host:

```json
[{"targets": ["postgres-exporter:9187"]}]
```

| Arquivo | Conteúdo |
|---|---|
| `postgres.json` | `postgres-exporter:9187` |
| `redis.json` | `redis-exporter:9121` |
| `meilisearch.json` | `meilisearch:7700` (endpoint nativo, sem exporter) |
| `node.json` | `node-exporter:9100` |
| `cadvisor.json` | `cadvisor:8080` |
| `blackbox.json` | as URLs das sondas — formato próprio, ver abaixo |

Os endereços são nomes de **serviço** Compose, não de container: na rede
`bdh_metrics` o Docker registra o nome do serviço como alias, então eles não
dependem do nome do projeto Compose.

**Serviço que não existe não deve ter arquivo.** O `prometheus.yml` usa um glob
por job, então a ausência do arquivo deixa o job *sem alvo* — em vez de deixá-lo
`up == 0` para sempre, o que envenenaria o alerta `AlvoForaDoAr`, que é o mais
importante da stack.

O `infra-setup.sh --metrics` escreve estes arquivos conforme os serviços
selecionados. Para conferir o que o Prometheus enxerga:

```bash
bdh metrics
```

---

## Quando o Prometheus está em OUTRO host

É o caso desta operação: o Prometheus vai no `bdh-apps`, e Postgres, Redis e o
motor de busca ficam no `bdh-data` (a justificativa está em
`03-arquitetura-de-busca.md` §3.2). **Não há rede privada entre os dois** — eles
se falam por IP público, em blocos /22 diferentes.

O nome de serviço Compose só resolve dentro do host. Então, para os alvos
remotos, o arquivo usa `IP:porta`:

```json
[{"targets": ["10.0.0.5:9187"], "labels": {"host": "bdh-data"}}]
```

E o host remoto precisa **publicar** a porta do exporter, com os overlays feitos
para isso:

```bash
# no bdh-data
METRICS_BIND_IP=<ip-do-bdh-data> docker compose \
  -f docker-compose.yml \
  -f docker-compose.metrics.yml \
  -f docker-compose.metrics-remote.yml up -d
```

`METRICS_BIND_IP` **não tem default**: um `0.0.0.0` acidental entregaria
`pg_settings_*` inteiro para a internet. E a proteção real é o firewall
restrito ao IP do par (item 8 do roadmap 20) — a sonda
`PortaDeDadosAlcancavelDeFora` existe para pegar a regressão dessa regra.

O rótulo `host` no arquivo de alvos é o que faz um alerta dizer **de qual
máquina** ele veio; sem ele, dois hosts com o mesmo problema viram uma
notificação só.

---

## `blackbox.json` — formato próprio

O job `blackbox` não coleta do alvo: ele pede ao `blackbox-exporter` que
**sonde** o alvo. Por isso o `targets` é a URL a sondar, e o módulo vai num
rótulo:

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

A **mesma URL** aparece em módulos diferentes de propósito: `borda_hit` exige
`cf-cache-status: HIT`, `condicional_304` exige resposta 304, e
`anonima_sem_cookie` falha se aparecer `Set-Cookie`. Três perguntas distintas
sobre o mesmo endereço, e cada uma com uma correção distinta.

### Sondar uma porta que DEVE estar fechada

A inversão útil: um alvo com `esperado: "fechado"` faz o alerta
`PortaDeDadosAlcancavelDeFora` disparar quando a sonda **tem** sucesso.

```json
[{ "targets": ["<ip-do-bdh-data>:15432"],
   "labels": { "module": "tcp_conecta", "esperado": "fechado" } }]
```

Sonde a partir de um host que **não** está na allow-list — do contrário a sonda
mede a regra errada. Na prática: este alvo mora no `blackbox.json` do
`bdh-apps` apenas se o `bdh-apps` não estiver liberado para aquela porta.
