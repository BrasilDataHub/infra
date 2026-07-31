# Ambiente Docker da BrasilDataHub

Este repositório centraliza a configuração da stack Docker utilizada por alguns projetos da [BrasilDataHub](https://github.com/BrasilDataHub). As imagens são reutilizáveis entre diferentes aplicações, enquanto as configurações específicas de cada projeto, como variáveis de ambiente, volumes e limites de recursos, permanecem definidas no ambiente de deploy.

## Serviços

| Serviço | Imagem | Documentação |
|---|---|---|
| PostgreSQL | `ghcr.io/brasildatahub/postgres:17` — imagem única, tuning por envs `PG_*`, perfis **dedicados** de 8 a 128 GB e o **compartilhado** `compartilhada-14gb`, todos com NVMe local ([perfis](postgres/docs/perfis.md), [deploy](postgres/docs/deploy.md), [troubleshooting](postgres/docs/troubleshooting.md), [preparação do host](postgres/docs/host.md)) | [`postgres/`](postgres/) |
| Backup | `ghcr.io/brasildatahub/pgbackrest:17` — sidecar do Postgres: backup físico, WAL archiving, PITR e **restore ensaiado** que mede o RTO real. Repositório em **object storage** ou em **volume local** | [`postgres/backup/`](postgres/backup/README.md) |
| Redis | `ghcr.io/brasildatahub/redis:7` — perfis `cache-256mb`–`cache-2gb`; e o **par** cache/fila em instâncias separadas, com políticas incompatíveis entre si | [`redis/`](redis/README.md), [par](redis/README-par.md) |
| PgBouncer | `ghcr.io/brasildatahub/pgbouncer:1` — transaction pooling, 400 clientes sobre 20 conexões reais. Roda no host da **aplicação** | [`pgbouncer/`](pgbouncer/README.md) |
| OpenSearch | `ghcr.io/brasildatahub/opensearch:3` — o motor de busca, mapping versionado, perfis `compartilhada-8gb` e `dedicada-16gb` | [`opensearch/`](opensearch/README.md) |
| Meilisearch | `ghcr.io/brasildatahub/meilisearch:1.34` — wrapper pinado, perfis `busca-512mb`–`busca-16gb`. **Em substituição** pelo OpenSearch | [`meilisearch/`](meilisearch/) |
| Observabilidade | `prometheus:3`, `grafana:13`, `alertmanager` e `blackbox-exporter` — **opcional**, perfis `metricas-512mb`–`metricas-8gb` | [`monitoring/`](monitoring/) |
| Aplicação (Laravel) | `ghcr.io/brasildatahub/laravel-app:8.4` (FrankenPHP + Octane), `laravel-worker:8.4` (fila, Horizon, scheduler) e `laravel-builder:8.4` (Composer + Node, só build) — a stack de aplicação que os verticais **herdam** em vez de reconstruir ([uso em novas aplicações](laravel/docs/uso-em-novas-aplicacoes.md), [versionamento](laravel/docs/versionamento.md)) | [`laravel/`](laravel/README.md) |

Cada pasta tem seu README com as variáveis de configuração, os perfis por
máquina e o passo a passo de implantação.

> **`laravel/` é a exceção da lista**, e de propósito: são imagens **base**, não
> serviços. Não têm compose, perfil, entrada no `setup.sh` nem alvo no
> Prometheus — quem as consome é um `FROM` no Dockerfile de uma aplicação, e
> quem define limites, réplicas e variáveis é o compose do projeto.

> **Implantando do zero?** A ordem entre os repositórios da operação
> (`plataforma`, `baseempresarial-services`, `baseempresarial-web`) e o que
> depende de quê está no
> [runbook de implantação](https://github.com/BrasilDataHub/docs/blob/main/roadmap/20-arquitetura-de-busca-2026-07/IMPLANTACAO.md).
> Este README cobre a parte de infraestrutura; ele sozinho não é suficiente.

## Como implantar

**Docker Compose direto no host** — cada pasta traz o compose de produção e os
perfis em [`<serviço>/profiles/*.env`](postgres/profiles/); o deploy é copiar os
dois e acrescentar as senhas. Se um painel (Dokploy, Coolify) for obrigatório,
use-o em modo **Compose stack** com o mesmo YAML, nunca em modo banco
gerenciado.

> ⚠️ **Um perfil tem três partes — envs, limite de memória e `/dev/shm` — e só a
> primeira é variável de ambiente.** As outras duas são recursos do container, e
> `shm_size` é **descartado sem aviso pelo Docker Swarm** (base do Dokploy): foi
> o que custou 6h43 de ETL na Base Empresarial. A receita do repositório usa um
> mount `tmpfs`, que funciona nos dois casos —
> [postgres/docs/deploy.md](postgres/docs/deploy.md).

Por que Compose, com a comparação entre as alternativas:
[postgres/docs/estrategia-deploy.md](postgres/docs/estrategia-deploy.md).

### Dados em volumes nomeados

Os três serviços usam o **mesmo padrão**: volume nomeado com o driver `local`.

| Serviço | Volume | Dentro do container |
|---|---|---|
| PostgreSQL | `bdh_pg_data` | `/var/lib/postgresql/data` |
| Redis | `bdh_redis_data` | `/data` |
| Meilisearch | `bdh_meili_data` | `/meili_data` |

**Por que volume nomeado, e não bind mount** — a decisão é deliberada, então não
a reverta sem novo contexto:

- todas as instâncias da org rodam em **NVMe**, inclusive no disco de sistema;
- nesse cenário bind mount **não é mais rápido**: o volume nomeado também é um
  diretório no filesystem do host, e a camada de storage é a mesma;
- volume nomeado usa o **driver padrão do Docker**, sem diretórios a criar,
  donos a ajustar ou variáveis de caminho — menos superfície de configuração
  customizada e comportamento igual em qualquer ambiente.

O que o bind garantia era *qual* disco. Isso virou uma **verificação explícita**:
volumes vivem sob o data-root do Docker, então confirme que ele está no NVMe
(`docker info -f '{{.DockerRootDir}}'`). Se não estiver, há duas saídas
documentadas — mover o data-root ou dar backing de diretório ao volume nomeado:
[host.md](postgres/docs/host.md#quando-o-nvme-não-é-o-disco-do-docker).

> ⚠️ `docker compose down -v` apaga os volumes. Use `down` sem `-v`.

### Acesso pela rede

Por default os três serviços publicam suas portas em `0.0.0.0` — ficam
alcançáveis de qualquer origem, inclusive da internet, com a senha como única
barreira. É conveniente para máquinas de aplicação em outras redes, e exige
senhas longas e aleatórias. Para restringir: `BIND_IP` numa interface privada,
firewall por origem ou VPN — ver
[host.md, Rede](postgres/docs/host.md#rede).

Quando mais de um destes serviços dividir o mesmo host, dimensione a máquina
pela [fórmula de coexistência](postgres/docs/perfis.md#fórmula-de-reserva).

## Setup automatizado de VPS

[`setup.sh`](setup.sh) provisiona uma máquina nova do zero: sistema,
Docker, layout de diretórios, `.env` de cada serviço, containers no ar, firewall,
mensagem de login e o comando `bdh`. É **opcional** — o fluxo manual de
[deploy.md](postgres/docs/deploy.md) continua valendo.

**Plataformas.** Ubuntu/Debian com systemd (servidor, requer root) e **macOS**
(estação de trabalho ou Mac mini como servidor). No macOS o script usa o Docker
já instalado — Docker Desktop, OrbStack ou Colima —, roda sem `sudo`
(configuração em `~/.config/brasildatahub`, `bdh` em `~/.local/bin`), não mexe em
firewall nem em arquivos de login, e dimensiona o perfil pela **memória da VM do
Docker**, não pela do host — que é o que de fato limita os containers. Ignoradas
no macOS: `--docker-version`, `--docker-data-root`, `--skip-system-update` e
`--allow-from`.

### Receitas prontas

**Máquina nova, tudo no ar com observabilidade.** Um comando; o script dimensiona
todos os serviços pela RAM da máquina:

```bash
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh \
  | sudo bash -s -- --auto --metrics
```

**O mesmo, mas restrito à rede privada** — é o que se roda num servidor de
verdade, exposto à internet:

```bash
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh \
  | sudo bash -s -- --auto --metrics \
      --bind-ip 10.0.0.5 \
      --allow-from 10.0.0.0/8 \
      --postgres-db dados_cnpj
```

`--bind-ip` publica os bancos só na interface privada e `--allow-from` restringe
a origem no `ufw` **e** na chain `DOCKER-USER`. Grafana e Prometheus não são
afetados: ficam em `127.0.0.1` de qualquer forma (veja
[Observabilidade](#observabilidade)).

**Acrescentar métricas a uma máquina que já está rodando**, sem recriar os
containers de dados:

```bash
sudo bash setup.sh --metrics-only
```

**Outras variações** que aparecem com frequência:

```bash
# interativo (pergunta serviços, perfis, modo de volume, rede)
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh -o setup.sh
sudo bash setup.sh

# só Postgres e Redis — o Postgres recebe a máquina inteira
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh \
  | sudo bash -s -- --auto --services postgres,redis --allow-from 10.0.0.0/8

# dados fora do disco do Docker (NVMe montado em outro ponto)
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh \
  | sudo bash -s -- --auto --volumes bind --data-dir /mnt/nvme

# métricas por container (cAdvisor) e Grafana numa interface privada
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh \
  | sudo bash -s -- --auto --metrics --metrics-containers --metrics-bind-ip 10.0.0.5

sudo bash setup.sh --help      # todas as opções
```

Baixar e revisar antes de executar é a forma recomendada: o script roda como
root e altera o sistema.

### Como o `--auto` dimensiona a máquina

Todos os perfis vêm em `auto`, e o dimensionamento é **coordenado**: Redis,
Meilisearch, OpenSearch e métricas são escolhidos primeiro, e o **Postgres fica
com o que sobra** — a
[fórmula de reserva](postgres/docs/perfis.md#fórmula-de-reserva) aplicada
sozinha. Com `--services postgres`, ele recebe a máquina inteira.

A tabela abaixo é o caso de `--services postgres,redis,meilisearch` (o default),
mais observabilidade:

| RAM do host | Postgres | Redis | Meilisearch | Métricas | Soma dos limites |
|---|---|---|---|---|---|
| 16 GB | `dedicada-8gb` | `cache-512mb` | `busca-1gb` | `metricas-512mb` | ~12 GB |
| 32 GB | `dedicada-16gb` | `cache-1gb` | `busca-4gb` | `metricas-512mb` | ~24 GB |
| 64 GB | `dedicada-32gb` | `cache-2gb` | `busca-16gb` | `metricas-512mb` | ~53 GB |
| 128 GB | `dedicada-64gb` | `cache-2gb` | `busca-16gb` | `metricas-512mb` | ~85 GB |

**O OpenSearch não escolhe por RAM — escolhe por companhia.** Ele não entra na
tabela acima porque a regra dele é de outra natureza: o que decide o perfil é
estar ou não sozinho no host.

| Situação | Perfil | Limite do container | Heap | vCPU |
|---|---|---|---|---|
| Ao lado de Postgres, Redis ou Meilisearch | `compartilhada-8gb` | 8 GiB | 4 GiB | 6 |
| Sozinho no host, com **≥ 14 GiB** de RAM | `dedicada-16gb` | 10 GiB | 5 GiB | 4 |
| Sozinho, mas abaixo de 14 GiB | `compartilhada-8gb` | 8 GiB | 4 GiB | 6 |
| Máquina de **desenvolvimento** rodando a arquitetura inteira em ~16 GiB | `dev-4gb` | 4 GiB | 2 GiB | 2 |

A última linha **não é automática**: `dev-4gb` só entra com
`--opensearch-profile dev-4gb` explícito. É o único perfil que cabe num host
pequeno com Postgres, Redis, PgBouncer e observabilidade juntos, e é também o
que ninguém quer ver selecionado sozinho num servidor —
[`opensearch/README.md`](opensearch/README.md#dev-4gb-não-é-escolhido-pelo-auto).

O último caso não é engano: `dedicada-16gb` pede 10 GiB de limite, e numa máquina
menor que isso o container simplesmente não subiria. Detalhe do porquê, e o que
custa aplicar o perfil errado, em [`opensearch/README.md`](opensearch/README.md#perfis).

O que sobra não é desperdício: vira page cache, que é exatamente o ativo pelo
qual se paga uma máquina grande para banco de dados — e, no caso do OpenSearch, é
onde os segmentos quentes do Lucene ficam residentes, já que o `mmap` não conta
no RSS do cgroup.

Algumas observações que costumam pegar de surpresa:

- **8 GB não comporta os três serviços mais observabilidade.** `dedicada-8gb` é o
  piso do catálogo, então a soma estoura e o script avisa. As saídas são
  `--services` menor, `--no-monitoring` ou uma máquina maior.
- **O perfil de métricas não cresce com a RAM.** A cardinalidade do Prometheus
  segue o **número de alvos**, não o tamanho do host: os três serviços geram
  ~3 mil séries tanto em 16 quanto em 128 GB. `metricas-2gb` entra só com
  `--metrics-containers`, e `metricas-8gb` nunca é automático (é para 5–15 hosts).
- **Máquina de tamanho intermediário recebe o perfil de baixo.** O catálogo é
  discreto e a escolha é por faixa: um host de 48 GB dedicado ao Postgres fica
  com `dedicada-32gb` e ~19 GiB fora do limite do container. O script **avisa**
  quando isso acontece e aponta a receita de ajuste — ver
  [e se a máquina não tem o tamanho de nenhum perfil](postgres/docs/perfis.md#e-se-a-máquina-não-tem-o-tamanho-de-nenhum-perfil).

**CPU não é limitada.** Postgres, Redis e Meilisearch sobem sem teto de CPU e
usam todos os núcleos da máquina. A exceção é o OpenSearch, que traz teto em
**os dois** perfis: 6 vCPU em `compartilhada-8gb` — dimensionado para dividir o
host com o banco — e 4 vCPU em `dedicada-16gb`, que roda em máquina menor. O
número está no `OS_CPU_LIMIT` de cada perfil.

Qualquer perfil pode ser fixado à mão — `--pg-profile dedicada-32gb`,
`--redis-profile cache-1gb`, `--meili-profile busca-4gb`,
`--opensearch-profile dedicada-16gb`, `--metrics-profile metricas-2gb` —, e
`--profiles-dir` lê de um clone local.

Os valores de cada perfil ficam **só** nos arquivos `.env` versionados
(`postgres/profiles/`, `redis/profiles/`, `meilisearch/profiles/`,
`opensearch/profiles/`, `monitoring/profiles/`): o script os baixa em vez de
embutir cópias, então doc, script e deploy manual usam exatamente os mesmos
números.

> **Ao trocar de perfil, substitua o `.env` — não acrescente por baixo.** Um
> `.env` com o perfil antigo seguido das variáveis do novo *funciona*, porque o
> Compose faz a última definição vencer, mas passa a mentir sobre si mesmo: o
> arquivo diz no cabeçalho que é um perfil e entrega outro. Foi assim que o
> `bdh-search` acabou com o cabeçalho de `compartilhada-8gb` e os valores de
> `dedicada-16gb` — e a ficha de infraestrutura passou a documentar 4 GiB de heap
> onde rodavam 5.

### O que fica onde

```
/opt/brasildatahub/                        (--workdir)
├── services/                              um diretório por serviço provisionado
│   ├── postgres/
│   │   ├── docker-compose.yml             baixado deste repositório
│   │   ├── docker-compose.metrics.yml     com --metrics
│   │   ├── docker-compose.metrics-remote.yml
│   │   ├── docker-compose.backup.yml      com o backup implantado
│   │   ├── docker-compose.backup-local.yml  repositório em volume local
│   │   ├── docker-compose.override.yml    só no modo --volumes bind
│   │   └── .env                           gerado, chmod 600
│   ├── redis/
│   ├── meilisearch/
│   ├── opensearch/                        com --services/--add-service opensearch
│   ├── pgbouncer/                         idem
│   └── monitoring/                        com --metrics
├── secrets/credentials.env                todas as credenciais, chmod 600
├── .metrics-remote.env                    METRICS_BIND_IP, lido como ambiente
├── setup.log
└── .setup-state                           ref, perfil, modo de volume, data
/etc/brasildatahub/setup.conf              aponta para a raiz acima
/usr/local/bin/bdh                          comandos de operação
/etc/update-motd.d/99-brasildatahub         mensagem de login
/etc/pgbackrest/pgbackrest.conf             só com o backup: fora do git, 0640, dono 999:999
```

Os overlays não são opcionais na hora de subir: quem compõe a linha de comando é
o `bdh`, e ele inclui **todos** os que existirem no diretório do serviço, nesta
ordem — base → metrics → metrics-remote → backup → backup-local → override.
Subir na mão com um `-f` a menos é como o `archive_mode` volta a `off` sem que
nada acuse.

Operar cada serviço é entrar no diretório dele e usar o Compose normalmente
(`cd /opt/brasildatahub/services/postgres && docker compose logs -f`), ou usar os
atalhos:

```bash
bdh status                # serviços, portas, diretórios e volumes
bdh logs postgres -f
bdh up|down|restart redis # down nunca remove volume
bdh verify postgres       # /dev/shm, limite de memória, conf aceita
bdh creds [--show]        # onde estão as credenciais
```

Ao entrar por SSH, a mensagem de login mostra os serviços em execução, as portas
e esses caminhos. `--no-motd` desliga essa parte.

### Credenciais

Ficam em `/opt/brasildatahub/secrets/credentials.env` (`chmod 600`) e também no
`.env` de cada serviço. Senhas omitidas nas flags são geradas com 32 bytes
aleatórios. Numa reexecução, as credenciais existentes são **preservadas** — o
volume do Postgres já foi inicializado com aquela senha, e mudar o arquivo não a
alteraria.

### Rodar de novo

Há três modos, e escolher o errado é caro.

| Comando | O que faz | Recria containers? |
|---|---|---|
| `--update` | **o modo normal de reexecução.** Herda tudo do `.setup-state` e reaplica. Flag explícita sobrescreve; ausência **herda** | só o que mudou |
| `--add-service NOME` | acrescenta `opensearch`, `pgbouncer`, … sem tocar no que já existe. Implica `--update` | só o serviço novo |
| `--force` | refaz `.env` e composes **do zero**, sem herdar nada | **todos** |

`--update` existe para eliminar um contorno que custava caro: antes dele, uma
reexecução exigia repetir `--postgres-db`, `--bind-ip` e `--allow-from` **de
cor**, e esquecer qualquer um recriava o banco, reexpunha as portas e esvaziava
o firewall. Com ele, o estado da instalação original é a fonte da verdade.

**A terceira coluna é o que separa os modos na prática.** Só `--force` passa
`--force-recreate`; nos outros dois o Compose compara a definição desejada com
a atual e recria apenas o que de fato mudou — perfil novo, imagem nova, overlay
novo. Um `--update` que só reescreve um alvo do Prometheus não encosta no
Postgres.

> ⚠️ **Mesmo assim, `--update` não é operação de janela livre.** Ele recria o
> que mudou, e "o que mudou" inclui o banco sempre que o perfil, a imagem ou um
> overlay mudarem. Um restart do Postgres derruba conexões abertas — um ETL com
> cursor server-side morre com `AdminShutdown` a horas do início. Rode
> atualizações com os pipelines parados, ou depois de confirmar que não há
> carga em andamento.

Nenhum dos três **remove volumes**: os dados permanecem. Trocar o modo de volume
(`named` ↔ `bind`) numa instalação existente é recusado, porque a troca não move
dados — copie-os antes:

```bash
docker run --rm -v bdh_pg_data:/from -v /mnt/nvme/postgres:/to alpine cp -a /from/. /to/
```

### Serviços acrescentados depois

Os módulos do roadmap 20 entram por `--add-service`, um de cada vez, sem recriar
os containers de dados:

```bash
sudo bash setup.sh --add-service opensearch
sudo bash setup.sh --add-service pgbouncer
sudo bash setup.sh --add-service monitoring
```

Serviços aceitos: `postgres`, `redis`, `meilisearch`, `opensearch`, `pgbouncer`
e `monitoring`.

Ao acrescentar o `opensearch`, o script também ajusta **`vm.max_map_count`** e o
persiste em `/etc/sysctl.d/99-brasildatahub.conf`. Os dois passos importam: com
o default do Debian (65530), o container morre no bootstrap check com uma
mensagem que fala de `vm.max_map_count` e **não** de OpenSearch — e quem lê
procura o problema no lugar errado. Sem a persistência, o valor volta no próximo
boot e o motor não sobe junto com o host, o que transforma um reboot de rotina em
incidente.

### Acesso e exposição

Por default o script publica as portas em `0.0.0.0` e libera 5432/6379/7700 no
`ufw` para **qualquer origem** — inclusive a internet, com a senha como única
barreira. Escolha consciente, para que máquinas de aplicação em outras redes
conectem sem VPN. Para reduzir exposição:

| Flag | Efeito |
|---|---|
| `--allow-from 10.0.0.0/8` | libera as portas só para esses CIDRs (ufw **e** chain `DOCKER-USER`) |
| `--bind-ip 10.0.0.5` | publica apenas na interface privada |
| `--no-firewall` | script não mexe no ufw (você configura) |

O SSH é liberado **antes** de o firewall ser ativado, na porta detectada em
`sshd_config`.

> ⚠️ **`ufw allow from … to any port 5432` sozinho não restringe container
> nenhum.** O tráfego para containers passa por `FORWARD → DOCKER-USER`, e o ufw
> só filtra `INPUT` — a regra aparece no `ufw status` e não bloqueia nada.
> Por isso o `--allow-from` também escreve regras na chain `DOCKER-USER`
> (persistidas em `/etc/ufw/after.rules`). Se for configurar à mão, siga
> [host.md, Rede](postgres/docs/host.md#ufw-não-filtra-portas-publicadas-pelo-docker).

## Observabilidade

Desligada por default. `--metrics` acrescenta Prometheus, Grafana, node exporter
e um exporter por serviço; nada disso muda os composes de produção dos serviços
de dados.

Nem todo serviço precisa de exporter: **Meilisearch e OpenSearch publicam
`/metrics` nativamente** e são raspados direto. **PgBouncer não é coletado hoje**
— não há exporter nem alvo para ele, e as estatísticas ficam só no `SHOW STATS`
do console de administração.

```bash
# instalação nova, já com observabilidade
... | sudo bash -s -- --auto --metrics

# acrescentar a uma instalação que JÁ existe, sem recriar os containers de dados
sudo bash setup.sh --metrics-only

bdh metrics        # alvos, alertas disparando e séries por job
```

O exporter de cada serviço mora no **diretório daquele serviço**
(`postgres/docker-compose.metrics.yml`), num overlay opcional: a DSN, os
coletores desligados e os timeouts são fatos sobre o Postgres, não sobre o
Prometheus. Eles conversam por uma rede Docker `bdh_metrics` e **nenhum exporter
publica porta no host** — `/metrics` não tem autenticação.

`--metrics-only` é o modo para ligar métricas num banco em produção: implica
`--force` mas suprime o `--force-recreate`, então só o container do exporter é
criado. A exceção é o Meilisearch, onde a feature é uma variável de ambiente e a
recriação é inerente — aplique numa janela sem indexação.

> ⚠️ **Grafana e Prometheus publicam em `127.0.0.1`, ao contrário dos serviços de
> dados.** O Prometheus não tem autenticação nenhuma: quem alcança a porta lê
> tudo e chama `/api/v1/admin/tsdb/*`. Use um túnel SSH
> (`ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 usuario@host`). A variável
> é `MONITORING_BIND_IP`, separada de `BIND_IP` justamente para que o default
> `--bind-ip 0.0.0.0` não os exponha.

Cada alvo é escrito com o rótulo `host`, o nome da máquina de onde a série veio.
É ele que sustenta a seção **Infraestrutura** da visão geral do Grafana — um
inventário de quais servidores existem e o que cada um roda, mais uma seção que
se repete por servidor. Em all-in-one vira um bloco; com os serviços espalhados,
um bloco por máquina. Para coleta remota, `--metrics-scrape` aceita o nome depois
do endereço (`postgres=10.0.0.5:9187@bdh-data`), e o host observado imprime a
linha pronta para colar.

A monitoração consome ~2 GB de RAM (~3 GB com o cAdvisor), que entram na
[fórmula de coexistência](postgres/docs/perfis.md#fórmula-de-reserva) — o script
avisa quando o orçamento não fecha com o perfil do Postgres escolhido. Detalhes,
perfis e alertas em [`monitoring/`](monitoring/).

## Publicação

As imagens são **públicas** no GHCR (pull sem autenticação); este
repositório permanece privado. A CI
(`.github/workflows/build-publish.yml`) builda e publica a cada push na
`main` que toque a pasta do serviço.

**Só a imagem afetada é reconstruída.** Os `paths:` do topo do workflow são do
workflow, não dos jobs: eles decidem se ele roda — e, uma vez disparado, todos
os jobs rodariam junto. Um job `changes` lê o diff do push e libera cada build
individualmente, para que mudar duas linhas do `redis/Dockerfile` não reconstrua
as imagens de aplicação, cujo build multi-arch compila 14 extensões PHP sob
emulação e leva dezenas de minutos.

Duas consequências que valem saber:

- **commit de documentação não publica nada** — nem `README.md`, nem `docs/`,
  nem os overlays de compose e os `profiles/*.env`, que não entram em imagem
  nenhuma;
- **mudar o próprio `build-publish.yml` também não republica**, e é deliberado:
  era esse o caminho pelo qual um ajuste de comentário reconstruía a stack
  inteira. Para republicar à mão use **`workflow_dispatch`**, que aceita
  escolher uma imagem ou `todos`.

O mapa de escopos vive dentro do workflow e é verificado por
[`test/filtro-build.test.sh`](test/filtro-build.test.sh), que o lê de lá em vez
de manter uma cópia — uma cópia divergiria no primeiro serviço novo. O teste
protege os dois lados do erro: padrão frouxo custa tempo de build à toa; padrão
estreito demais faz a imagem **deixar de publicar em silêncio**.

```bash
docker pull ghcr.io/brasildatahub/postgres:17
docker pull ghcr.io/brasildatahub/redis:7
docker pull ghcr.io/brasildatahub/meilisearch:1.34
docker pull ghcr.io/brasildatahub/laravel-app:8.4
docker pull ghcr.io/brasildatahub/laravel-worker:8.4
docker pull ghcr.io/brasildatahub/laravel-builder:8.4
```

As três imagens de aplicação são as únicas publicadas em **multi-arch**
(`linux/amd64` e `linux/arm64`): são consumidas em tempo de build, inclusive nas
estações Apple Silicon da equipe. As de infraestrutura rodam só em servidor e
continuam `amd64`.
