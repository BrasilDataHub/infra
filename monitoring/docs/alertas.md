# Alertas

Regras em [`../prometheus/rules/`](../prometheus/rules/), embutidas na imagem do
Prometheus. Janelas `for:` generosas; testes unitários cobrem não-disparo nos
casos limítrofes.

## Notificação

Alerting unificado do Grafana (datasource provisionado). Contact point em
*Alerting → Contact points*; casa com `--webhook-url` do `setup.sh`. Sem contact
point: alertas no painel **Alertas disparando** e em `bdh metrics`, sem notificar.

## Coleta

| Alerta | Dispara quando | Nota |
|---|---|---|
| `AlvoForaDoAr` | `up == 0` por 5 min | 5 min (não 1): scrape isolado sob ETL satura timeout |
| `JobSemAlvo` | `absent(up{job=...})` por 15 min | arquivo de target sumiu — `up == 0` nunca pega |
| `ServidorSemColeta` | `sum by (host) (up{host!=""}) == 0` por 5 min | máquina/firewall/rota; `host!=""` exclui blackbox |

`sum by (host)` funciona com todos os alvos em 0 (série existe). Label
`{{ $labels.host }}` vem do arquivo de alvos (`labels.host` do `setup.sh`).
`external_labels: host` do `prometheus.yml` só preenche rótulos ausentes
(reserva para `absent()`).

## Host

| Alerta | Limiar |
|---|---|
| `DiscoQuaseCheio` | < 15% livres (TSDB e `PGDATA` no mesmo NVMe) |
| `DiscoEncheEm24h` | `predict_linear` 6h → 24h |
| `MemoriaDoHostCritica` | < 10% disponível |
| `MemoriaSobPressao` | PSI memória > 5% por 15 min (antes do OOM) |
| `IOSaturado` | PSI stalled > 30% por 15 min (inerte sem `CONFIG_PSI`) |

## Containers

`ContainerPertoDoLimiteDeMemoria` — só com cAdvisor (`COMPOSE_PROFILES=containers`):
`container_memory_working_set_bytes` vs `container_spec_memory_limit_bytes`.

## PostgreSQL

| Alerta | Limiar |
|---|---|
| `PostgresConexoesPertoDoLimite` | > 85% de `max_connections` (perfis 100–300) |
| `TransacaoLongaSegurandoXmin` | transação aberta > 1h |
| `WraparoundSeAproximando` | `datfrozenxid` > 1 bilhão (em 2B para de escrever) |
| `MuitosArquivosTemporarios` | > 50 MB/s por 15 min |
| `CheckpointsForcadosDemais` | forçados > agendados por 30 min (exige `stat_checkpointer`) |
| `DeadlocksFrequentes` | qualquer deadlock em 10 min |
| `CacheHitBaixo` | < 95% por 1 hora |

```sql
SELECT pid, state, xact_start, now() - xact_start AS idade, query
  FROM pg_stat_activity
 WHERE xact_start < now() - interval '1 hour'
 ORDER BY xact_start;
```

## Redis

| Alerta | Limiar |
|---|---|
| `RedisDespejandoChaves` | qualquer despejo em 10 min (`volatile-lru` = só com TTL) |
| `RedisPertoDoMaxmemory` | > 90% (limite container ≈ 2× `maxmemory`) |
| `RedisRecusandoConexoes` | qualquer recusa |
| `FilaDoHorizonCrescendo` | > 10 mil itens crescendo por 30 min |

`FilaDoHorizonCrescendo` exige `REDIS_METRICS_KEYS` (`-check-single-keys`).
Variantes com `SCAN` (`--check-keys`, `--count-keys`) param Redis single-thread.

## Backup e WAL

[`backup.rules.yml`](../prometheus/rules/backup.rules.yml). `Backup*` /
`Repositorio*` via textfile + `pgbackrest-backup-run.sh`; `ArquivamentoDeWal*`
via `pg_stat_archiver` (vale sem sidecar).

| Alerta | Limiar |
|---|---|
| `ArquivamentoDeWalNuncaAconteceu` | `absent(…last_archive_age)` por 30 min (`archive_mode` off ou nunca arquivou; `pg_stat_reset_shared('archiver')` também acende — `pg_switch_wal()` devolve) |
| `ArquivamentoDeWalParado` | idade último WAL > **6h30** por 10 min (par do `check` pgBackRest 6 h; não minutos — banco ocioso não gera WAL) |
| `ArquivamentoDeWalFalhando` | qualquer falha em 15 min (`archive_command` quebrado) |
| `SemSegmentosDeWalNoRepositorio` | full existe, WAL não, por 30 min |
| `NenhumBackupCompleto` | `backup_count{type="full"} == 0` |
| `RepositorioDeBackupComProblema` | `info_ok == 0` ou `repo_status_code != 0` por 15 min |
| `ExecucaoDeBackupFalhou` | `run_last_success == 0` por 10 min (por tipo) |
| `BackupCompletoAtrasado` | full > 9 dias |
| `BackupDiferencialAtrasado` | sem full nem diff há 48 h |
| `MetricasDeBackupAusentes` | sem métrica por 1 h |

> Mudar `BDH_BACKUP_CHECK_SCHEDULE` sem mudar o limiar de
> `ArquivamentoDeWalParado` reintroduz falso positivo.

## Sondas e SLO

[`blackbox.rules.yml`](../prometheus/rules/blackbox.rules.yml) — vista de fora.

| Alerta | Limiar |
|---|---|
| `SondaFalhando` | falha por 5 min |
| `DisponibilidadeAbaixoDoSlo` | < 99,5% em 24 h |
| `SloBordaHitEstourado` | p95 > 60 ms |
| `SloCondicional304Estourado` | p95 > 40 ms |
| `SloEmpresaPorCnpjEstourado` | p95 > 200 ms |
| `SloHubTerritorialEstourado` | p95 > 250 ms |
| `SloAutocompleteEstourado` | p95 > 80 ms |
| `SloBuscaEstourado` | p95 > 200 ms |
| `RotaAnonimaVazandoEstadoDeSessao` | cookie ou `Cache-Control` privado em rota pública (**critical**) |
| `BordaParouDeCachear` | origem ok, borda não cacheia |
| `CertificadoExpirando` | < 14 dias |
| `PortaDeDadosAlcancavelDeFora` | porta de dados aceita conexão externa (**critical**) |

## OpenSearch

[`opensearch.rules.yml`](../prometheus/rules/opensearch.rules.yml) — `/metrics`
nativo, sem exporter.

| Alerta | Limiar |
|---|---|
| `ClusterDeBuscaDegradado` | `cluster_status > 0` por 5 min (YELLOW/RED) |
| `MotorDeBuscaForaDoAr` | sem métrica por 10 min |
| `HeapDoMotorAlto` | heap > **85%** por 15 min |
| `GcVelhoConstante` | GC velho > 10% do tempo por 10 min (**critical**) |
| `BreakerDisparando` | qualquer circuit breaker por 15 min |
| `LatenciaMediaDeBuscaAlta` | média > **100 ms** por 15 min |
| `FilaDeEscritaCrescendo` | fila escrita > **100** por 10 min |
| `DiscoDoMotorPertoDoFloodStage` | uso > **70%** por 30 min (`flood_stage` do perfil = 90%) |
| `IndiceDesatualizado` | sem carga ok há **72 h** (`bdh_indexer_*`) |
| `DivergenciaDeContagemComOPostgres` | divergência relativa acima do limiar por 15 min (**critical**, `bdh_indexer_*`) |

## Auto-monitoração

| Alerta | Limiar |
|---|---|
| `AlertmanagerForaDoAr` | `absent(up{job="alertmanager"})` ou `up == 0` por 5 min (**critical**) |
| `NotificacaoFalhando` | falha de entrega em 15 min |

Não substituem teste ponta a ponta do canal final após mudança de webhook.

## Testando

```bash
bash monitoring/test/prometheus-config.test.sh
```

Inclui `promtool test rules` (disparo e não-disparo). Ao vivo:

```bash
bdh metrics
curl -s http://127.0.0.1:9090/api/v1/rules | jq '.data.groups[].name'
```
