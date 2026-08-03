# O par de instâncias de Redis

## Papel

Complementa o [`README.md`](README.md) (instância única). Duas instâncias Redis no mesmo host: uma para **cache** e outra para **fila e sessões**, porque `maxmemory` e `maxmemory-policy` são por instância, não por database.

Com cache e fila juntos, nenhuma política serve aos dois: `allkeys-lru` pode descartar job; `noeviction` derruba writes de cache; `volatile-lru` despeja sessões (TTL).

## Componentes / imagem

- Compose: [`docker-compose.par.yml`](docker-compose.par.yml)
- Perfis: [`profiles/cache-768mb.env`](profiles/cache-768mb.env), [`profiles/fila-256mb.env`](profiles/fila-256mb.env)
- Mesma imagem `ghcr.io/brasildatahub/redis` do módulo

| | cache | fila e sessões |
|---|---|---|
| perfil | `cache-768mb` | `fila-256mb` |
| `maxmemory-policy` | `allkeys-lru` | `noeviction` |
| persistência | **não** | AOF `everysec` |
| limite de container | 1G | 512M |
| porta default | 6379 | 6380 |
| perder dado é | comportamento esperado | incidente |

## Perfis e configuração

Os dois arquivos `.env.cache` e `.env.fila` são `required: true` no compose — sem eles o deploy sobe com defaults de instância única (`volatile-lru` / `512mb`).

## Deploy / operação

```bash
cd /opt/brasildatahub/services/redis

curl -fsSL .../redis/profiles/cache-768mb.env -o .env.cache
curl -fsSL .../redis/profiles/fila-256mb.env  -o .env.fila
echo "REDIS_PASSWORD=$(openssl rand -base64 36 | tr -d '\n/+=' | cut -c1-32)" >> .env

docker compose -f docker-compose.par.yml up -d
```

Aplicação:

```env
# fila e sessões
REDIS_HOST=<host>
REDIS_PORT=6380

# cache
REDIS_CACHE_HOST=<host>
REDIS_CACHE_PORT=6379
```

Validação:

```bash
redis-cli -p 6379 -a "$REDIS_PASSWORD" CONFIG GET maxmemory-policy   # allkeys-lru
redis-cli -p 6380 -a "$REDIS_PASSWORD" CONFIG GET maxmemory-policy   # noeviction
redis-cli -p 6380 -a "$REDIS_PASSWORD" CONFIG GET appendonly         # yes
```

Alerta `RedisDespejandoChaves`: na de cache, despejo constante importa; na de fila, **qualquer** despejo é falha (`noeviction`).

## Variáveis e segredos

| Variável | Onde | Descrição |
|---|---|---|
| `REDIS_PASSWORD` | `.env` compartilhado | mesma senha nas duas instâncias |
| envs do perfil | `.env.cache` / `.env.fila` | maxmemory, policy, limites |

## Restrições

- Apontar cache e fila para a mesma porta mistura as políticas sem sintoma óbvio.
- Kernel (`overcommit`, THP): mesmas exigências do [`README.md`](README.md).

## Links

- [`README.md`](README.md)
- [`docker-compose.par.yml`](docker-compose.par.yml)
