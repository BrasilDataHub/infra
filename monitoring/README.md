# monitoring

Observabilidade da infraestrutura BrasilDataHub: Prometheus, Alertmanager,
Grafana, sondas de caixa-preta e os coletores de escopo de máquina. Quatro
imagens: `ghcr.io/brasildatahub/prometheus` (config e regras embutidas),
`ghcr.io/brasildatahub/grafana` (provisioning e dashboards),
`ghcr.io/brasildatahub/alertmanager` (roteamento, inibição e a janela de
silenciamento do ETL) e `ghcr.io/brasildatahub/blackbox-exporter` (os módulos
das classes de SLO).

É o único módulo que observa os outros. Os **exporters de Postgres e Redis não
estão aqui** — vivem no diretório do serviço que observam, porque a DSN, os
coletores desligados e os timeouts são fatos sobre aquele serviço:

| Onde | O quê |
|---|---|
| [`../postgres/docker-compose.metrics.yml`](../postgres/docker-compose.metrics.yml) | `postgres_exporter` + a role `metrics_read` |
| [`../redis/docker-compose.metrics.yml`](../redis/docker-compose.metrics.yml) | `redis_exporter` |
| [`../meilisearch/docker-compose.metrics.yml`](../meilisearch/docker-compose.metrics.yml) | liga o `/metrics` nativo (não há exporter) |
| `monitoring/` | Prometheus, Alertmanager, Grafana, blackbox, node exporter, cAdvisor |

Tudo isso é **opcional**: nada sobe sem `--metrics`, e os composes de produção
dos três serviços continuam idênticos.

## Como os pedaços se enxergam

Cada serviço sobe como um projeto Compose separado (`docker compose -p postgres`),
e projetos não compartilham rede. A ligação é uma rede Docker chamada
`bdh_metrics`: o exporter fica em **duas** redes — a do seu projeto, para falar
com o serviço por DNS interno (`postgres:5432`), e a `bdh_metrics`, para ser
coletado pelo Prometheus.

```
projeto postgres          projeto redis            projeto monitoring
┌─────────────────┐       ┌─────────────────┐      ┌──────────────────────┐
│ postgres        │       │ redis           │      │ prometheus ── grafana│
│    ↑ DNS interno│       │    ↑            │      │     ↑                │
│ postgres-exporter       │ redis-exporter  │      │ node-exporter        │
└────────┼────────┘       └────────┼────────┘      └──────┼───────────────┘
         └──────────────── bdh_metrics ──────────────────┘
```

### Alertmanager: por que ele existe

Antes dele havia **18 regras de alerta validadas e sem destino nenhum**. O
Alertmanager é o que as faz chegar a alguém, e traz três coisas que um contact
point do Grafana não daria:

- **`silence`.** O runbook mensal começa com "silence do Alertmanager por 6 h" e
  termina com "remover o silence". É um recurso do Alertmanager; o alerting do
  Grafana só roteia regras gerenciadas pelo próprio Grafana, e estas são
  avaliadas pelo Prometheus.
- **Janela de ETL.** Cinco alertas — `IOSaturado`, `CacheHitBaixo`,
  `MuitosArquivosTemporarios`, `CheckpointsForcadosDemais` e
  `PostgresConexoesPertoDoLimite` — são falsos positivos **legítimos** durante a
  carga mensal. Sem silenciá-los, a operação aprende a ignorá-los, o que é pior
  que não ter alerta.
- **Inibição.** Host fora do ar cala o que roda nele; sonda que falha cala o p95
  do mesmo alvo.

**O container RECUSA subir sem um destino configurado.** É deliberado: um
Alertmanager que não notifica ninguém reproduziria o estado que ele veio
corrigir, com a aparência de resolvido.

### blackbox_exporter: o que substitui o Pulse

Antes dele **não existia uma métrica de TTFB no sistema**. O Laravel Pulse media
latência por dentro e custava uma transação no banco por requisição pública —
100% das inserções do banco da aplicação. O blackbox mede por fora, com retenção
e histórico, e mede o que o usuário experimenta: TLS, borda e origem.

Há um módulo por classe da tabela de SLO, e três deles sondam a **mesma URL** de
propósito, porque fazem perguntas diferentes:

| Módulo | Pergunta | Falha significa |
|---|---|---|
| `borda_hit` | a borda está servindo? | a Cache Rule caiu ou a resposta virou incachável |
| `condicional_304` | o `Last-Modified` está sendo emitido? | o crawl do Googlebot volta a 314 dias |
| `anonima_sem_cookie` | a rota pública continua sem sessão? | **estado de login vazando para o cache público** |

**Nenhum exporter publica porta no host.** O `/metrics` não tem autenticação e o
do Postgres entrega o `pg_settings_*` inteiro; expô-lo daria de graça o que o
resto da stack protege com senha. O Prometheus os alcança pelo nome do **serviço**
Compose, que o Docker registra como alias na rede compartilhada — por isso o
endereço não depende do nome do projeto.

### Quando o Prometheus fica em outro host

Nesta operação ele fica: Prometheus no `bdh-apps`, dados no `bdh-data`, sem rede
privada entre os dois. O nome de serviço Compose não atravessa hosts, então os
exporters remotos precisam publicar porta — o que os overlays
`*/docker-compose.metrics-remote.yml` e `docker-compose.remote.yml` fazem, com
`METRICS_BIND_IP` **obrigatória e sem default**. A proteção passa a ser o
firewall restrito ao IP do par, e a sonda `PortaDeDadosAlcancavelDeFora` existe
para pegar a regressão dessa regra. Detalhes em [`targets/`](targets/README.md).

A rede é declarada **sem `external: true`**, e isso é deliberado. Com `external`,
um `docker network prune` com os containers parados faria o `docker compose up`
do **próprio banco** falhar com `network declared as external, but could not be
found`. Do jeito atual, o primeiro projeto a subir cria a rede, os demais reusam,
e se ela sumir o próximo `up` a recria. O Compose emite um aviso cosmético
(`a network with name bdh_metrics exists but was not created for project ...`);
silenciá-lo com `external: true` reintroduz a falha.

## Perfis

O eixo é o orçamento de memória do Prometheus, como nos demais módulos. Retenção
e alvos suportados são derivados.

| Perfil | Séries ativas | Retenção | `PROM_MEMORY_LIMIT` | Quando usar |
|---|---|---|---|---|
| `metricas-512mb` | ~3 mil | 30d / 2GB | **512M** | default; um host com os três serviços |
| `metricas-2gb` | ~15 mil | 90d / 20GB | **2G** | um host com cAdvisor, ou 2–4 hosts |
| `metricas-8gb` | ~80 mil | 180d / 200GB | **8G** | 5–15 hosts |

Medido num host com os três serviços e o node exporter: **3.470 séries ativas** e
**~67 amostras/s** — bem dentro do `metricas-512mb`.

**O `auto` deste módulo não escala com a RAM**, ao contrário do Redis e do
Meilisearch. A cardinalidade segue o **número de alvos**, não o tamanho do host:
os mesmos três serviços geram ~3 mil séries tanto numa máquina de 16 GB quanto
numa de 128 GB. Então `--metrics-profile auto` resolve para `metricas-512mb` em
qualquer tamanho, e sobe para `metricas-2gb` apenas com `--metrics-containers`
(o cAdvisor sozinho dobra o volume de séries). **`metricas-8gb` nunca é
automático**: ele existe para 5–15 hosts, um cenário multi-host que o
`infra-setup.sh` não conhece — escolha-o à mão se for federar máquinas.

Cada perfil é um `.env` versionado em [`profiles/`](profiles/), o mesmo arquivo
que o [`infra-setup.sh`](../README.md#setup-automatizado-de-vps) baixa.

**As duas retenções são sempre declaradas.** A de tempo sozinha não protege o
disco: um pico de cardinalidade enche o volume — que divide o NVMe com o
Postgres — muito antes de os 30 dias passarem. Este é o pior modo de falha da
stack, a ferramenta de observação derrubando o observado.

Se a monitoração dividir o host com o Postgres, some ~2 GB (ou ~3 GB com
cAdvisor) à [fórmula de coexistência](../postgres/docs/perfis.md#fórmula-de-reserva).
O `infra-setup.sh` avisa quando o orçamento não fecha.

## Acesso

Grafana e Prometheus publicam em **`127.0.0.1`**, o oposto dos serviços de dados
— e por um motivo concreto: Postgres, Redis e Meilisearch abrem em `0.0.0.0`
porque a aplicação vive em outra máquina e a senha é a barreira, enquanto o
**Prometheus não tem autenticação nenhuma**. Quem alcança a porta lê tudo e chama
`/api/v1/admin/tsdb/*`.

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 usuario@host
# depois: http://127.0.0.1:3000  (usuário admin, senha em secrets/credentials.env)
```

A variável é `MONITORING_BIND_IP`, **separada** de `BIND_IP` de propósito: o
default do provisionamento é `--bind-ip 0.0.0.0`, e reusá-la publicaria o Grafana
na internet.

Efeito colateral bom: com bind em loopback o DNAT do Docker só existe para
destino loopback, então **nenhuma regra de firewall é necessária**. É o único
caso nesta infraestrutura em que a [armadilha do `DOCKER-USER`](../postgres/docs/host.md#rede)
não morde. Se você mudar `MONITORING_BIND_IP` para uma interface real, aí sim as
regras passam a valer — e `ufw allow 3000` sozinho não protegeria nada.

## Implantação

O caminho normal é o provisionamento automatizado:

```bash
# instalação nova, já com observabilidade
sudo bash infra-setup.sh --auto --metrics

# acrescentar observabilidade a uma instalação que JÁ existe, sem recriar
# os containers de dados
sudo bash infra-setup.sh --metrics-only
```

`--metrics-only` é o modo para ligar métricas num banco em produção: ele implica
`--force` (para reconfigurar) mas **suprime o `--force-recreate`**, então o
Compose cria apenas o container novo. Verificado: Postgres e Redis preservados.
O Meilisearch é a exceção inerente — ligar o `/metrics` é uma variável de
ambiente do próprio serviço, então o container é recriado; faça numa janela sem
indexação.

À mão:

```bash
BASE=https://raw.githubusercontent.com/BrasilDataHub/infra/main/monitoring
curl -fsSL "$BASE/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$BASE/profiles/metricas-512mb.env" -o .env

cat >> .env <<'EOF'
GRAFANA_ADMIN_PASSWORD=uma-senha-longa-e-aleatoria
MON_HOSTNAME=vps-bdh-01
COMPOSE_PROFILES=node          # +containers para o cAdvisor
EOF
chmod 600 .env

# obrigatório ANTES do primeiro up (ver abaixo)
mkdir -p targets secrets && touch secrets/meili-metrics.key

# um arquivo por serviço que existe neste host
printf '[{"targets":["postgres-exporter:9187"]}]\n' > targets/postgres.json
printf '[{"targets":["redis-exporter:9121"]}]\n'    > targets/redis.json
printf '[{"targets":["node-exporter:9100"]}]\n'     > targets/node.json

docker compose up -d
```

**Por que `touch secrets/meili-metrics.key` é obrigatório:** o job do Meilisearch
usa `credentials_file`, e o Prometheus recusa a configuração **inteira** se o
arquivo não existir — um host sem Meilisearch ficaria sem monitoração nenhuma por
causa disso. O arquivo é montado com `create_host_path: false`, então a falta
dele falha no `up` com o caminho exato, em vez de o Docker criar um diretório
fantasma e o erro aparecer obscuro lá dentro.

**Por que os alvos ficam em arquivos, e não no `prometheus.yml`:** o que varia
entre hosts são os alvos, e `file_sd_configs` é o mecanismo nativo para isso —
com recarga a quente, sem restart. Serviço que não existe não deixa arquivo, o
glob não casa nada e o job fica **sem alvo** em vez de ficar `up == 0` para
sempre, envenenando justamente o alerta que mais importa.

## Operação

```bash
bdh metrics          # alvos, alertas disparando e séries por job
bdh logs monitoring
```

Recarregar alvos sem reiniciar (o `--web.enable-lifecycle` já está ligado):

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

## Dashboards

Provisionados na pasta **BrasilDataHub**, marcados como não editáveis pela UI —
o git é a fonte da verdade, como nos composes e nos perfis.

| Dashboard | Origem |
|---|---|
| **Visão geral — BrasilDataHub** | escrito para esta operação; comece por ele |
| Node Exporter Full | grafana.com 1860 |
| PostgreSQL Database | grafana.com 9628 |
| Redis | grafana.com 763 |

Os três de comunidade são vendorizados por [`grafana/vendorizar.sh`](grafana/vendorizar.sh)
e alguns painéis ficam vazios por decisões conscientes de coleta — o que e por
quê está em [`grafana/dashboards/UPSTREAM.md`](grafana/dashboards/UPSTREAM.md).

Alertas: as regras vivem no Prometheus ([`prometheus/rules/`](prometheus/rules/)),
com testes unitários; a notificação usa o alerting unificado do Grafana, que
dispensa um Alertmanager e casa com o `--webhook-url` que o script já tem. Ver
[`docs/alertas.md`](docs/alertas.md).

## Ressalvas no macOS

O `infra-setup.sh` **não liga** o node exporter nem o cAdvisor no macOS, por duas
razões medidas:

1. eles leem o `/proc` da **VM do Docker**, não do Mac — "disco cheio" no painel
   significaria o disco virtual;
2. o kernel da VM não traz `CONFIG_PSI`, então `/proc/pressure` não existe e o
   coletor `pressure` falha (`node_scrape_collector_success{collector="pressure"} = 0`).
   Em Ubuntu 22.04+ e Debian 12 o PSI vem habilitado e o painel de pressão de IO
   funciona.

Prometheus, Grafana e os exporters de Postgres/Redis/Meilisearch funcionam
normalmente no macOS.

## Validação local

```bash
bash test/prometheus-config.test.sh   # promtool + alertas + dashboards + perfis
docker build -t bdh-prometheus:local prometheus/
docker build -t bdh-grafana:local grafana/
```

O build das duas imagens roda `promtool check config`, `check rules` e a
validação dos dashboards — config inválida não chega a virar imagem publicada.
