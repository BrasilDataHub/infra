# Alertas

As regras vivem em [`../prometheus/rules/`](../prometheus/rules/), embutidas na
imagem do Prometheus. Cada uma responde a um modo de falha desta operação — ETL
de centenas de milhões de linhas, base de centenas de GB, Redis com cache e fila
na mesma instância —, não a uma lista genérica.

Alerta que dispara à toa é desligado pela operação em duas semanas, e aí a
monitoração vira enfeite. Por isso as janelas `for:` são generosas e há testes
unitários provando que a regra **não** dispara nos casos limítrofes.

## Notificação

Sem Alertmanager: a notificação usa o **alerting unificado do Grafana**, que já
lê o datasource provisionado. É um container a menos, um lugar a menos para
configurar rota e silêncio, e o contact point de webhook casa com o
`--webhook-url` que o `setup.sh` já aceita.

Configure em *Alerting → Contact points* no Grafana. Enquanto nenhum contact
point existir, os alertas aparecem no painel **Alertas disparando** da Visão
geral e em `bdh metrics`, mas não notificam ninguém.

## O que cada regra vigia

### Coleta

| Alerta | Dispara quando | Por quê |
|---|---|---|
| `AlvoForaDoAr` | `up == 0` por 5 min | 5 min e não 1: sob ETL com IO saturado um scrape isolado estoura o timeout, e alertar nisso treina a operação a ignorar |
| `JobSemAlvo` | `absent(up{job=...})` por 15 min | pega o caso que o `up == 0` **nunca** pegaria: o arquivo de target sumiu, não há série nenhuma para avaliar, e a monitoração daquele serviço está desligada sem ninguém ter pedido |

Os dois juntos são o que evita o modo de falha mais insidioso desta stack:
falha de monitoramento é silenciosa por construção, porque o sistema que avisaria
é o que caiu.

### Host

| Alerta | Limiar | Por quê |
|---|---|---|
| `DiscoQuaseCheio` | < 15% livres | o TSDB e o `PGDATA` dividem o mesmo NVMe; cardinalidade descontrolada derruba o **banco** |
| `DiscoEncheEm24h` | `predict_linear` 6h → 24h | pega o crescimento antes de virar incidente |
| `MemoriaDoHostCritica` | < 10% disponível | confira a soma dos limites de container contra a RAM real |
| `IOSaturado` | PSI stalled > 30% por 15 min | distingue "ETL pesado" de "disco no teto" — em NVMe o `%util` satura em 100% sem o disco estar no limite |

`IOSaturado` fica inerte onde não há `CONFIG_PSI` (a VM do Docker no macOS).

### Containers

`ContainerPertoDoLimiteDeMemoria` só existe com o cAdvisor ligado
(`COMPOSE_PROFILES=containers`). É o par `container_memory_working_set_bytes` vs
`container_spec_memory_limit_bytes` — exatamente o que teria detectado o
incidente de `Memory=0` de
[`../../postgres/docs/troubleshooting.md`](../../postgres/docs/troubleshooting.md),
em que um perfil aplicado pela metade deixou o container sem limite.

### PostgreSQL

| Alerta | Limiar | Por quê |
|---|---|---|
| `PostgresConexoesPertoDoLimite` | > 85% do `max_connections` | os perfis fixam 100–300; estourar rejeita conexão. Antes de subir o teto, confirme o pool — mais conexões multiplicam o `work_mem` alocável |
| `TransacaoLongaSegurandoXmin` | transação aberta > 1h | causa nº1 de bloat que o autovacuum não resolve; o sintoma só aparece horas depois, como disco cheio |
| `WraparoundSeAproximando` | `datfrozenxid` > 1 bilhão | em 2 bilhões o Postgres **para de aceitar escrita** |
| `MuitosArquivosTemporarios` | > 50 MB/s por 15 min | queries derramando em disco; parente do incidente de `/dev/shm` |
| `CheckpointsForcadosDemais` | forçados > agendados por 30 min | `max_wal_size` pequeno para a carga de escrita; cada checkpoint forçado é um pico de IO no meio do ETL |
| `DeadlocksFrequentes` | qualquer deadlock em 10 min | `log_lock_waits` já está ligado; os detalhes estão no log |
| `CacheHitBaixo` | < 95% por 1 hora | janela longa de propósito: leitura fria durante ETL é legítima |

`CheckpointsForcadosDemais` só existe porque o `collector.stat_checkpointer` está
ligado — o PG17 moveu esses campos para fora do `pg_stat_bgwriter`, e com os
defaults do exporter o efeito do `checkpoint_timeout` seria invisível.

Consultas úteis quando `TransacaoLongaSegurandoXmin` disparar:

```sql
SELECT pid, state, xact_start, now() - xact_start AS idade, query
  FROM pg_stat_activity
 WHERE xact_start < now() - interval '1 hour'
 ORDER BY xact_start;
```

### Redis

| Alerta | Limiar | Por quê |
|---|---|---|
| `RedisDespejandoChaves` | qualquer despejo em 10 min | com `volatile-lru` só chaves **com TTL** são despejadas: cache perdido — e, se alguma chave de fila ganhou TTL por engano, **trabalho perdido** |
| `RedisPertoDoMaxmemory` | > 90% | suba de perfil (limite de container ≈ 2× `maxmemory`, pelo fork do AOF) |
| `RedisRecusandoConexoes` | qualquer recusa | o Horizon abre uma conexão por worker |
| `FilaDoHorizonCrescendo` | > 10 mil itens crescendo por 30 min | worker parado ou job que falha e volta para a fila |

`FilaDoHorizonCrescendo` só produz série se `REDIS_METRICS_KEYS` estiver definida
no `.env` do Redis (o `-check-single-keys` do exporter). Sem isso a regra fica
inerte — de propósito: as variantes que varrem o keyspace (`--check-keys`,
`--count-keys`) fazem `SCAN` a cada scrape e param um Redis single-thread.

## Testando as regras

```bash
bash monitoring/test/prometheus-config.test.sh
```

Inclui `promtool test rules` com casos que provam tanto o disparo quanto o
não-disparo (scrape instável por 2 minutos, conexões em 50%, zero despejos). Ao
mexer numa regra, acrescente o caso negativo junto — é ele que protege a
operação do ruído.

Para ver o estado ao vivo:

```bash
bdh metrics
curl -s http://127.0.0.1:9090/api/v1/rules | jq '.data.groups[].name'
```
