# redis

Imagem `ghcr.io/brasildatahub/redis` (base `redis:7.4-alpine`) — o Redis
padrão dos projetos BrasilDataHub. Papel: cache de aplicação Laravel e fila
do Horizon.

É uma **imagem única**: a conf base (`redis.conf`) é embutida e o
dimensionamento vem de envs no start — trocar de perfil é trocar envs no
deploy, nenhum rebuild:

| Env | Default | O que controla |
|---|---|---|
| `REDIS_MAXMEMORY` | `512mb` | teto de memória de dados |
| `REDIS_MAXMEMORY_POLICY` | `volatile-lru` | política de despejo |
| `REDIS_PASSWORD` | — | anexa `--requirepass` (a conf não lê env) |

## Perfis por orçamento de memória

Os perfis são definidos pelo orçamento de memória do serviço, independentes
de projeto e de fornecedor:

| Perfil | maxmemory | Limite de container | Quando usar |
|---|---|---|---|
| `cache-256mb` | 256mb | **512M** | projetos pequenos (ex.: Base Escolar): cache + fila leve |
| `cache-512mb` | 512mb | **1G** | default da imagem; aplicação de produção com cache + Horizon (Base Empresarial) |
| `cache-1gb` | 1gb | **2G** | cache pesado ou várias aplicações (um database lógico por app) |
| `cache-2gb` | 2gb | **3G** | cache + fila numa instância só, em host de 8 GiB |
| `cache-4gb` | 4gb | **5G** | instância **dedicada a cache** (`allkeys-lru`, sem AOF), host de 8 GiB ou mais — Base Empresarial |

Acima de `cache-4gb`, separe instâncias por projeto em vez de crescer uma só.

Cada perfil é um arquivo `.env` versionado em [`profiles/`](profiles/) —
`maxmemory`, política de despejo e limite de container juntos. É o mesmo arquivo
que o [`setup.sh`](../README.md#setup-automatizado-de-vps) baixa:

```bash
curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/redis/profiles/cache-512mb.env -o .env
# depois acrescente: REDIS_PASSWORD=...
```

| Perfil | Arquivo |
|---|---|
| `cache-256mb` | [`profiles/cache-256mb.env`](profiles/cache-256mb.env) |
| `cache-512mb` | [`profiles/cache-512mb.env`](profiles/cache-512mb.env) |
| `cache-1gb` | [`profiles/cache-1gb.env`](profiles/cache-1gb.env) |
| `cache-2gb` | [`profiles/cache-2gb.env`](profiles/cache-2gb.env) |
| `cache-4gb` | [`profiles/cache-4gb.env`](profiles/cache-4gb.env) |

Use apenas UM perfil por deploy. Os perfis até `cache-2gb` ficam em
`volatile-lru` porque assumem cache **e** fila na mesma instância (ver decisões
abaixo). O `cache-4gb` é o único que assume instância dedicada a cache, e por
isso usa `allkeys-lru` e dispensa o AOF.

Se o Redis dividir o host com o Postgres, é o **limite de container** da tabela
acima (não o `maxmemory`) que entra na
[fórmula de coexistência](../postgres/docs/perfis.md#fórmula-de-reserva).

**Por que o limite de container é ~2× o maxmemory:** com AOF ligado, o
rewrite periódico faz `fork()` e as páginas copy-on-write podem
temporariamente dobrar a memória do processo. Limite de container igual ao
`maxmemory` (como já rodou em produção) arrisca OOM-kill exatamente durante
o rewrite. O headroom encolhe proporcionalmente nos perfis maiores porque o
pico de COW depende da taxa de escrita, não do tamanho total.

**Quando migrar de perfil:** `evicted_keys` crescendo em `INFO stats`
(cache sendo despejado cedo demais) ou `used_memory` estacionado no
`maxmemory`. Se a fila (chaves sem TTL) dominar o uso, o problema não é
perfil de cache — é backlog de jobs; investigue o Horizon antes de subir
memória.

## Decisões de configuração (base fixa da imagem)

- **`volatile-lru`** — despeja só chaves **com TTL** (cache). As chaves de
  fila/Horizon não têm TTL e nunca são despejadas; por isso a política é
  segura **para os jobs** com cache+fila na mesma instância. `allkeys-lru`
  poderia descartar jobs pendentes; `noeviction` faria writes de cache falharem
  no limite. Instâncias **só de cache** (sem fila) devem usar `allkeys-lru` via
  `REDIS_MAXMEMORY_POLICY` — é o que o perfil `cache-4gb` já traz.
  **Atenção ao que ela NÃO protege:** sessão tem TTL, então é despejável. Numa
  instância compartilhada sob pressão, `volatile-lru` desloga usuário — foi o
  que aconteceu em 28/07/2026 e é o motivo do [par de
  instâncias](README-par.md). Com login desligado o efeito é inofensivo; ao
  ligar login, a sessão precisa sair da instância de cache.
- **`appendonly yes` (AOF, fsync a cada segundo)** — jobs enfileirados
  sobrevivem a restart. Numa instância **só de cache** é custo sem retorno:
  desligue com `REDIS_APPENDONLY=no` e deixe só o RDB, que serve para o cache
  voltar quente depois de um restart, não para durabilidade.

## Parâmetros de kernel do host

Valem para **qualquer** instância, e o Redis reclama de um deles no boot:

```
WARNING Memory overcommit must be enabled! Without it, a background save or
replication may fail under low memory condition.
```

| Parâmetro | Valor | Por quê |
|---|---|---|
| `vm.overcommit_memory` | `1` | BGSAVE e rewrite do AOF fazem `fork()`. Com overcommit heurístico (`0`) o kernel avalia o tamanho **virtual** do pai e pode recusar o fork de um processo de vários GB mesmo com memória sobrando — o COW real medido foi de 4,7 MB |
| Transparent Huge Pages | `never` | Com THP em `always` o kernel entrega páginas de 2 MB: no fork, tocar 1 byte copia 2 MB em vez de 4 KB. Vira latência em pico e memória muito acima do dataset |
| `net.core.somaxconn` | `≥ 511` | Backlog de accept; o default do Debian 12 (4096) já atende |

**O [`setup.sh`](../setup.sh) já aplica os dois** sempre que o Redis está entre
os serviços selecionados (`configure_overcommit` e `configure_thp`), de forma
idempotente e persistente. O que segue é o equivalente manual, para host que
não passou pelo setup — o `sysctl.d` sozinho não cobre THP, que não é sysctl:

```bash
# 1) overcommit
printf 'vm.overcommit_memory = 1\n' > /etc/sysctl.d/60-redis.conf
sysctl -p /etc/sysctl.d/60-redis.conf

# 2) THP: unit oneshot, porque /sys não é persistido por sysctl.d.
#    Before=docker.service garante que vale antes de o Redis subir.
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Desabilita Transparent Huge Pages (exigido pelo Redis)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload && systemctl enable --now disable-thp.service
```

Conferir:

```bash
cat /proc/sys/vm/overcommit_memory              # 1
cat /sys/kernel/mm/transparent_hugepage/enabled # always madvise [never]
```

## Implantação

Use o [`docker-compose.yml`](docker-compose.yml) desta pasta com um `.env` ao
lado — é a forma recomendada, pelos mesmos motivos do Postgres
([por quê](../postgres/docs/estrategia-deploy.md)). Num painel (Dokploy,
Coolify), crie o serviço como **Compose stack** e cole o mesmo YAML; o Redis
não usa `/dev/shm`, então não há a armadilha do Postgres — mas o **limite de
memória continua sendo recurso do serviço**, e é ele que dá o headroom do AOF.

```bash
BASE=https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/redis
curl -fsSL "$BASE/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$BASE/profiles/cache-512mb.env" -o .env    # <- perfil escolhido

cat >> .env <<'EOF'
REDIS_PASSWORD=a-mesma-senha-que-a-aplicacao-e-o-horizon-usam
# opcionais: BIND_IP, REDIS_PORT, REDIS_VOLUME
EOF
chmod 600 .env

docker compose up -d

# validação (limite aplicado + conf efetiva)
docker inspect <container> --format 'Memory={{.HostConfig.Memory}}'   # ≠ 0
redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory        # bytes do perfil
redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory-policy # volatile-lru
redis-cli -a $REDIS_PASSWORD CONFIG GET appendonly       # yes
```

**Volume.** O AOF fica no volume nomeado `bdh_redis_data`, montado em `/data` —
mesmo padrão dos três serviços da org
([layout](../postgres/docs/host.md#volumes-nomeados)). Nada a criar ou ajustar de
permissão: o entrypoint corrige o dono no start e o Redis roda como uid 999, não
como root. `docker compose down -v` **apaga** o volume; use `down` sem `-v`.

**Porta.** Publicada em `0.0.0.0:6379` por default — o Redis não faz TLS, então
fora de rede confiável a senha trafega em claro. Use uma senha longa e, se quiser
restringir, `BIND_IP` numa interface privada ou firewall por origem
([Rede](../postgres/docs/host.md#rede)).

## Métricas

[`docker-compose.metrics.yml`](docker-compose.metrics.yml) é um overlay
**opcional** que acrescenta o `redis_exporter` ao mesmo projeto Compose, sem
tocar no serviço `redis`:

```bash
docker compose -f docker-compose.yml -f docker-compose.metrics.yml up -d
```

Nenhuma credencial nova: o exporter lê `REDIS_PASSWORD`, que já está no `.env`.
Como nada é acrescentado ao `.env`, o container do Redis **não é recriado** ao
ligar métricas.

O exporter não publica porta — é alcançado pelo Prometheus na rede
`bdh_metrics` ([como isso funciona](../monitoring/README.md#como-os-pedaços-se-enxergam)).

**Profundidade das filas do Horizon** é a métrica mais útil daqui, e é opt-in.
Defina no `.env` as chaves exatas a medir:

```bash
REDIS_METRICS_KEYS=0=queues:default,0=queues:default:reserved
```

Isso usa `-check-single-keys`, que faz `LLEN` — O(1), seguro em produção. **Nunca
use** `--check-keys` nem `--count-keys`: elas fazem `SCAN` do keyspace a cada
scrape e param um Redis single-thread com fila.

Endurecimento em aberto: o `redis.conf` usa `requirepass`, não ACL, então o
exporter conecta com a mesma senha de todo mundo. Um usuário ACL dedicado
(`+info +config|get +client|info +slowlog +latency -@all`) exigiria mexer no
`redis.conf` embutido e rebuildar a imagem.

## Validação local

```bash
docker build -t brasildatahub-redis:7 .
docker run -d --name redis-test -e REDIS_MAXMEMORY=256mb \
    -e REDIS_PASSWORD=test brasildatahub-redis:7
docker exec redis-test redis-cli -a test CONFIG GET maxmemory  # 268435456
```
