# PgBouncer

## Papel

Pool de conexões entre a aplicação e o Postgres em **transaction pooling**: até 400 clientes sobre 20 conexões reais (`default_pool_size`).

Roda no **host da aplicação**, não no host do banco — a perna de rede reusada é a do lado do cliente. Com mais de um host de aplicação, um pooler no host do banco passa a valer (um pool só; custo: ponto único de falha e RTT na abertura).

## Componentes / imagem

- Compose: [`docker-compose.yml`](docker-compose.yml)
- Overlay de rede externa: [`docker-compose.rede-externa.yml`](docker-compose.rede-externa.yml)
- Deploy único para painel: [`docker-compose.dokploy.yml`](docker-compose.dokploy.yml)
- Porta default: `6432` (dentro e no host)
- Teste: `bash pgbouncer/test/pgbouncer.test.sh`

## Perfis e configuração

Sem arquivos de perfil `.env` versionados por orçamento. Dimensionamento:

```
default_pool_size × work_mem  ≤  memória disponível para sorts
        20        ×   96 MB   =  1,9 GB   (perfil Postgres compartilhada-14gb)
```

`max_client_conn` (400) são conexões do lado cliente (~2 KB cada no PgBouncer).

Configuração crítica embutida:

```ini
server_reset_query = DISCARD ALL
server_reset_query_always = 1
ignore_startup_parameters = extra_float_digits,options,search_path
```

`max_prepared_statements` default **200** (PgBouncer 1.21+). Com `0`, PDO nativo falha com `prepared statement does not exist`.

Ordem de implantação (indivisível):

1. Subir o PgBouncer e apontar a aplicação para a porta **6432**.
2. Confirmar `SHOW POOLS` com tráfego real.
3. Só então aplicar `max_connections=60` + `work_mem=96MB` no Postgres (`compartilhada-14gb`) — exige restart do banco.

## Deploy / operação

```bash
cd pgbouncer
cat > .env <<'EOF'
PGB_DB_HOST=<ip-do-bdh-data>
PGB_DB_NAME=dados_cnpj
PGB_USER=postgres
PGB_PASSWORD=...
EOF
docker compose up -d
docker compose exec pgbouncer psql -h 127.0.0.1 -p 6432 -U "$PGB_USER" -d pgbouncer -c 'SHOW POOLS'
```

Rede da aplicação:

| Como a aplicação é implantada | O que fazer |
|---|---|
| Mesmo `docker compose`, ou rede criada por este compose | nada: `APP_NETWORK` + alias `pgbouncer` |
| Painel com rede própria (Dokploy, Coolify, Swarm) | `APP_NETWORK=<rede>` **e** overlay [`docker-compose.rede-externa.yml`](docker-compose.rede-externa.yml) |
| Deploy pelo painel | [`docker-compose.dokploy.yml`](docker-compose.dokploy.yml) |

Em host do `setup.sh`:

```bash
cp docker-compose.rede-externa.yml \
   /opt/brasildatahub/services/pgbouncer/docker-compose.override.yml
echo 'APP_NETWORK=dokploy-network' >> /opt/brasildatahub/services/pgbouncer/.env
bdh up pgbouncer
```

Conferir alias:

```bash
docker inspect pgbouncer-pgbouncer-1 \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.Aliases}}{{println}}{{end}}'
```

Diagnóstico:

```bash
psql -h 127.0.0.1 -p 6432 -U <PGB_USER> -d pgbouncer
SHOW POOLS;    # cl_waiting > 0 sustentado = pool pequeno
SHOW STATS;
SHOW LISTS;    # healthcheck
```

Sintomas comuns:

| Sintoma | Causa |
|---|---|
| App não resolve o host do banco | `DB_HOST` com nome do serviço no painel em vez do alias `pgbouncer` |
| Conexões falham em metade das vezes | Dois containers com o mesmo alias na rede |
| Container Up, pooler recusando | `healthcheck` removido |

Não enviar pelo pooler: exportações, sitemaps, varreduras longas — usar conexão direta ao Postgres.

Chain `DOCKER-USER` do `setup.sh` conhece 5432, 9100 e 9187 — **não** a 6432. Se o pooler for para o host do banco, liberar a porta no firewall.

## Variáveis e segredos

### Conexão ao Postgres (obrigatórias)

| Variável | Default | Descrição |
|---|---|---|
| `PGB_DB_HOST` | — | host do Postgres |
| `PGB_DB_NAME` | — | database |
| `PGB_USER` | — | usuário (`admin_users`/`stats_users`) |
| `PGB_PASSWORD` | — | senha em texto |
| `PGB_DB_PORT` | `5432` | porta do Postgres |
| `PGB_PASSWORD_SCRAM` | — | verificador SCRAM (`SCRAM-SHA-256$...`); preferível à senha em texto |

### Bancos/usuários extras

| Variável | Default | Descrição |
|---|---|---|
| `PGB_EXTRA_DATABASES` | — | separados por `;`; `nome` ou `nome=host` |
| `PGB_EXTRA_USERS` | — | `usuario=senha`, separados por `;` |

Cada par (database, usuário) tem pool próprio de `default_pool_size`. Senha com `;` ou `=` não passa por `PGB_EXTRA_USERS`.

### Dimensionamento

| Variável | Default | Descrição |
|---|---|---|
| `PGB_POOL_MODE` | `transaction` | |
| `PGB_DEFAULT_POOL_SIZE` | `20` | conexões reais por (database, usuário) |
| `PGB_MAX_CLIENT_CONN` | `400` | lado cliente |
| `PGB_MIN_POOL_SIZE` | `5` | |
| `PGB_RESERVE_POOL_SIZE` | `5` | |
| `PGB_RESERVE_POOL_TIMEOUT` | `3` | segundos |

### Tempos e ciclo de vida

| Variável | Default | Descrição |
|---|---|---|
| `PGB_MAX_PREPARED_STATEMENTS` | `200` | `0` quebra PDO nativo |
| `PGB_SERVER_IDLE_TIMEOUT` | `600` | |
| `PGB_SERVER_LIFETIME` | `3600` | |
| `PGB_QUERY_WAIT_TIMEOUT` | `30` | |
| `PGB_SERVER_RESET_ALWAYS` | `1` | guarda contra vazamento de `SET` entre clientes |

### Container

| Variável | Default | Descrição |
|---|---|---|
| `PGBOUNCER_PORT` | `6432` | porta no host |
| `PGBOUNCER_BIND_IP` | `127.0.0.1` | |
| `PGBOUNCER_MEMORY_LIMIT` | `128M` | |
| `PGBOUNCER_CPU_LIMIT` | `1` | |
| `PGB_LISTEN_PORT` | `6432` | porta dentro do container |
| `PGB_LOG_CONNECTIONS` / `PGB_LOG_DISCONNECTIONS` | `0` | |
| `APP_NETWORK` | `baseempresarial` | rede da aplicação |
| `LOG_MAX_SIZE` / `LOG_MAX_FILE` | `50m` / `3` | |

## Restrições

- Transaction pooling: `SET` de sessão vaza entre clientes sem `DISCARD ALL` + `server_reset_query_always = 1`. Preferir `SET LOCAL` na aplicação.
- Sem `ignore_startup_parameters`, handshake falha com `unsupported startup parameter`.
- `search_path` na lista de ignore faz o ciclo blue/green funcionar via `ALTER DATABASE`; com `server_lifetime = 3600`, publicação alcança todas as conexões em no máximo 1 h.
- Mudar `PG_WORK_MEM` no Postgres sem refazer a conta `pool_size × work_mem` arrisca OOM sob pico.
- `127.0.0.1:6432` dentro do container da app é o loopback dela — não alcança o pooler.

## Links

- [Ciclo blue/green (cnpj-pipeline)](https://github.com/BrasilDataHub/baseempresarial-services/blob/main/services/cnpj-pipeline/docs/ciclo-blue-green.md)
- [`../postgres/README.md`](../postgres/README.md)
