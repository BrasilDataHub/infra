# Armazenamento

Onde cada coisa fica, quanto ocupa e como acomodar o pico do ciclo mensal.

## Layout

| Dispositivo | Tamanho | Montagem | Conteúdo |
|---|---|---|---|
| `sda1` — NVMe local | 226 GB | `/` | `PGDATA`, `pg_wal`, imagens e volumes Docker |
| `sdb` — Hetzner Volume | 344 GB | `/mnt/bdh-backup` | pgBackRest, insumos da carga, geração N−1 |

**`PGDATA` fica no NVMe local. Sempre.**

## Desempenho

Medido com `fio`, `--direct=1`, `iodepth=32`, 20 s:

| Teste | NVMe local | Hetzner Volume | Razão |
|---|---|---|---|
| leitura sequencial 1M | 14.893 MB/s | 301 MB/s | 49× |
| escrita sequencial 1M | 10.459 MB/s | 301 MB/s | 35× |
| leitura aleatória 8K | **133.664 IOPS** | **7.537 IOPS** | **17,7×** |
| escrita aleatória 8K | **121.169 IOPS** | **7.536 IOPS** | **16,1×** |
| latência p95 (rand read) | 0,31 ms | 4,49 ms | 14,5× |

Bloco 8K = página do PostgreSQL. Volume entrega ~6 % dos IOPS do NVMe; com
`shared_buffers` 10 GB / banco 141 GB / `cache_hit` ~83 %, leituras ao disco no
volume custariam ~14× mais latência.

Volume satura ~300 MB/s e ~7.500 IOPS — ok para escrita sequencial (backup,
carga); insuficiente para leitura aleatória (consulta).

| Uso | Serve? |
|---|---|
| Repositório de backup | **sim** (full 137 GB ≈ 3 min 44 s) |
| Insumos da carga | **sim** |
| Geração N−1 após publicação | **sim** |
| `PGDATA` em produção | **não** |
| Construção de geração nova | **caso a caso** (índices = leitura aleatória) |

## Quanto ocupa

Uma geração:

| Item | Tamanho |
|---|---|
| Banco `dados_cnpj` | **141 GB** (heap 50 GB + índices 90 GB) |
| `pg_wal` | 29 GB |
| **Total no `sda1`** | **173 GB de 226 GB (81 %)** |
| Repositório de backup | 56 GB de 344 GB (17 %) |

| Tabela | Total | Heap | Índices |
|---|---|---|---|
| `estabelecimento` | 51 GB | 15 GB | 36 GB |
| `busca_estabelecimento` | 35 GB | 15 GB | 20 GB |
| `empresa` | 23 GB | 6,1 GB | 17 GB |
| `estabelecimento_cnae_sec` | 18 GB | 8,0 GB | 10 GB |
| `simples` | 6,9 GB | 2,6 GB | 4,3 GB |
| `socio` | 5,9 GB | 3,1 GB | 2,8 GB |

**Índices = 64 % do banco.** ~50 GB sem uso registrado — ver `index_cleanup` no
pipeline. Crescimento mensal é pequeno; o problema é o **pico do ciclo**.

## Pico do ciclo mensal

Blue/green: duas gerações no NVMe durante a carga.

```
                     ┌── geração N   (servindo)      141 GB
sda1 · 226 GB   ─────┤── geração N+1 (carregando)    141 GB
                     └── pg_wal                       29 GB
                                                     ─────
                                                     311 GB   ✗ não cabe
```

O volume **não** resolve o pico de construção (índices = IOPS aleatório). Resolve
o momento seguinte: guardar N−1 após publicação.

| Cenário | `sda1` | Cabe? |
|---|---|---|
| Fora do ciclo, uma geração | 170 GB (75 %) | sim |
| Ciclo, sem poda de índices | 311 GB | **não — faltam 85 GB** |
| Ciclo, com poda (−50 GB/geração) | 211 GB (93 %) | apertado |
| Ciclo, poda + `max_wal_size=8GB` | 190 GB (84 %) | **sim** |

**Poda de índices é pré-requisito do ciclo mensal.**

Depois de publicar:

```
sda1 · 226 GB    geração corrente + pg_wal      99–170 GB   (44–75 %)
sdb  · 344 GB    backup + insumos + N−1        ~249 GB      (72 %)
```

### `max_wal_size`

`sighup` — `SELECT pg_reload_conf()`, sem restart. **Reduzir não devolve espaço
já ocupado.** Checkpoint só reavalia segmentos **atrás** do LSN; pré-alocados à
frente só voltam quando o WAL avança. Em cluster ocioso o `pg_wal` fica no
tamanho em que estava.

Parâmetro = teto para o **próximo** ciclo. Liberar agora exige gerar WAL
(a carga mensal faz). Definir em `PG_MAX_WAL_SIZE` no `.env` (sobrevive a
`bdh up`); `ALTER SYSTEM` diverge do perfil:

```bash
sed -i 's/^PG_MAX_WAL_SIZE=.*/PG_MAX_WAL_SIZE=8GB/' .env
docker exec <container> sed -i 's/^max_wal_size = .*/max_wal_size = 8GB/' \
  /etc/postgresql/postgresql.conf
docker exec <container> psql -U postgres -Atc 'select pg_reload_conf()'
```

Mantenha `PG_MIN_WAL_SIZE` bem abaixo do máximo. Custo: mais checkpoints
forçados — acompanhe `num_requested` em `pg_stat_checkpointer` e o alerta
`CheckpointsForcadosDemais`.

### Geração N−1 no volume

Libera ~91 GB (ou 141 GB sem poda) no NVMe:

```sql
CREATE TABLESPACE arquivo LOCATION '/mnt/bdh-backup/pgdata_n1';
ALTER TABLE <tabela> SET TABLESPACE arquivo;
```

141 GB a ~300 MB/s ≈ 8 min/passagem; tabela bloqueada no `ALTER` — faça na
janela da carga, geração fora do `search_path`.

Capacidade no pico (2 fulls ~100 GB + insumos ~8 GB + N−1 141 GB) = 249 GB
(72 % de 344 GB). Cabe sem depender da poda.

## Expandir armazenamento

`ccx33` não amplia só o disco — exige upgrade de instância. Volume é
redimensionável **online**:

```bash
hcloud volume resize bdh-backup --size <GB>
resize2fs /dev/sdb   # online, volume montado
```

Até 10 TB/volume; só para cima, irreversível.

| | ccx33 (atual) | ccx43 | Volume |
|---|---|---|---|
| Recursos | 8 vCPU · 32 GB · 240 GB | 16 vCPU · 64 GB · 360 GB | — |
| Custo | € 140,99/mês | € 279,49/mês | € 0,0572/GB/mês |
| €/GB adicional | — | **€ 1,15/GB/mês** | **€ 0,057/GB/mês** |

Upgrade de instância ≈ **20×** mais caro por GB. Volume não resolve espaço de
`PGDATA` em produção — saída = poda de índices.

## Alertas

| Alerta | Limiar | Aplica a |
|---|---|---|
| `DiscoQuaseCheio` | < 15 % livres (85 % uso) | todos os mounts |
| `EspacoCriticoNoBanco` | < 15 GB livres em `/` | disco do `PGDATA` |
| `DiscoEncheEm24h` | previsão 24 h **e** < 30 % livres | todos |

`EspacoCriticoNoBanco` = piso absoluto (15 GB). Guarda de 30 % em
`DiscoEncheEm24h`: `predict_linear` é dominada por escrita em degrau (backup
full); sem ela, full de 47 GB com 79 % livres projetou −119 GB.

Se `archive_command` falhar, WAL cresce sem teto (ignora `max_wal_size`). Quem
pega: `ArquivamentoDeWalFalhando`, não os alertas de disco.

## Verificação

```bash
df -h / /mnt/bdh-backup

docker exec postgres-postgres-1 psql -U postgres -d dados_cnpj -c "
  SELECT pg_size_pretty(pg_database_size('dados_cnpj')) AS banco"

docker exec postgres-postgres-1 sh -c 'du -sh $PGDATA/pg_wal'

docker exec postgres-postgres-1 psql -U postgres -d dados_cnpj -c "
  SELECT pg_postmaster_start_time(), now() - pg_postmaster_start_time() AS uptime"
```

`idx_scan` zera no restart — "índice sem uso" só vale com uptime representativo.
