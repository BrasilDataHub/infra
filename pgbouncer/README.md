# PgBouncer

> Item 18 do roadmap 20 (arquitetura de busca).

Pool de conexões entre a aplicação e o Postgres, em **transaction pooling**.
400 clientes sobre 20 conexões reais.

## Onde ele roda

**No host da aplicação (`bdh-apps`), não no host do banco.** Isso não é
detalhe: o ganho do pooler é encurtar o caminho de abertura de conexão que o
*cliente* percorre. Com ele do lado do banco, cada nova conexão do Octane ainda
pagaria o RTT de rede antes de encontrar o pool.

## Subir

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

Depois, aponte a aplicação para a porta **6432** em vez da 5432.

## A ordem de implantação, que é indivisível

O item 18 é um par. Invertê-lo **derruba a aplicação**:

1. subir o PgBouncer e apontar a aplicação para ele (porta 6432);
2. confirmar `SHOW POOLS` com **tráfego real** passando;
3. **só então** aplicar `max_connections=60` + `work_mem=96MB` no Postgres
   (perfil `compartilhada-14gb`) — o que exige restart do banco.

Fazer o passo 3 antes do 1 significa 60 conexões diretas atendendo o que hoje
abre até 100.

## A conta que dimensiona o serviço

`default_pool_size` é o número de conexões **reais** ao Postgres por par
(database, usuário). Ele é o multiplicador de `work_mem` no pior caso, e por
isso não pode ser escolhido por conforto:

```
default_pool_size × work_mem  ≤  memória disponível para sorts
        20        ×   96 MB   =  1,9 GB   ✔ dentro dos 14 GiB do perfil
```

`max_client_conn` é outra coisa inteiramente: são conexões do **lado cliente**,
que custam ~2 KB cada no PgBouncer e nada no Postgres. 400 clientes sobre 20
conexões reais é exatamente o ponto do pooler.

Mudar `PG_WORK_MEM` no perfil do Postgres sem refazer esta conta é o caminho
para um OOM sob pico.

## O que transaction pooling quebra

A conexão real volta ao pool a **cada COMMIT**. É o que permite os 400 sobre 20,
e é também o que quebra duas coisas:

### 1. `SET` de sessão

Um `SET work_mem` fora de transação vale para a **próxima conexão que pegar
aquele slot** — que é de outro cliente. Isso foi reproduzido no teste de
integração: sem as guardas abaixo, um `SET statement_timeout = 9999` feito por
um cliente aparece no `current_setting` de outro.

As duas linhas que fecham isso:

```ini
server_reset_query = DISCARD ALL
server_reset_query_always = 1
```

`server_reset_query_always = 1` é o que faz o `DISCARD ALL` rodar **também em
transaction mode** — por default ele só roda em session mode. Custa um
round-trip por transação e nenhuma IO.

A aplicação usa `SET LOCAL` dentro de transação (`App\Support\StatementTimeout`),
que é seguro por si. As linhas acima são a rede de segurança para quando alguém
não seguir a regra.

### 2. Prepared statements no protocolo estendido

O PgBouncer 1.21+ os suporta com `max_prepared_statements > 0`. Com `0`, o PDO
do PHP em modo nativo falha com `prepared statement does not exist`. O default
aqui é **200**, folgado para o conjunto de consultas desta aplicação, e custa
memória no PgBouncer, não no banco.

### `ignore_startup_parameters`

```ini
ignore_startup_parameters = extra_float_digits,options,search_path
```

Sem esta linha, a conexão é **recusada no handshake** com
`unsupported startup parameter` — e o erro não menciona o PgBouncer, o que
torna o diagnóstico caro.

> `search_path` estar nesta lista é o que faz o [ciclo blue/green](https://github.com/BrasilDataHub/baseempresarial-services/blob/main/services/cnpj-pipeline/docs/ciclo-blue-green.md)
> funcionar através do pooler: o `search_path` que vale é o do
> `ALTER DATABASE`, e não o que a aplicação pede no handshake. Com
> `server_lifetime = 3600`, uma publicação alcança todas as conexões em no
> máximo uma hora.

## Variáveis de ambiente

### Conexão ao Postgres (obrigatórias)

| Variável | Default | Descrição |
|---|---|---|
| `PGB_DB_HOST` | — | host do Postgres. **Obrigatória** |
| `PGB_DB_NAME` | — | database. **Obrigatória** |
| `PGB_USER` | — | usuário. **Obrigatória**. É também o `admin_users`/`stats_users` |
| `PGB_PASSWORD` | — | senha em texto. **Obrigatória** |
| `PGB_DB_PORT` | `5432` | porta do Postgres |
| `PGB_PASSWORD_SCRAM` | — | verificador SCRAM pronto (`SCRAM-SHA-256$...`). **Preferível** à senha em texto; gerar exige o Postgres |

### Dimensionamento

| Variável | Default | Descrição |
|---|---|---|
| `PGB_POOL_MODE` | `transaction` | mudar para `session` desfaz o ganho e as duas quebras acima |
| `PGB_DEFAULT_POOL_SIZE` | `20` | conexões **reais** por (database, usuário). Multiplica `work_mem` |
| `PGB_MAX_CLIENT_CONN` | `400` | conexões do lado **cliente**, ~2 KB cada |
| `PGB_MIN_POOL_SIZE` | `5` | conexões mantidas abertas mesmo ocioso |
| `PGB_RESERVE_POOL_SIZE` | `5` | conexões extras liberadas sob fila |
| `PGB_RESERVE_POOL_TIMEOUT` | `3` | segundos de fila antes de liberar a reserva |

### Tempos e ciclo de vida

| Variável | Default | Descrição |
|---|---|---|
| `PGB_MAX_PREPARED_STATEMENTS` | `200` | `0` quebra o PDO em modo nativo |
| `PGB_SERVER_IDLE_TIMEOUT` | `600` | fecha conexão de servidor ociosa. Um slot preso é um slot a menos para o pico |
| `PGB_SERVER_LIFETIME` | `3600` | recicla a conexão real. Evita que um backend acumule cache de catálogo pelo resto do mês |
| `PGB_QUERY_WAIT_TIMEOUT` | `30` | espera máxima na fila. Sem teto, uma consulta lenta transforma degradação em travamento |
| `PGB_SERVER_RESET_ALWAYS` | `1` | **não mexa.** É a guarda contra vazamento de estado entre clientes |

### Container

| Variável | Default | Descrição |
|---|---|---|
| `PGBOUNCER_PORT` | `6432` | porta publicada no host |
| `PGBOUNCER_BIND_IP` | `127.0.0.1` | publicá-lo na interface externa daria a qualquer um um caminho até o banco |
| `PGBOUNCER_MEMORY_LIMIT` | `128M` | orçamento de 03 §3.2. Single-threaded, ~2 KB por cliente |
| `PGBOUNCER_CPU_LIMIT` | `1` | |
| `PGB_LISTEN_PORT` | `6432` | porta **dentro** do container |
| `PGB_LOG_CONNECTIONS` | `0` | ligar só para diagnóstico: uma linha por conexão |
| `PGB_LOG_DISCONNECTIONS` | `0` | idem |
| `APP_NETWORK` | `baseempresarial` | rede da aplicação, para que Octane e Horizon alcancem o pooler pelo nome |
| `LOG_MAX_SIZE` / `LOG_MAX_FILE` | `50m` / `3` | teto de log do json-file driver |

## Diagnóstico

```bash
# conectar ao database de administração
psql -h 127.0.0.1 -p 6432 -U <PGB_USER> -d pgbouncer

SHOW POOLS;    # cl_active / cl_waiting / sv_active. cl_waiting > 0 sustentado = pool pequeno
SHOW STATS;    # total_xact_count, avg_query_time
SHOW LISTS;    # o que o healthcheck usa
```

`cl_waiting` sustentado acima de zero significa que `default_pool_size` está
apertado — mas subi-lo exige refazer a conta de `work_mem` acima.

## Testes

```bash
bash pgbouncer/test/pgbouncer.test.sh
```

Sobe Postgres + PgBouncer de verdade e afirma, entre outras coisas, que o
vazamento de `SET` entre clientes **não** acontece. Esse teste foi o que provou
que o vazamento existia antes das duas linhas de `server_reset_query`.
