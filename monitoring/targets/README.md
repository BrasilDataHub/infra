# targets/

Este diretório está **vazio no repositório** de propósito: os alvos são do host,
não da imagem. No servidor ele fica em
`/opt/brasildatahub/services/monitoring/targets/` e é montado read-only no
Prometheus, que o relê a quente — acrescentar um arquivo aqui não exige restart.

Um arquivo por serviço que existe no host:

```json
[{"targets": ["postgres-exporter:9187"], "labels": {"host": "bdh-data"}}]
```

| Arquivo | Conteúdo | `host` |
|---|---|---|
| `postgres.json` | `postgres-exporter:9187` | sim |
| `redis.json` | `redis-exporter:9121` | sim |
| `meilisearch.json` | `meilisearch:7700` (endpoint nativo, sem exporter) | sim |
| `opensearch.json` | `opensearch:9200` (plugin na imagem, sem exporter) | sim |
| `node.json` | `node-exporter:9100` | sim |
| `cadvisor.json` | `cadvisor:8080` | sim |
| `blackbox.json` | as URLs das sondas — formato próprio, ver abaixo | **não** |

Os endereços são nomes de **serviço** Compose, não de container: na rede
`bdh_metrics` o Docker registra o nome do serviço como alias, então eles não
dependem do nome do projeto Compose.

## O rótulo `host`

É o único rótulo que diz **de qual máquina** a série veio, e sem ele a seção de
infraestrutura da visão geral fica vazia, o alerta `ServidorSemColeta` não tem
por onde agrupar, e um painel como o de disco livre mostra o pior valor da frota
sem dizer de quem é.

**Não confunda com os `external_labels` do `prometheus.yml`.** Aquele `host` é
real, mas não é gravado no TSDB: ele só entra em `remote_write`, em federação e
nos alertas enviados ao Alertmanager. Toda consulta do Grafana é cega para ele.
Foi exatamente essa distinção que manteve a stack sem rótulo de máquina até
29/07/2026 — a configuração parecia correta e o dado não existia.

Os dois se complementam, e por isso o `external_labels` continua onde está: o
Prometheus só aplica external labels a rótulos **ausentes** na saída, então o
nome real da máquina vence nos alertas com série, e o nome do monitor sobra como
reserva para os alertas de `absent()`, que não têm série nenhuma de onde herdar.

O valor é o `hostname` cru da máquina, sem normalizar. Isso é deliberado: no
Linux `hostname` e `uname -n` leem o mesmo nodename do kernel, então o `host` do
alvo é byte a byte igual ao `nodename` que o node_exporter publica em
`node_uname_info`. É essa igualdade que permite cruzar as duas fontes — métricas
de serviço só têm `host`, métricas de máquina têm os dois — e é o que faz o link
do dashboard abrir no servidor certo.

`blackbox.json` fica de fora de propósito: ali o alvo é uma URL, não uma máquina,
e um `host` mentiria sobre o que está sendo medido.

### Quando o hostname não serve

Nem sempre dá para renomear a máquina. Num nó **Docker Swarm** o hostname está
registrado no cluster, e trocá-lo num manager arrisca desassociar o nó — num
manager único, isso derruba tudo que roda ali. Provedores também entregam
máquinas com nomes como `v2202607386618488113`, que viram rótulo e painel.

Para esses casos existe `--host-label`:

```bash
bash setup.sh --update --host-label bdh-apps
```

Ele vence o `hostname` **apenas para os alvos locais** — o nome de um alvo remoto
continua vindo do `@apelido` do `--metrics-scrape`. E como o mesmo valor vai para
`MON_HOSTNAME`, que o compose passa ao container do node_exporter, o `nodename`
acompanha: os dois seguem iguais e os links do dashboard continuam certos.

**Serviço que não existe não deve ter arquivo.** O `prometheus.yml` usa um glob
por job, então a ausência do arquivo deixa o job *sem alvo* — em vez de deixá-lo
`up == 0` para sempre, o que envenenaria o alerta `AlvoForaDoAr`, que é o mais
importante da stack.

O `setup.sh --metrics` escreve estes arquivos conforme os serviços
selecionados. Para conferir o que o Prometheus enxerga:

```bash
bdh metrics
```

---

## Quando o Prometheus está em OUTRO host

O módulo suporta os dois extremos e o meio entre eles, porque a topologia muda
com o orçamento e com o momento:

| Cenário | Como fica |
|---|---|
| **All-in-one** | serviços e Prometheus no mesmo host; os alvos são nomes de serviço Compose, nada publica porta. É o default |
| **Um host por serviço** | cada host publica seus exporters (`--metrics-publish`), e um host coleta todos (`--metrics-scrape`) |
| **Misto / sob demanda** | um host tem Postgres local e coleta um motor de busca remoto. O glob `<job>*.json` permite alvo local e remoto no mesmo job |

Nada aqui pressupõe uma máquina específica. O que muda entre os cenários é só
onde os arquivos de alvo apontam.

**Se não houver rede privada entre os hosts**, o firewall passa a ser a única
proteção: `/metrics` não tem autenticação nenhuma, e o do Postgres entrega
`pg_settings_*` inteiro. As regras precisam ser restritas ao IP do par
(`--allow-from`), nunca abertas ao mundo, e a sonda
`PortaDeDadosAlcancavelDeFora` existe para pegar a regressão dessa regra. Com
rede privada, aponte `METRICS_BIND_IP` e os alvos para o **IP privado** — é o
arranjo preferível, e o único em que a coleta não trafega pela internet.

O nome de serviço Compose só resolve dentro do host. Então, para os alvos
remotos, o arquivo usa `IP:porta`:

```json
[{"targets": ["10.0.0.5:9187"], "labels": {"host": "host-de-dados"}}]
```

Quem escreve isso é o `setup.sh`, a partir do `--metrics-scrape`, que aceita um
apelido depois do endereço:

```bash
# no host que roda o Prometheus
bash setup.sh --update --metrics-scrape \
  postgres=10.0.0.5:9187@host-de-dados,redis=10.0.0.5:9121@host-de-dados,\
node=10.0.0.5:9100@host-de-dados
```

O apelido vira o rótulo `host`. Sem ele, o rótulo cai para o endereço — funciona,
mas os painéis passam a mostrar `10.0.0.5` no lugar de um nome. IPv6 exige
colchetes: `node=[fe80::1]:9100@host-de-dados`.

**Use o hostname real da máquina como apelido.** O host observado imprime a linha
pronta para colar quando roda com `--metrics-publish` — ele conhece o próprio
`hostname` e o host do Prometheus não. Se os dois divergirem, o link do dashboard
abre a máquina errada em silêncio; o painel *"Apelidos que não batem com o
hostname real"* na visão geral e o `bdh metrics` existem para denunciar isso.

Os arquivos com sufixo `-remoto` são **reservados ao script**: ele os reescreve a
cada `--update` e os apaga quando o job sai do `--metrics-scrape`. Alvos escritos
à mão devem usar outro sufixo (`postgres-extra.json`), que o glob `postgres*.json`
casa igual.

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
