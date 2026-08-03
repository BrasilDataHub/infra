# redis

## Papel

Redis padrão dos projetos BrasilDataHub: cache de aplicação Laravel e fila do Horizon. Imagem única `ghcr.io/brasildatahub/redis` (base `redis:7.4-alpine`); conf base embutida, dimensionamento por envs no start — trocar perfil não exige rebuild.

Para cache e fila/sessões em instâncias separadas, ver [`README-par.md`](README-par.md).

## Componentes / imagem

- Imagem: `ghcr.io/brasildatahub/redis`
- Conf: `redis.conf` embutida
- Compose: [`docker-compose.yml`](docker-compose.yml)
- Overlay métricas: [`docker-compose.metrics.yml`](docker-compose.metrics.yml)
- Volume: `bdh_redis_data` → `/data` (uid 999; entrypoint corrige dono)
- Porta default: `0.0.0.0:6379`

## Perfis e configuração

| Perfil | maxmemory | Limite de container | Quando usar |
|---|---|---|---|
| `cache-256mb` | 256mb | **512M** | cache + fila leve |
| `cache-512mb` | 512mb | **1G** | default; cache + Horizon |
| `cache-1gb` | 1gb | **2G** | cache pesado ou várias apps |
| `cache-2gb` | 2gb | **3G** | cache + fila, host 8 GiB |
| `cache-4gb` | 4gb | **5G** | instância **só cache** (`allkeys-lru`, sem AOF), host ≥ 8 GiB |

| Perfil | Arquivo |
|---|---|
| `cache-256mb` | [`profiles/cache-256mb.env`](profiles/cache-256mb.env) |
| `cache-512mb` | [`profiles/cache-512mb.env`](profiles/cache-512mb.env) |
| `cache-1gb` | [`profiles/cache-1gb.env`](profiles/cache-1gb.env) |
| `cache-2gb` | [`profiles/cache-2gb.env`](profiles/cache-2gb.env) |
| `cache-4gb` | [`profiles/cache-4gb.env`](profiles/cache-4gb.env) |

Um perfil por deploy. Até `cache-2gb`: `volatile-lru` + AOF (cache e fila juntos). `cache-4gb`: `allkeys-lru`, AOF desligado.

Limite de container ≈ 2× `maxmemory` (headroom para COW no rewrite do AOF). Em coexistência com Postgres, entra o **limite de container** na [fórmula](../postgres/docs/perfis.md#fórmula-de-reserva).

Políticas:

- `volatile-lru` — despeja só chaves com TTL; jobs Horizon (sem TTL) seguros. Sessões **têm** TTL e são despejáveis sob pressão.
- Instância só cache: `allkeys-lru` via `REDIS_MAXMEMORY_POLICY` (já no `cache-4gb`).
- `appendonly yes` (fsync a cada segundo) por default; só cache: `REDIS_APPENDONLY=no`.

Migrar de perfil quando `evicted_keys` crescer ou `used_memory` estacionar no `maxmemory`. Backlog de fila (chaves sem TTL) → investigar Horizon antes de subir memória.

Kernel (aplicado pelo `setup.sh` quando Redis está nos serviços):

| Parâmetro | Valor |
|---|---|
| `vm.overcommit_memory` | `1` |
| Transparent Huge Pages | `never` |
| `net.core.somaxconn` | `≥ 511` (Debian 12 default 4096) |

Manual:

```bash
printf 'vm.overcommit_memory = 1\n' > /etc/sysctl.d/60-redis.conf
sysctl -p /etc/sysctl.d/60-redis.conf

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

```bash
cat /proc/sys/vm/overcommit_memory              # 1
cat /sys/kernel/mm/transparent_hugepage/enabled # always madvise [never]
```

## Deploy / operação

```bash
BASE=https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/redis
curl -fsSL "$BASE/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$BASE/profiles/cache-512mb.env" -o .env

cat >> .env <<'EOF'
REDIS_PASSWORD=a-mesma-senha-que-a-aplicacao-e-o-horizon-usam
# opcionais: BIND_IP, REDIS_PORT, REDIS_VOLUME
EOF
chmod 600 .env

docker compose up -d

docker inspect <container> --format 'Memory={{.HostConfig.Memory}}'   # ≠ 0
redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory
redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory-policy # volatile-lru
redis-cli -a $REDIS_PASSWORD CONFIG GET appendonly       # yes
```

Painel: Compose stack com o mesmo YAML. `docker compose down -v` apaga o volume.

Métricas (não recria o container Redis):

```bash
docker compose -f docker-compose.yml -f docker-compose.metrics.yml up -d
```

Exporter lê `REDIS_PASSWORD`; alcançado na rede `bdh_metrics`. Profundidade de filas Horizon (opt-in, O(1)):

```bash
REDIS_METRICS_KEYS=0=queues:default,0=queues:default:reserved
```

Não usar `--check-keys` / `--count-keys` (SCAN a cada scrape).

```bash
docker build -t brasildatahub-redis:7 .
docker run -d --name redis-test -e REDIS_MAXMEMORY=256mb \
    -e REDIS_PASSWORD=test brasildatahub-redis:7
docker exec redis-test redis-cli -a test CONFIG GET maxmemory  # 268435456
```

## Variáveis e segredos

| Env | Default | O que controla |
|---|---|---|
| `REDIS_MAXMEMORY` | `512mb` | teto de memória de dados |
| `REDIS_MAXMEMORY_POLICY` | `volatile-lru` | política de despejo |
| `REDIS_PASSWORD` | — | anexa `--requirepass` |
| `REDIS_APPENDONLY` | (conf: yes) | `no` em instância só cache |
| `REDIS_METRICS_KEYS` | — | chaves para `LLEN` no exporter |
| `BIND_IP`, `REDIS_PORT`, `REDIS_VOLUME` | — | publicação e volume |

Sem TLS: fora de rede confiável a senha trafega em claro. Exporter usa a mesma senha (`requirepass`, sem ACL dedicada).

## Restrições

- Limite de container = `maxmemory` arrisca OOM-kill no rewrite do AOF.
- `volatile-lru` sob pressão desloga usuários (sessão tem TTL) — ver [`README-par.md`](README-par.md).
- Acima de `cache-4gb`, separar instâncias por projeto.

## Links

- [`README-par.md`](README-par.md) — par cache + fila
- [Fórmula de coexistência](../postgres/docs/perfis.md#fórmula-de-reserva)
- [Layout de volumes](../postgres/docs/host.md#volumes-nomeados)
- [Rede](../postgres/docs/host.md#rede)
- [`../monitoring/README.md`](../monitoring/README.md)
- [`../README.md`](../README.md) — `setup.sh`
