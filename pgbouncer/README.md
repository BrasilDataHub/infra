# PgBouncer

> Item 18 do roadmap 20 (arquitetura de busca).

Pool de conexões entre a aplicação e o Postgres, em **transaction pooling**.
400 clientes sobre 20 conexões reais.

## Onde ele roda

**No host da aplicação, não no host do banco.** O ganho do pooler é encurtar o
caminho de abertura de conexão que o *cliente* percorre; do lado do banco, cada
nova conexão do Octane pagaria o RTT de rede antes de encontrar o pool.

O número de travessias de rede é o **mesmo** nos dois arranjos — o que muda é
qual perna fica local:

```
no host da aplicação   app ─(local)─ pooler ─(rede)─ banco    ← a perna de rede é reusada
no host do banco       app ─(rede)─ pooler ─(local)─ banco    ← a perna de rede é reaberta
```

Medido em 31/07/2026 (RTT de 0,483 ms entre os dois hosts, rede privada), do
container da aplicação, com o pooler no host da aplicação:

| | direto no banco | pelo pooler |
|---|---|---|
| abrir conexão + 1 consulta | 11,20 ms · p95 **14,35 ms** | 9,76 ms · p95 **10,12 ms** |
| consulta em conexão persistente | 0,665 ms | 0,949 ms |

Duas leituras, e as duas importam:

- **Abrir é mais rápido e muito mais previsível** pelo pooler — o p95 cai 30%.
  É o que o arranjo do lado do cliente compra.
- **Cada consulta custa ~0,3 ms a mais.** É o salto extra pelo proxy mais o
  `DISCARD ALL` por transação. Numa página com 10 consultas, ~3 ms sobre 60 ms.

O pooler não é uma otimização de latência: ele **cobra** latência por consulta
e paga com o teto de conexões. Ligá-lo com folga de conexões sobrando é perda
líquida.

### Quando mover para o host do banco passa a valer

Com **mais de um host de aplicação**. Do lado do cliente, cada host tem o
próprio pool: N hosts são `N × default_pool_size` conexões reais. Do lado do
banco, um pooler serve todos com um pool só.

O preço de mover: o pooler vira ponto único de falha para todas as aplicações
(no lado do cliente ele cai junto com o host que já estava fora), a abertura de
conexão passa a pagar RTT, e a porta `6432` precisa entrar no firewall do host
do banco — a chain `DOCKER-USER` do `setup.sh` conhece 5432, 9100 e 9187, e
**não** conhece a 6432.

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

## A rede da aplicação

O pooler só serve se a aplicação **enxergar** o container dele. Dentro do
container da aplicação, `127.0.0.1:6432` é o loopback DELA — não chega aqui.

| Como a aplicação é implantada | O que fazer |
|---|---|
| Mesmo `docker compose`, ou rede criada por este compose | nada: `APP_NETWORK` cria a rede e o alias `pgbouncer` resolve |
| Painel que cria a própria rede (Dokploy, Coolify, Swarm) | `APP_NETWORK=<rede do painel>` **e** o overlay [`docker-compose.rede-externa.yml`](docker-compose.rede-externa.yml) |

No segundo caso o overlay não é opcional: sem `external: true` o compose recusa
uma rede que ele não criou, e a saída manual (`docker network connect`) não
sobrevive ao próximo `up -d` — o container volta sem a rede, no meio de um
deploy que parecia rotineiro.

Num host do `setup.sh`, instale o overlay como `docker-compose.override.yml`:
é o nome que o helper `bdh` inclui sozinho.

```bash
cp docker-compose.rede-externa.yml \
   /opt/brasildatahub/services/pgbouncer/docker-compose.override.yml
echo 'APP_NETWORK=dokploy-network' >> /opt/brasildatahub/services/pgbouncer/.env
bdh up pgbouncer
```

Confira o alias depois de qualquer recriação:

```bash
docker inspect pgbouncer-pgbouncer-1 \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.Aliases}}{{println}}{{end}}'
```

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

Medido em 31/07/2026 contra o PgBouncer 1.24.1, a partir do container de uma
aplicação Laravel, em duas conexões e dois bancos: **15/15 consultas OK com
`PDO::ATTR_EMULATE_PREPARES` em `false`**. Com `max_prepared_statements`
configurado, emular no driver deixa de ser necessário — e `false` é o valor
melhor, porque preserva a reutilização de plano do lado do servidor.

Quem baixar este valor para `0` precisa ligar a emulação na aplicação no mesmo
movimento.

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

### Mais de um banco, mais de um usuário

Uma aplicação com dois bancos no mesmo servidor precisa dos **dois declarados**:
o PgBouncer roteia pelo `dbname` do handshake e recusa o que não estiver na
seção `[databases]` com `no such database`. O mesmo vale para o usuário, que é
recusado no handshake se não estiver no `userlist`.

| Variável | Default | Descrição |
|---|---|---|
| `PGB_EXTRA_DATABASES` | — | bancos adicionais, separados por `;`. `nome` usa o `PGB_DB_HOST`; `nome=host` usa outro |
| `PGB_EXTRA_USERS` | — | usuários adicionais, `usuario=senha`, separados por `;` |

```bash
PGB_EXTRA_DATABASES="baseempresarial"
PGB_EXTRA_USERS="dados_read=<senha>"
```

**Sem isto, a única saída é apontar tudo para o superusuário** — o que troca um
pooler por uma escalação de privilégio. Uma conexão que era somente-leitura
passa a poder escrever em qualquer tabela.

Cada par (database, usuário) tem pool **próprio** de `default_pool_size`
conexões: dois bancos com um usuário cada são `2 × 20 = 40` conexões reais no
pior caso. Confira contra o `max_connections` do servidor antes de crescer.

Senha com `;` ou `=` não passa por `PGB_EXTRA_USERS`.

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

## O que NÃO mandar pelo pooler

Consultas que seguram a conexão por minutos — exportações, geração de sitemap,
relatórios que varrem a base inteira. Em `transaction` pooling elas ocupam um
slot durante toda a varredura, e o `query_wait_timeout` passa a devolver erro
para as requisições que ficam na fila. O pooler existe para muitas conexões
curtas; carga longa é o caso em que ele piora as coisas.

Dê a essas cargas uma conexão direta ao Postgres, com o mesmo usuário.

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
