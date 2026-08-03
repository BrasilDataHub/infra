# Ambiente Docker da BrasilDataHub

Configuração da stack Docker reutilizável entre projetos da [BrasilDataHub](https://github.com/BrasilDataHub). As imagens são compartilhadas; variáveis, volumes e limites ficam no ambiente de deploy de cada projeto.

## Serviços

| Serviço | Imagem | Documentação |
|---|---|---|
| PostgreSQL | `ghcr.io/brasildatahub/postgres:17` — tuning por envs `PG_*`, perfis dedicados 8–128 GB e `compartilhada-14gb` ([perfis](postgres/docs/perfis.md), [deploy](postgres/docs/deploy.md), [troubleshooting](postgres/docs/troubleshooting.md), [host](postgres/docs/host.md)) | [`postgres/`](postgres/) |
| Backup | `ghcr.io/brasildatahub/pgbackrest:17` — sidecar: backup físico, WAL, PITR, restore ensaiado; repositório em object storage ou volume local | [`postgres/backup/`](postgres/backup/README.md) |
| Redis | `ghcr.io/brasildatahub/redis:7` — perfis `cache-256mb`–`cache-2gb`; [par](redis/README-par.md) cache/fila em instâncias separadas | [`redis/`](redis/README.md) |
| PgBouncer | `ghcr.io/brasildatahub/pgbouncer:1` — transaction pooling (400 clientes / 20 conexões); roda no host da aplicação | [`pgbouncer/`](pgbouncer/README.md) |
| OpenSearch | `ghcr.io/brasildatahub/opensearch:3` — motor de busca; mapping versionado; perfis `compartilhada-8gb`, `dedicada-16gb`, `dev-4gb` | [`opensearch/`](opensearch/README.md) |
| Meilisearch | `ghcr.io/brasildatahub/meilisearch:1.34` — wrapper pinado; perfis `busca-512mb`–`busca-16gb`; provisionável para outros projetos | [`meilisearch/`](meilisearch/) |
| Observabilidade | Prometheus, Grafana, Alertmanager, blackbox-exporter — opcional; perfis `metricas-512mb`–`metricas-8gb` | [`monitoring/`](monitoring/) |
| Aplicação (Laravel) | `laravel-app:8.4`, `laravel-worker:8.4`, `laravel-builder:8.4` — imagens base herdadas pelos verticais ([uso](laravel/docs/uso-em-novas-aplicacoes.md), [versionamento](laravel/docs/versionamento.md)) | [`laravel/`](laravel/README.md) |

`laravel/` não é serviço Compose: não tem perfil, entrada no `setup.sh` nem alvo no Prometheus. Consumo via `FROM` no Dockerfile da aplicação.

Runbook de ordem entre repositórios (`plataforma`, `baseempresarial-services`, `baseempresarial-web`): [IMPLANTACAO.md](https://github.com/BrasilDataHub/docs/blob/main/roadmap/20-arquitetura-de-busca-2026-07/IMPLANTACAO.md).

## Como implantar

Docker Compose direto no host: compose de produção + perfil em [`<serviço>/profiles/*.env`](postgres/profiles/), com senhas acrescentadas. Se um painel (Dokploy, Coolify) for obrigatório, use modo **Compose stack** — nunca banco gerenciado.

Um perfil tem três partes: envs, limite de memória e `/dev/shm`. Só a primeira é variável de ambiente. `shm_size` é descartado sem aviso pelo Docker Swarm; o compose do repositório usa mount `tmpfs` — ver [deploy.md](postgres/docs/deploy.md).

### Volumes

| Serviço | Volume | Dentro do container |
|---|---|---|
| PostgreSQL | `bdh_pg_data` | `/var/lib/postgresql/data` |
| Redis | `bdh_redis_data` | `/data` |
| Meilisearch | `bdh_meili_data` | `/meili_data` |
| OpenSearch | (ver compose) | dados do índice |

Padrão: volume nomeado com driver `local`. Confirme que o data-root do Docker está no NVMe (`docker info -f '{{.DockerRootDir}}'`). Alternativas: [host.md](postgres/docs/host.md#quando-o-nvme-não-é-o-disco-do-docker).

`docker compose down -v` apaga volumes — use `down` sem `-v`.

### Rede

Por default as portas de dados publicam em `0.0.0.0`. Restrinja com `BIND_IP`, firewall por origem ou VPN — [host.md, Rede](postgres/docs/host.md#rede).

Coexistência no mesmo host: [fórmula de reserva](postgres/docs/perfis.md#fórmula-de-reserva).

## Setup automatizado (`setup.sh`)

Provisiona máquina nova: sistema, Docker, layout, `.env`, containers, firewall, MOTD e comando `bdh`. Opcional — o fluxo manual de [deploy.md](postgres/docs/deploy.md) permanece válido.

**Plataformas.** Ubuntu/Debian com systemd (root) e macOS (Docker Desktop/OrbStack/Colima; config em `~/.config/brasildatahub`; sem firewall/MOTD; perfil pela RAM da VM Docker). Ignoradas no macOS: `--docker-version`, `--docker-data-root`, `--skip-system-update`, `--allow-from`.

### Receitas

```bash
# Máquina nova com observabilidade (perfis pela RAM)
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh \
  | sudo bash -s -- --auto --metrics

# Rede privada
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh \
  | sudo bash -s -- --auto --metrics \
      --bind-ip 10.0.0.5 \
      --allow-from 10.0.0.0/8 \
      --postgres-db dados_cnpj

# Métricas em instalação existente (sem recriar containers de dados)
sudo bash setup.sh --metrics-only

# Interativo / subset / bind mount / cAdvisor
sudo bash setup.sh
... | sudo bash -s -- --auto --services postgres,redis --allow-from 10.0.0.0/8
... | sudo bash -s -- --auto --volumes bind --data-dir /mnt/nvme
... | sudo bash -s -- --auto --metrics --metrics-containers --metrics-bind-ip 10.0.0.5
sudo bash setup.sh --help
```

Baixe e revise antes de executar: o script roda como root.

### Dimensionamento `--auto`

Redis, Meilisearch, OpenSearch e métricas são escolhidos primeiro; o Postgres fica com o restante ([fórmula](postgres/docs/perfis.md#fórmula-de-reserva)). Com `--services postgres`, recebe a máquina inteira.

Caso `--services postgres,redis,meilisearch` + observabilidade:

| RAM do host | Postgres | Redis | Meilisearch | Métricas | Soma dos limites |
|---|---|---|---|---|---|
| 16 GB | `dedicada-8gb` | `cache-512mb` | `busca-1gb` | `metricas-512mb` | ~12 GB |
| 32 GB | `dedicada-16gb` | `cache-1gb` | `busca-4gb` | `metricas-512mb` | ~24 GB |
| 64 GB | `dedicada-32gb` | `cache-2gb` | `busca-16gb` | `metricas-512mb` | ~53 GB |
| 128 GB | `dedicada-64gb` | `cache-2gb` | `busca-16gb` | `metricas-512mb` | ~85 GB |

OpenSearch escolhe por companhia, não só por RAM:

| Situação | Perfil | Limite | Heap | vCPU |
|---|---|---|---|---|
| Ao lado de Postgres/Redis/Meilisearch | `compartilhada-8gb` | 8 GiB | 4 GiB | 6 |
| Sozinho, ≥ 14 GiB | `dedicada-16gb` | 10 GiB | 5 GiB | 4 |
| Sozinho, &lt; 14 GiB | `compartilhada-8gb` | 8 GiB | 4 GiB | 6 |
| Dev (~16 GiB, stack completa) | `dev-4gb` | 4 GiB | 2 GiB | 2 |

`dev-4gb` só com `--opensearch-profile dev-4gb` explícito.

Notas:

- 8 GB não comporta três serviços + métricas; o script avisa.
- Perfil de métricas não cresce com a RAM (cardinalidade = número de alvos). `metricas-2gb` com `--metrics-containers`; `metricas-8gb` nunca é automático.
- Host intermediário recebe o perfil inferior da faixa; o script avisa — [perfis.md](postgres/docs/perfis.md#e-se-a-máquina-não-tem-o-tamanho-de-nenhum-perfil).
- CPU sem teto em Postgres/Redis/Meilisearch; OpenSearch usa `OS_CPU_LIMIT` do perfil.

Override: `--pg-profile`, `--redis-profile`, `--meili-profile`, `--opensearch-profile`, `--metrics-profile`, `--profiles-dir`.

Valores só nos `.env` versionados sob `*/profiles/`. Ao trocar perfil, **substitua** o `.env` inteiro — não acrescente variáveis por baixo (a última definição vence e o cabeçalho mente).

### Layout no host

```
/opt/brasildatahub/                        (--workdir)
├── services/                              um diretório por serviço
│   ├── postgres/                          compose + overlays + .env
│   ├── redis/ | meilisearch/ | opensearch/ | pgbouncer/ | monitoring/
├── secrets/credentials.env                chmod 600
├── .metrics-remote.env
├── setup.log
└── .setup-state
/etc/brasildatahub/setup.conf
/usr/local/bin/bdh
/etc/update-motd.d/99-brasildatahub
/etc/pgbackrest/pgbackrest.conf            com backup (0640, 999:999)
```

`bdh` inclui todos os overlays presentes, nesta ordem: base → metrics → metrics-remote → backup → backup-local → override. Subir à mão com `-f` a menos pode desligar `archive_mode` sem aviso.

```bash
bdh status
bdh logs postgres -f
bdh up|down|restart redis   # down nunca remove volume
bdh verify postgres
bdh creds [--show]
```

### Credenciais

`/opt/brasildatahub/secrets/credentials.env` e o `.env` de cada serviço. Senhas omitidas: 32 bytes aleatórios. Reexecução preserva credenciais existentes.

### Reexecução

| Comando | Efeito | Recria containers? |
|---|---|---|
| `--update` | Herda `.setup-state`; flag explícita sobrescreve | só o que mudou |
| `--add-service NOME` | Acrescenta serviço; implica `--update` | só o novo |
| `--force` | Refaz `.env` e composes do zero | todos |

Só `--force` passa `--force-recreate`. `--update` ainda recria o que mudou (perfil, imagem, overlay) — rode com pipelines parados se o Postgres for afetado. Nenhum modo remove volumes. Troca `named` ↔ `bind` é recusada sem cópia prévia dos dados.

```bash
sudo bash setup.sh --add-service opensearch
sudo bash setup.sh --add-service pgbouncer
sudo bash setup.sh --add-service monitoring
```

Serviços: `postgres`, `redis`, `meilisearch`, `opensearch`, `pgbouncer`, `monitoring`.

OpenSearch: o script ajusta e persiste `vm.max_map_count` em `/etc/sysctl.d/99-brasildatahub.conf` (default Debian 65530 falha no bootstrap).

### Exposição

| Flag | Efeito |
|---|---|
| `--allow-from CIDR` | ufw **e** chain `DOCKER-USER` |
| `--bind-ip IP` | publica só na interface |
| `--no-firewall` | script não mexe no ufw |

SSH é liberado antes de ativar o firewall. `ufw allow … port 5432` sozinho não filtra containers (`FORWARD` → `DOCKER-USER`) — [host.md](postgres/docs/host.md#ufw-não-filtra-portas-publicadas-pelo-docker).

## Observabilidade

Desligada por default. `--metrics` acrescenta Prometheus, Grafana, node exporter e exporters por serviço, sem alterar composes de produção dos dados.

Meilisearch e OpenSearch expõem `/metrics` nativamente. PgBouncer não é coletado (só `SHOW STATS`).

```bash
... | sudo bash -s -- --auto --metrics
sudo bash setup.sh --metrics-only
bdh metrics
```

Exporters ficam no diretório do serviço (`docker-compose.metrics.yml`), na rede `bdh_metrics`, sem porta no host. `--metrics-only` cria só o exporter (exceto Meilisearch, onde a feature é env e recria o container).

Grafana e Prometheus em `127.0.0.1` (`MONITORING_BIND_IP`, separado de `BIND_IP`). Túnel: `ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 usuario@host`.

Alvos usam rótulo `host`. Coleta remota: `--metrics-scrape postgres=10.0.0.5:9187@bdh-data`. Orçamento ~2 GB (~3 GB com cAdvisor) — [monitoring/](monitoring/).

## Publicação

Imagens públicas no GHCR. CI (`.github/workflows/build-publish.yml`): push em `main` que toque a pasta do serviço; job `changes` libera só a imagem afetada.

- Commit só de documentação / overlays / profiles não publica.
- Mudança só no workflow não republica; use `workflow_dispatch`.
- Mapa de escopos: [`test/filtro-build.test.sh`](test/filtro-build.test.sh).

```bash
docker pull ghcr.io/brasildatahub/postgres:17
docker pull ghcr.io/brasildatahub/redis:7
docker pull ghcr.io/brasildatahub/meilisearch:1.34
docker pull ghcr.io/brasildatahub/laravel-app:8.4
docker pull ghcr.io/brasildatahub/laravel-worker:8.4
docker pull ghcr.io/brasildatahub/laravel-builder:8.4
```

Imagens Laravel: multi-arch (`amd64` + `arm64` em runner nativo). Infra: `amd64`.

## Build local

[`build.sh`](build.sh) espelha a CI (contextos, Dockerfiles, tags). Por default não publica.

```bash
bash build.sh --listar
bash build.sh laravel
bash build.sh laravel-app
bash build.sh monitoring/grafana
bash build.sh laravel --push
bash build.sh --help
```

Publicar exige `--push` e escopo `write:packages`:

```bash
gh auth refresh -h github.com -s write:packages
bash build.sh laravel --push --login
```

Catálogo lido de `build-publish.yml`; verificado por [`test/catalogo-build.test.sh`](test/catalogo-build.test.sh).
