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
| `ServidorSemColeta` | `sum by (host) (up{host!=""}) == 0` por 5 min | quando a máquina inteira some, o `AlvoForaDoAr` entrega uma notificação por job e nenhuma delas diz que a causa é comum. Aqui é um alerta só, e o suspeito é a máquina, o firewall ou a rota privada — não os serviços |

Os três juntos são o que evita o modo de falha mais insidioso desta stack:
falha de monitoramento é silenciosa por construção, porque o sistema que avisaria
é o que caiu.

O `sum by (host)` funciona onde um `count(up == 1) == 0` falharia: com todos os
alvos em zero a série **continua existindo** com valor 0, então o grupo não some
e a comparação avalia. O `host!=""` exclui o `blackbox`, cujos alvos são URLs e
não máquinas — sem ele, uma sonda falhando viraria "servidor sem coleta" de um
servidor que não existe.

### De qual máquina veio o alerta

Todo alerta com série carrega `{{ $labels.host }}`, que vem do **arquivo de
alvos** (o `setup.sh` escreve `labels.host` em cada um). Não confunda com o
`external_labels: host` do `prometheus.yml`: aquele só é aplicado a rótulos
*ausentes* na saída, então o nome real da máquina vence, e o nome do monitor
sobra como reserva para os alertas de `absent()` — que não têm série nenhuma de
onde herdar rótulo.

### Host

| Alerta | Limiar | Por quê |
|---|---|---|
| `DiscoQuaseCheio` | < 15% livres | o TSDB e o `PGDATA` dividem o mesmo NVMe; cardinalidade descontrolada derruba o **banco** |
| `DiscoEncheEm24h` | `predict_linear` 6h → 24h | pega o crescimento antes de virar incidente |
| `MemoriaDoHostCritica` | < 10% disponível | confira a soma dos limites de container contra a RAM real |
| `MemoriaSobPressao` | PSI de memória > 5% por 15 min | processos **parados** esperando memória. Vem antes do OOM killer e antes de `MemoriaDoHostCritica`: mede espera real, não espaço livre |
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

### Backup e WAL

Regras de [`backup.rules.yml`](../prometheus/rules/backup.rules.yml). As de
`Backup*` e `Repositorio*` dependem do textfile collector alimentado por
`pgbackrest-backup-run.sh`; as de `ArquivamentoDeWal*` saem do
`pg_stat_archiver` do postgres-exporter e valem mesmo sem o sidecar no ar.

| Alerta | Limiar | Por quê |
|---|---|---|
| `ArquivamentoDeWalNuncaAconteceu` | `absent(pg_stat_archiver_last_archive_age)` por 30 min | a série **não existe**: ou `archive_mode` está `off`, ou o cluster nunca arquivou. Usa `absent()` e não uma comparação justamente porque uma série ausente não dispara comparação nenhuma — o furo passaria despercebido no estado exato que se quer evitar. Efeito colateral a conhecer: `pg_stat_reset_shared('archiver')` zera `last_archived_time`, a série some e este alerta acende num cluster saudável. Um `pg_switch_wal()` a devolve |
| `ArquivamentoDeWalParado` | idade do último WAL > **6h30** por 10 min | o limiar acompanha o `check` do pgBackRest (6 h), que força uma troca de segmento. **Não** pode ser minutos: `archive_timeout` só fecha segmento quando houve escrita, e um banco de carga mensal fica horas sem gerar WAL — com um limiar curto isto seria `critical` permanente num sistema saudável |
| `ArquivamentoDeWalFalhando` | qualquer falha em 15 min | é este, e não o anterior, que pega o `archive_command` quebrado. Falha isolada é recuperável (o Postgres reexecuta); o que importa é a que persiste |
| `SemSegmentosDeWalNoRepositorio` | full existe, WAL não, por 30 min | o pior estado silencioso: o backup completo dá a impressão de cobertura, mas sem WAL não há recuperação a ponto no tempo |
| `NenhumBackupCompleto` | `backup_count{type="full"} == 0` | a stanza existe e está vazia |
| `RepositorioDeBackupComProblema` | `info_ok == 0` ou `repo_status_code != 0` por 15 min | é o `status` do `pgbackrest info` — repositório inacessível, stanza incoerente com o PGDATA |
| `ExecucaoDeBackupFalhou` | `run_last_success == 0` por 10 min | por tipo (`full`/`diff`/`incr`), publicado pelo `backup-run.sh` |
| `BackupCompletoAtrasado` | full com mais de 9 dias | 9 e não 7: dá folga para um full semanal atrasar sem virar ruído |
| `BackupDiferencialAtrasado` | sem full nem diff há 48 h | pega o agendador parado, que os alertas de "atrasado" por tipo não pegariam |
| `MetricasDeBackupAusentes` | sem métrica por 1 h | o sidecar não está publicando no textfile collector — a monitoração do backup está cega, mesmo que o backup rode |

> **O `check` e o limiar de `ArquivamentoDeWalParado` são um par.** Mudar
> `BDH_BACKUP_CHECK_SCHEDULE` sem mudar o limiar reintroduz o falso positivo.

### Sondas externas e SLO

Regras de [`blackbox.rules.yml`](../prometheus/rules/blackbox.rules.yml). Olham o
site **de fora**, pela borda — é a única família que mede o que o visitante vê.

| Alerta | Limiar | Por quê |
|---|---|---|
| `SondaFalhando` | sonda falha por 5 min | disponibilidade da rota, não do container |
| `DisponibilidadeAbaixoDoSlo` | < 99,5% em 24 h | orçamento de erro, não incidente pontual |
| `SloBordaHitEstourado` | p95 > 60 ms | resposta servida pela borda: se isto sobe, o problema é a CDN, não a origem |
| `SloCondicional304Estourado` | p95 > 40 ms | o 304 condicional é o que poupa o PHP; degradou, o crawler passa a bater na origem |
| `SloEmpresaPorCnpjEstourado` | p95 > 200 ms | página de empresa |
| `SloHubTerritorialEstourado` | p95 > 250 ms | hub territorial |
| `SloAutocompleteEstourado` | p95 > 80 ms | autocomplete, o mais sensível: é por tecla digitada |
| `SloBuscaEstourado` | p95 > 200 ms | busca com filtros |
| `RotaAnonimaVazandoEstadoDeSessao` | cookie ou `Cache-Control` privado em rota pública | **critical**, e não é performance: uma resposta com `Set-Cookie` numa rota pública envenena o cache da borda com a sessão de alguém |
| `BordaParouDeCachear` | origem responde e a borda não cacheia | pega a Cache Rule removida ou um cabeçalho que passou a recusar cache — o site continua no ar e a origem passa a levar 100% do tráfego |
| `CertificadoExpirando` | menos de 14 dias | |
| `PortaDeDadosAlcancavelDeFora` | porta de dados aceita conexão externa | **critical**. Postgres, Redis e OpenSearch só devem escutar na rede privada; o OpenSearch não tem autenticação nenhuma |

### Motor de busca (OpenSearch)

Regras de [`opensearch.rules.yml`](../prometheus/rules/opensearch.rules.yml). O
OpenSearch publica `/metrics` nativamente (plugin na imagem) — não há exporter.

| Alerta | Limiar | Por quê |
|---|---|---|
| `ClusterDeBuscaDegradado` | `cluster_status > 0` por 5 min | YELLOW ou RED. Em nó único, YELLOW já significa shard não alocado |
| `MotorDeBuscaForaDoAr` | sem métrica por 10 min | |
| `HeapDoMotorAlto` | heap > **85%** por 15 min | heap cheio precede o GC constante abaixo |
| `GcVelhoConstante` | GC velho > 10% do tempo por 10 min | **critical**: a JVM está viva e não trabalha. Costuma ser heap subdimensionado ou agregação cara demais |
| `BreakerDisparando` | qualquer circuit breaker por 15 min | com `fielddata` em 0%, um breaker disparando é erro de consulta — alguém agregou num campo sem `doc_values` |
| `LatenciaMediaDeBuscaAlta` | média > **100 ms** por 15 min | média por consulta, derivada de `query_time / query_count` |
| `FilaDeEscritaCrescendo` | fila de escrita > **100** tarefas por 10 min | indexação mais rápida que o cluster aguenta; aparece durante a carga |
| `DiscoDoMotorPertoDoFloodStage` | uso > **70%** por 30 min | o `flood_stage` do perfil é 90%; 70% dá margem para agir. No `flood_stage` **todos** os índices viram read-only e a busca para — a interrupção autoinfligida nº 1 desta classe de serviço |
| `IndiceDesatualizado` | sem carga bem-sucedida há **72 h** | o motor responde, com dados velhos — falha que nenhum health check pega. Também depende de `bdh_indexer_*` |
| `DivergenciaDeContagemComOPostgres` | divergência relativa acima do limiar por 15 min | **critical**: o índice e a fonte discordam. Pega a carga que terminou pela metade e mesmo assim trocou o alias. Depende das séries `bdh_indexer_*`, publicadas pelo search-indexer |

### A monitoração vigiando a si mesma

Duas regras existem para o modo de falha que todas as outras têm em comum: elas
só valem se alguém for notificado. Um Alertmanager fora do ar deixa as 52 regras
restantes tecnicamente corretas e operacionalmente mudas.

| Alerta | Limiar | Por quê |
|---|---|---|
| `AlertmanagerForaDoAr` | `absent(up{job="alertmanager"})` ou `up == 0` por 5 min | **critical**. Enquanto ele estiver fora, nenhum alerta chega a ninguém — inclusive este, que fica visível só no painel e no `bdh metrics` |
| `NotificacaoFalhando` | qualquer falha de entrega em 15 min | o Alertmanager está de pé e o destino recusa: webhook expirado, canal removido, SMTP negando. O alerta é entregue pelas integrações que ainda funcionam |

`AlertmanagerForaDoAr` usa `absent()` pelo mesmo motivo de
`ArquivamentoDeWalNuncaAconteceu`: sem a série, nenhuma comparação avalia, e o
silêncio pareceria saúde.

> Estas duas não substituem uma verificação de ponta a ponta. Que a notificação
> **chega ao canal final** é coisa que só um disparo de teste prova — vale
> repetir a cada mudança de webhook.

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
