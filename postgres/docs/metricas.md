# Métricas do PostgreSQL

O que o `postgres_exporter` coleta nesta infraestrutura, quanto custa e por que
vários coletores estão desligados. A stack que consome estas métricas está em
[`../../monitoring/`](../../monitoring/).

Duas coisas a imagem já tinha antes desta camada existir, e é por isso que ela
saiu barata: `pg_stat_statements` pré-carregado e `track_io_timing = on`
(`generate-config.sh`).

## A role `metrics_read`

O exporter conecta com uma role dedicada, nunca com o superusuário:

| | |
|---|---|
| Privilégio | `pg_monitor` (= `pg_read_all_settings` + `pg_read_all_stats` + `pg_stat_scan_tables`) |
| Acesso a dados | **nenhum** — não há `SELECT` em tabela alguma |
| `statement_timeout` | `10s` |
| `idle_in_transaction_session_timeout` | `30s` |
| `CONNECTION LIMIT` | `5` |

Os timeouts têm um motivo mais forte aqui do que na `dados_read`: um scrape
travado segura o snapshot, e durante o ETL isso atrasa o autovacuum de **todas**
as tabelas. O exporter jamais pode ser a causa de bloat.

O `CONNECTION LIMIT` protege o `max_connections` do perfil (100 no
`dedicada-8gb`) de um exporter em restart loop.

### Criando a role

O mesmo arquivo — [`../initdb/03-role-metrics.sh`](../initdb/03-role-metrics.sh)
— cobre os dois casos, e isso é deliberado: dois caminhos divergiriam com o
tempo. Ele é idempotente, então pode rodar de novo sem efeito.

**Instalação nova.** Roda sozinho no `initdb`, depois do `02-role-dados-read.sh`.
Nada a fazer.

**Cluster que já existe** — o caso de produção, já que o entrypoint não repete o
`initdb` num volume inicializado:

```bash
docker exec -i -e PG_METRICS_PASSWORD='...' \
    "$(docker ps -q --filter label=org.brasildatahub.service=postgres)" \
    bash -s < 03-role-metrics.sh
```

`POSTGRES_DB` e `POSTGRES_USER` não precisam ser passados: já estão no ambiente
do container. O `infra-setup.sh --metrics` faz exatamente isso.

Conferindo:

```sql
SELECT rolname FROM pg_auth_members m
  JOIN pg_roles r ON r.oid = m.roleid
 WHERE member = 'metrics_read'::regrole;      -- deve listar pg_monitor
```

### Onde fica a senha, e por que não no `.env`

Em `.env.metrics`, ao lado do `.env`, como `DATA_SOURCE_PASS`.

A razão é concreta e foi medida: `env_file` faz parte da definição do serviço,
então acrescentar **qualquer** variável ao `.env` muda o hash de configuração e o
Compose **recria o container do banco**. Ligar métricas não pode custar o restart
de um banco de centenas de GB — downtime e page cache frio. Com o segredo à
parte, o serviço `postgres` fica byte a byte idêntico e só o container do
exporter é criado. Há um teste na CI que falha se isso regredir.

O Redis não precisa do mesmo cuidado: o `redis_exporter` lê `REDIS_PASSWORD`,
que já está no `.env`, sem acrescentar nada.

## Coletores

Contra os defaults do `postgres_exporter v0.20.1`.

### Desligados

| Coletor | Por quê |
|---|---|
| `stat_user_tables`, `statio_user_tables` | ~10 séries **por tabela e por partição**, varrendo `pg_stat_all_tables` a cada scrape. Num schema particionado é o maior gerador de cardinalidade da stack |
| `replication`, `replication_slots`, `stat_replication` | não há réplica na org; vêm ligados por default e só geram queries que voltam vazias |
| `stat_statements` | já é o default; **não ligue** — ver abaixo |

O custo de desligar `stat_user_tables` é perder `n_dead_tup` e `last_autovacuum`
por tabela. Se o seu schema tiver poucas dezenas de tabelas e você quiser esse
par de volta, remova as duas linhas `--no-collector.*` do overlay e observe
`count by (job) ({__name__=~".+"})` antes e depois.

### Ligados (vêm desabilitados por default, e são o que importa aqui)

| Coletor | Por quê |
|---|---|
| `stat_checkpointer` | o PG17 moveu os campos de checkpoint para fora do `pg_stat_bgwriter`. Sem ele o efeito do `checkpoint_timeout=15min` dos perfis é **invisível** |
| `long_running_transactions` | ETL segurando `xmin` é a causa nº1 de bloat que o autovacuum não resolve |
| `database_wraparound` | carga em massa de dezenas de milhões de linhas torna wraparound risco real |
| `stat_activity_autovacuum` | mostra o autovacuum competindo com o ETL pela mesma janela de IO |
| `postmaster` | uptime: distingue "o banco está lento" de "o banco reiniciou há 3 minutos" |

### Por que `stat_statements` fica de fora

O `queryid` vira **label**. Os perfis definem `pg_stat_statements.max` entre 5.000
e 10.000, e cada query nova do ETL cria séries que nunca mais recebem amostra —
crescimento sem teto num TSDB que divide disco com o banco.

`pg_stat_statements` continua pré-carregado e serve para diagnóstico interativo
via `psql`, que é para o que foi habilitado. Se precisar dele como série temporal
por algumas horas, ligue com consciência do custo e desligue depois.

### `auto-discover-databases`

Desligado (e marcado como deprecated no upstream). Multiplicaria todas as séries
pelo número de bancos e abriria uma conexão por banco.

## Custo

Medido num host com o banco recém-criado:

| | |
|---|---|
| Séries expostas pelo exporter | ~600 |
| Duração dos coletores | 0,6 a 5 ms cada |
| Scrape interval | **30s** (não os 15s do global) |
| `--collection-timeout` | `8s`, abaixo do `scrape_timeout` de 10s do Prometheus |

O interval de 30s existe porque cada scrape dispara ~12 queries de catálogo que,
durante o ETL, competem com a carga real. **Consequência para dashboards:**
janelas de `rate()` do Postgres precisam ser ≥ `2m` (mínimo saudável é 4× o
intervalo de scrape), senão os painéis ficam com buracos.

O `--collection-timeout` menor que o `scrape_timeout` faz o exporter desistir
primeiro e devolver coleta parcial, em vez de derrubar o scrape inteiro.

### O coletor a vigiar

`database` chama `pg_database_size()`, que percorre com `stat()` cada arquivo do
datadir. A 30s é aceitável numa base de centenas de GB com page cache quente. Se
começar a pesar:

```promql
pg_scrape_collector_duration_seconds{collector="database"}
```

Passando de ~1s de forma consistente, acrescente `--no-collector.database` ao
overlay — o tamanho do banco também aparece via `node_filesystem_*`.

## Troubleshooting

**O alvo `postgres` está `up == 0` e o log do exporter mostra erro de
autenticação.** A role não existe ou a senha divergiu. Rode o
`03-role-metrics.sh` (acima) com a senha de `.env.metrics`.

**`WARN Error loading config ... postgres_exporter.yml: no such file`** no start
do exporter. É ruído esperado do upstream: o arquivo de config é opcional e não
usamos nenhum — toda a configuração vem de flags e envs. Não indica problema.

**Um painel do dashboard "PostgreSQL Database" está vazio.** Provavelmente
depende de `stat_user_tables` ou das métricas de checkpoint pré-PG17. O que está
coberto e o que não está: [`../../monitoring/grafana/dashboards/UPSTREAM.md`](../../monitoring/grafana/dashboards/UPSTREAM.md).

**As séries por job cresceram muito.** `bdh metrics` mostra a contagem. Suspeite
primeiro de `stat_statements` ou `stat_user_tables` ligados "para investigar uma
coisa" e esquecidos assim.
