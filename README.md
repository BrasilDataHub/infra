# Infraestrutura de serviços da BrasilDataHub

Configuração **versionada** dos serviços de dados da organização
[BrasilDataHub](https://github.com/BrasilDataHub). As imagens são genéricas
por desenho: qualquer projeto da org (baseempresarial, baseescolar,
basehospitalar) consome as mesmas imagens; o que é específico de cada
projeto (envs, volumes, limites) vive no deploy.

## Serviços

| Serviço | Imagem | Documentação |
|---|---|---|
| PostgreSQL | `ghcr.io/brasildatahub/postgres:17` — imagem única, tuning por envs `PG_*`, perfis **dedicados** de 8 a 128 GB, todos com NVMe local ([perfis](postgres/docs/perfis.md), [deploy](postgres/docs/deploy.md), [troubleshooting](postgres/docs/troubleshooting.md), [preparação do host](postgres/docs/host.md)) | [`postgres/`](postgres/) |
| Redis | `ghcr.io/brasildatahub/redis:7` — volatile-lru, AOF, perfis `cache-256mb`–`cache-2gb` | [`redis/`](redis/) |
| Meilisearch | `ghcr.io/brasildatahub/meilisearch:1.34` — wrapper pinado, perfis `busca-512mb`–`busca-16gb` | [`meilisearch/`](meilisearch/) |

Cada pasta tem seu README com as variáveis de configuração, os perfis por
máquina e o passo a passo de implantação.

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

[`infra-setup.sh`](infra-setup.sh) provisiona uma máquina nova do zero: sistema,
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

```bash
# interativo (pergunta serviços, perfil, modo de volume, rede)
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/infra/main/infra-setup.sh -o infra-setup.sh
sudo bash infra-setup.sh

# não supervisionado: tudo, com senhas geradas e perfil detectado pela RAM
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/infra/main/infra-setup.sh | sudo bash -s -- --auto

# só Postgres e Redis, com acesso restrito à rede privada da aplicação
... | sudo bash -s -- --auto --services postgres,redis --allow-from 10.0.0.0/8

# dados fora do disco do Docker (NVMe montado em outro ponto)
... | sudo bash -s -- --auto --volumes bind --data-dir /mnt/nvme

sudo bash infra-setup.sh --help      # todas as opções
```

Baixar e revisar antes de executar é a forma recomendada: o script roda como
root e altera o sistema.

Os valores de cada perfil ficam **só** nos arquivos `.env` versionados
(`postgres/profiles/`, `redis/profiles/`, `meilisearch/profiles/`): o script os
baixa em vez de embutir cópias, então doc, script e deploy manual usam
exatamente os mesmos números. `--pg-profile`, `--redis-profile` e
`--meili-profile` escolhem qual; `--profiles-dir` lê de um clone local.

### O que fica onde

```
/opt/brasildatahub/                        (--workdir)
├── services/
│   ├── postgres/
│   │   ├── docker-compose.yml             baixado deste repositório
│   │   ├── docker-compose.override.yml    só no modo --volumes bind
│   │   └── .env                           gerado, chmod 600
│   ├── redis/
│   └── meilisearch/
├── secrets/credentials.env                todas as credenciais, chmod 600
├── setup.log
└── .setup-state                           ref, perfil, modo de volume, data
/etc/brasildatahub/setup.conf              aponta para a raiz acima
/usr/local/bin/bdh                          comandos de operação
/etc/update-motd.d/99-brasildatahub         mensagem de login
```

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

`sudo bash infra-setup.sh --force` refaz `.env` e composes e recria os
containers. **Nunca remove volumes**: os dados permanecem. Trocar o modo de
volume (`named` ↔ `bind`) numa instalação existente é recusado, porque a troca
não move dados — copie-os antes:

```bash
docker run --rm -v bdh_pg_data:/from -v /mnt/nvme/postgres:/to alpine cp -a /from/. /to/
```

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

## Publicação

As imagens são **públicas** no GHCR (pull sem autenticação); este
repositório permanece privado. A CI
(`.github/workflows/build-publish.yml`) builda e publica a cada push na
`main` que toque a pasta do serviço.

```bash
docker pull ghcr.io/brasildatahub/postgres:17
docker pull ghcr.io/brasildatahub/redis:7
docker pull ghcr.io/brasildatahub/meilisearch:1.34
```
