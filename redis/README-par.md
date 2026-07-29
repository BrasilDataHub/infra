# O par de instâncias de Redis

> Complementa o [`README.md`](README.md), que descreve a instância única.

## O defeito que ele corrige

Medido em 28/07/2026, numa única instância de 512 MB servindo cache **e**
fila/sessões:

| | |
|---|---|
| evicções | **34.007** |
| hit rate | **59,7%** |
| política | `volatile-lru` |

`volatile-lru` despeja **somente chaves com TTL**. As chaves de fila do Horizon
não têm TTL — mas **as de sessão têm**. Então, quando o cache encheu, o Redis
descartou sessões: parte daqueles 34 mil despejos eram **usuários sendo
deslogados**, e ninguém tinha ligado o "logout aleatório" ao hit rate.

## Por que duas instâncias, e não dois databases

Porque `maxmemory` e `maxmemory-policy` são da **instância**, não do database.
Com cache e fila juntos, a política tem de servir aos dois — e nenhuma serve:

| Política | Com cache + fila juntos |
|---|---|
| `allkeys-lru` | pode descartar **job pendente** |
| `noeviction` | um `SET` de cache no limite **derruba a escrita** |
| `volatile-lru` | descarta **sessão**, que é o que aconteceu |

Separadas, cada lado ganha a política que faz sentido:

| | cache | fila e sessões |
|---|---|---|
| perfil | `cache-768mb` | `fila-256mb` |
| `maxmemory-policy` | `allkeys-lru` | `noeviction` |
| persistência | **não** | AOF `everysec` |
| limite de container | 1G | 512M |
| porta default | 6379 | 6380 |
| perder dado é | o comportamento correto | **um incidente** |

## Deploy

```bash
cd /opt/brasildatahub/services/redis

curl -fsSL .../redis/profiles/cache-768mb.env -o .env.cache
curl -fsSL .../redis/profiles/fila-256mb.env  -o .env.fila
echo "REDIS_PASSWORD=$(openssl rand -base64 36 | tr -d '\n/+=' | cut -c1-32)" >> .env

docker compose -f docker-compose.par.yml up -d
```

Os dois arquivos são `required: true` no compose de propósito: sem eles, o
deploy subiria com os defaults de instância única — `volatile-lru` e `512mb` —,
que é exatamente o estado que este par corrige, e sem nenhum sintoma novo.

## Do lado da aplicação

```env
# fila e sessões
REDIS_HOST=<host>
REDIS_PORT=6380

# cache
REDIS_CACHE_HOST=<host>
REDIS_CACHE_PORT=6379
```

**Apontar as duas para a mesma porta recria o defeito** sem nenhum sinal: o site
continua funcionando, e os despejos voltam. Confira depois de subir:

```bash
redis-cli -p 6379 -a "$REDIS_PASSWORD" CONFIG GET maxmemory-policy   # allkeys-lru
redis-cli -p 6380 -a "$REDIS_PASSWORD" CONFIG GET maxmemory-policy   # noeviction
redis-cli -p 6380 -a "$REDIS_PASSWORD" CONFIG GET appendonly         # yes
```

O alerta `RedisDespejandoChaves` continua valendo para as duas — mas com
significados opostos. Na de cache, despejo é operação normal e o alerta só
importa se for constante; na de fila, **qualquer** despejo é um defeito, porque
com `noeviction` ele nem deveria acontecer.
