# Armazenamento

Onde cada coisa fica, quanto ocupa e como acomodar o pico do ciclo mensal.

## Layout

O `bdh-data` tem dois dispositivos, com papéis que não se misturam.

| Dispositivo | Tamanho | Montagem | Conteúdo |
|---|---|---|---|
| `sda1` — NVMe local | 226 GB | `/` | `PGDATA`, `pg_wal`, imagens e volumes Docker |
| `sdb` — Hetzner Volume | 344 GB | `/mnt/bdh-backup` | repositório do pgBackRest, insumos da carga, geração N−1 |

**O `PGDATA` fica no NVMe local. Sempre.** O volume de rede não serve para dados
quentes — a diferença de desempenho está medida abaixo.

## Desempenho dos dois dispositivos

Medido com `fio` em 31/07/2026, `--direct=1`, `iodepth=32`, 20 s por teste:

| Teste | NVMe local | Hetzner Volume | Razão |
|---|---|---|---|
| leitura sequencial 1M | 14.893 MB/s | 301 MB/s | 49× |
| escrita sequencial 1M | 10.459 MB/s | 301 MB/s | 35× |
| leitura aleatória 8K | **133.664 IOPS** | **7.537 IOPS** | **17,7×** |
| escrita aleatória 8K | **121.169 IOPS** | **7.536 IOPS** | **16,1×** |
| latência p95 (rand read) | 0,31 ms | 4,49 ms | 14,5× |

O bloco de 8K é o tamanho de página do PostgreSQL, então a linha de leitura
aleatória é a que decide: **o volume entrega 6 % dos IOPS do NVMe**. Com
`shared_buffers` de 10 GB para um banco de 141 GB e `cache_hit` em torno de 83 %,
uma parte relevante das leituras vai ao disco — e nessas o volume custaria 14×
mais latência.

O volume satura em ~300 MB/s de throughput e ~7.500 IOPS. Isso é suficiente para
escrita sequencial (backup, carga) e insuficiente para leitura aleatória
(consulta).

### Para que o volume serve

| Uso | Serve? | Por quê |
|---|---|---|
| Repositório de backup | **sim** | escrita sequencial; o full de 137 GB levou 3 min 44 s |
| Insumos da carga (downloads, logs) | **sim** | leitura sequencial, uma vez por mês |
| Geração N−1 após a publicação | **sim** | não recebe leitura; existe como rollback |
| `PGDATA` da geração em produção | **não** | 17× menos IOPS |
| Construção de uma geração nova | **caso a caso** | a carga é escrita sequencial, mas a criação de índices faz leitura aleatória pesada |

## Quanto ocupa

Medido em 31/07/2026, uma geração:

| Item | Tamanho |
|---|---|
| Banco `dados_cnpj` | **141 GB** |
| ├ heap | 50 GB |
| └ índices | 90 GB |
| `pg_wal` | 29 GB |
| **Total no `sda1`** | **173 GB de 226 GB (81 %)** |
| Repositório de backup | 56 GB de 344 GB (17 %) |

As seis maiores relações concentram quase tudo:

| Tabela | Total | Heap | Índices |
|---|---|---|---|
| `estabelecimento` | 51 GB | 15 GB | 36 GB |
| `busca_estabelecimento` | 35 GB | 15 GB | 20 GB |
| `empresa` | 23 GB | 6,1 GB | 17 GB |
| `estabelecimento_cnae_sec` | 18 GB | 8,0 GB | 10 GB |
| `simples` | 6,9 GB | 2,6 GB | 4,3 GB |
| `socio` | 5,9 GB | 3,1 GB | 2,8 GB |

**Índices são 64 % do banco.** É onde está a folga: ~50 GB deles não registram
uso. Ver [`index_cleanup`](https://github.com/BrasilDataHub/baseempresarial-services)
no pipeline.

O crescimento entre cargas é pequeno — a base da RFB é incremental, e o mês
acrescenta empresas novas sem mudar a ordem de grandeza. **O problema de
armazenamento não é o crescimento: é o pico do ciclo mensal.**

## O pico do ciclo mensal

O ciclo blue/green carrega a geração nova enquanto a anterior continua servindo.
Durante a carga, **duas gerações coexistem no NVMe** — e é aí que o espaço aperta.

```
                     ┌── geração N   (servindo)      141 GB
sda1 · 226 GB   ─────┤── geração N+1 (carregando)    141 GB
                     └── pg_wal                       29 GB
                                                     ─────
                                                     311 GB   ✗ não cabe
```

**O volume não resolve este pico.** A geração em construção recebe criação de
índices, que é leitura aleatória pesada — o perfil que o volume atende mal. O
volume resolve o momento **seguinte**: guardar a geração N−1 depois da
publicação, liberando o NVMe para o ciclo seguinte.

### Cenários — durante a construção

| Cenário | `sda1` | Uso | Cabe? |
|---|---|---|---|
| Fora do ciclo, uma geração | 170 GB | 75 % | sim |
| Ciclo, sem poda de índices | 311 GB | — | **não — faltam 85 GB** |
| Ciclo, com poda (−50 GB por geração) | 211 GB | 93 % | apertado |
| Ciclo, com poda + `max_wal_size=8GB` | 190 GB | 84 % | **sim** |

**A poda de índices é pré-requisito do ciclo mensal.** Sem ela, nenhum cenário de
construção fecha no NVMe, e o volume não substitui o disco local para essa etapa.

### Depois de publicar

Publicada a geração nova, a anterior vira rollback e para de receber leitura —
o perfil que o volume atende bem. Movê-la para lá devolve o NVMe ao patamar de
uma geração só:

```
sda1 · 226 GB    geração corrente + pg_wal      99–170 GB   (44–75 %)
sdb  · 344 GB    backup + insumos + N−1        ~249 GB      (72 %)
```

É isto que o volume de 344 GB garante: **espaço para manter o N−1 sem apertar o
disco do banco**, em vez de precisar dropá-lo assim que a nova geração sobe.

### `max_wal_size` durante a carga

`max_wal_size` é `sighup` — muda com `SELECT pg_reload_conf()`, sem restart.

Reduzir para 8 GB durante a janela libera até 24 GB. O custo é mais checkpoints
durante a carga, que é justamente quando a escrita é mais pesada. Use quando a
folga for necessária, e devolva o valor ao fim:

```sql
ALTER SYSTEM SET max_wal_size = '8GB';
SELECT pg_reload_conf();
-- ao fim da carga
ALTER SYSTEM RESET max_wal_size;
SELECT pg_reload_conf();
```

Acompanhe `CheckpointsForcadosDemais` enquanto estiver reduzido.

### Geração N−1 no volume

Depois de publicar, a geração anterior existe só como rollback e não recebe
leitura — o perfil que o volume atende bem. Movê-la para lá libera ~91 GB (ou
141 GB sem poda) no NVMe.

Requer um tablespace no volume:

```sql
CREATE TABLESPACE arquivo LOCATION '/mnt/bdh-backup/pgdata_n1';
ALTER TABLE <tabela> SET TABLESPACE arquivo;
```

Mover 141 GB a ~300 MB/s leva cerca de 8 minutos por passagem, e a tabela fica
bloqueada durante o `ALTER` — faça na janela da carga, com a geração já fora do
`search_path`.

**Capacidade:** o volume tem 344 GB. No pico — dois fulls durante a geração
(~100 GB), insumos da carga (~8 GB) e a geração N−1 completa (141 GB) — são
249 GB, ou 72 %. Cabe sem depender da poda de índices.

## Expandir armazenamento

O `ccx33` não permite ampliar só o disco — a Hetzner exige upgrade da instância
inteira, e 8 vCPU / 32 GB já atendem a carga. Upgrade permanente para resolver um
pico mensal não se paga.

**A alternativa é o volume**, que é redimensionável **online** e cobrado por
GB/mês:

```bash
hcloud volume resize bdh-backup --size <GB>
# depois, no servidor:
resize2fs /dev/sdb
```

Depois do `resize`, o filesystem precisa acompanhar — o `resize2fs` roda **online**,
com o volume montado e o backup no ar.

Limites: até 10 TB por volume; o redimensionamento é **só para cima e não pode ser
revertido**.

### Por que não expandir o disco local

O disco local é atributo do *server type*: não há comando para ampliá-lo
isoladamente, só `hcloud server change-type`, que troca CPU, RAM e disco em
bloco.

| | ccx33 (atual) | ccx43 | Volume |
|---|---|---|---|
| Recursos | 8 vCPU · 32 GB · 240 GB | 16 vCPU · 64 GB · 360 GB | — |
| Custo | € 140,99/mês | € 279,49/mês | € 0,0572/GB/mês |
| Custo por GB adicional | — | **€ 1,15/GB/mês** | **€ 0,057/GB/mês** |

O upgrade de instância custa **20× mais por GB** e vem com CPU e RAM que a carga
não pede. O volume é a via de expansão sempre que o dado couber no perfil de I/O
dele.

**O que o volume não resolve:** espaço para o `PGDATA` em produção. Para isso, as
saídas são a poda de índices e o ajuste temporário de `max_wal_size`.

## Alertas

| Alerta | Limiar | Aplica a |
|---|---|---|
| `DiscoQuaseCheio` | < 15 % livres (dispara a 85 % de uso) | todos os pontos de montagem |
| `EspacoCriticoNoBanco` | < 15 GB livres em `/` | disco do `PGDATA` |
| `DiscoEncheEm24h` | previsão de encher em 24 h **e** menos de 30 % livres | todos |

Porcentagem e espaço absoluto respondem a perguntas diferentes, e a porcentagem
reage mais tarde quanto maior o disco. `EspacoCriticoNoBanco` garante um piso que
não depende do tamanho do dispositivo: 15 GB não comportam um checkpoint grande
nem o crescimento de `pg_wal`.

A guarda de 30 % em `DiscoEncheEm24h` existe porque `predict_linear` é regressão
linear, e uma escrita em **degrau** a domina. Um backup full escreve dezenas de
GB de uma vez; sem a guarda, a regressão lê isso como tendência e projeta o disco
enchendo mesmo com o volume quase vazio — medido: um full de 47 GB num volume com
79 % livres produziu previsão de −119 GB.

Com a geração N−1 no volume, o disco local acomoda só a geração corrente mais o
`pg_wal`, e o ciclo mensal não leva `/` acima de 85 %.

### O risco que nenhum limiar cobre

Se o `archive_command` falhar, o WAL **para de ser reciclado** e cresce sem teto,
ignorando `max_wal_size`. Com 44 GB livres isso derruba o banco em menos de um
dia. Quem pega esse caso é `ArquivamentoDeWalFalhando`, não os alertas de disco —
o disco só acusa quando já é tarde.

## Verificação

```bash
# ocupação dos dois dispositivos
df -h / /mnt/bdh-backup

# banco, heap e índices
docker exec postgres-postgres-1 psql -U postgres -d dados_cnpj -c "
  SELECT pg_size_pretty(pg_database_size('dados_cnpj')) AS banco"

# pg_wal
docker exec postgres-postgres-1 sh -c 'du -sh $PGDATA/pg_wal'

# índices sem uso registrado — confira o uptime antes de concluir
docker exec postgres-postgres-1 psql -U postgres -d dados_cnpj -c "
  SELECT pg_postmaster_start_time(), now() - pg_postmaster_start_time() AS uptime"
```

`idx_scan` é zerado quando o cluster reinicia. Uma leitura de "índice sem uso"
só vale se o uptime cobrir um ciclo de uso representativo.
