# Backup da instância — pgBackRest + PITR

> **Escopo.** Vale para qualquer instância do catálogo de
> [perfis](../docs/perfis.md) — todas assumem máquina dedicada com NVMe local
> para o PGDATA e o repositório de backup em object storage.
>
> **Pré-condição:** tabelas LOGGED. Backup físico não protege tabelas
> UNLOGGED — elas são truncadas no restore de qualquer forma.

## Arquitetura

- **Ferramenta:** [pgBackRest](https://pgbackrest.org/) — backup físico
  incremental + WAL archiving → **PITR** (restauração a qualquer ponto no
  tempo, não só ao momento do último dump).
- **Destino:** object storage S3-compatível (`repo1-type=s3`), um bucket por
  projeto (ex.: `baseempresarial-pgbackrest` na Hetzner, ~€5/mês), **ou** um
  diretório local em volume de bloco (`repo1-type=posix`) — ver
  [Repositório local](#repositório-local-posix).
- **Execução:** container sidecar no mesmo host do Postgres, montando o **volume
  de dados** (`bdh_pg_data`) e o socket.

### Repositório local (posix)

Alternativa ao object storage, para quando o dado é **reconstruível** e o que se
quer do backup é RTO, não sobrevivência a desastre.

| | s3 | posix |
|---|---|---|
| sobrevive à perda do host/projeto | **sim** | não |
| velocidade de restore | rede | disco local |
| custo | por GB/mês | zero (volume já pago) |
| credencial no `pgbackrest.conf` | sim | nenhuma |

Os dois coexistem: `repo1` local para restaurar rápido, `repo2` em S3 para
sobreviver. Recomendado sempre que o dado **não** for reproduzível.

**O que muda na instalação:**

1. `pgbackrest.conf.local.example` no lugar de `pgbackrest.conf.example`;
2. o overlay [`../docker-compose.backup-local.yml`](../docker-compose.backup-local.yml),
   **depois** de `docker-compose.backup.yml`;
3. `BDH_BACKUP_REPO_DIR` no `.env`, apontando para o diretório no volume.

```bash
install -d -o 999 -g 999 -m 0750 /mnt/<volume>/pgbackrest
echo 'BDH_BACKUP_REPO_DIR=/mnt/<volume>/pgbackrest' >> .env
```

**Por que o overlay monta o repositório nos DOIS containers.** Quem executa
`archive-push` é o servidor Postgres, não o sidecar (ver
[O binário vive nos DOIS lados](#o-binário-vive-nos-dois-lados)). Com `s3` isso
não aparece — os dois falam com o bucket pela rede. Com `posix`, montar só no
sidecar produz a falha mais cara possível: o `backup` funciona, o `info` reporta
sucesso, e **todo** segmento de WAL falha ao ser arquivado, até o `pg_wal` encher
o mesmo NVMe do PGDATA.

**Duas armadilhas verificadas em 31/07/2026, ambas custam um loop de restart:**

- **Comentário é `#`, nunca `;`.** Um `;` no início da linha não é comentário
  para o pgBackRest: o parser o lê como par chave/valor fora de seção e aborta
  com `key/value found outside of section at line 1`. Os modelos deste diretório
  já usam `#`.
- **Não use o prefixo `PGBACKREST_` para variáveis que não sejam opções dele.**
  O pgBackRest lê o ambiente e mapeia `PGBACKREST_FOO` para a opção `foo`; uma
  variável só de compose chamada `PGBACKREST_REPO_DIR` vira a opção inexistente
  `repo-dir` e ele avisa `environment contains invalid option`. É por isso que a
  variável do overlay se chama `BDH_BACKUP_REPO_DIR`.

### O binário vive nos DOIS lados

Quem executa o `archive_command` é o **servidor Postgres**, como subprocesso do
postmaster — não o sidecar. Por isso o `pgbackrest` está instalado também na
imagem do banco (`../Dockerfile`). Sem ele, `PG_ARCHIVE_MODE=on` faz o comando
falhar a cada segmento, o `pg_wal` cresce sem teto e o banco cai com o disco
cheio.

| Componente | Papel |
|---|---|
| imagem `postgres` | `archive-push` de cada segmento de WAL |
| sidecar `pgbackrest` | `stanza-create`, `check`, `backup`, `restore`, agendamento, métricas |
| `/etc/pgbackrest/pgbackrest.conf` no host | **o mesmo arquivo** montado read-only nos dois |

## Arquivos deste diretório

| Arquivo | O que é |
|---|---|
| `Dockerfile` | imagem do sidecar (`ghcr.io/brasildatahub/pgbackrest:17`) |
| `entrypoint.sh` | valida, espera o banco, cria a stanza, agenda e entrega o PID 1 ao `cron` |
| `backup-run.sh` | executa `full`/`diff`/`incr`/`check` e publica métricas Prometheus |
| `restore-test.sh` | restaura num caminho separado, dentro do sidecar |
| `restore-drill.sh` | **ensaio completo no host**: restore + Postgres temporário + contagem + RTO |
| `pgbackrest.conf.example` | modelo do arquivo de configuração do host |
| `test/backup.test.sh` | teste de integração de ponta a ponta (sem S3, repo `posix`) |

O compose está em [`../docker-compose.backup.yml`](../docker-compose.backup.yml).

## Instalação — a ordem não é negociável

### 1. Configuração no host

```bash
install -d -m 0750 /etc/pgbackrest
# object storage:
cp pgbackrest.conf.example /etc/pgbackrest/pgbackrest.conf
# ou repositório local:
# cp pgbackrest.conf.local.example /etc/pgbackrest/pgbackrest.conf
$EDITOR /etc/pgbackrest/pgbackrest.conf     # preencher as chaves do bucket
chown -R 999:999 /etc/pgbackrest            # uid/gid do postgres na imagem
chmod 0640 /etc/pgbackrest/pgbackrest.conf

install -d -o 999 -g 999 -m 0755 /var/lib/node_exporter/textfile
```

As credenciais ficam **só** nesse arquivo: nenhum `.env`, nenhum `docker
inspect`, nenhum commit.

> **`checksum-page` e clusters sem checksums.** Se o `initdb` correu sem
> `--data-checksums`, o pgBackRest avisa no primeiro backup —
> `checksum-page option set to true but checksums are not enabled on the
> cluster, resetting to false` — e segue sem detecção de corrupção de página.
> O backup é válido; o que se perde é o alarme precoce de corrupção silenciosa
> de disco. Ligar depois exige `pg_checksums` com o **cluster parado**, e em
> 137 GB isso é uma janela real de indisponibilidade: planeje junto da carga
> mensal. Verifique com
> `SELECT current_setting('data_checksums')`.

### 2. O alerta ANTES do `archive_mode`

`archive_mode = on` com um `archive_command` que falha faz o Postgres **reter**
todo segmento não arquivado. O `pg_wal` cresce, o filesystem enche, o banco
para — e o intervalo entre "quebrou" e "caiu" é só o espaço livre dividido pela
taxa de WAL.

Por isso `ArquivamentoDeWalParado`
([`../../monitoring/prometheus/rules/backup.rules.yml`](../../monitoring/prometheus/rules/backup.rules.yml))
tem de estar **coletando e notificando** antes do passo 3. Confira que a série
existe:

```bash
curl -s localhost:9090/api/v1/query --data-urlencode \
  'query=pg_stat_archiver_last_archive_age' | jq '.data.result'
```

> O nome da métrica é `pg_stat_archiver_last_archive_age` (postgres_exporter
> v0.20.1). O roadmap 20 a chama de `..._last_archived_age`; o nome correto é
> este.

### 3. Subir

```bash
docker compose -f docker-compose.yml -f docker-compose.metrics.yml \
               -f docker-compose.backup.yml up -d
```

**Este overlay RECRIA o container do Postgres** — ao contrário do de métricas,
que foi desenhado para não recriar. Não há alternativa: `archive_mode` é
parâmetro de postmaster e exige restart. O restart é planejado uma vez e nele
entram as três mudanças de uma vez (`archive_mode`, `archive_command`,
`archive_timeout`).

O `entrypoint.sh` faz `stanza-create` e `check` sozinho no primeiro start; o
`check` força uma troca de segmento e confirma que ele chegou ao repositório.
Se o log do sidecar chegar em `agendado: ...`, o arquivamento está de pé.

### 4. Primeiro backup completo

```bash
docker exec -u postgres <sidecar> /usr/local/bin/pgbackrest-backup-run.sh full
```

### 5. Ensaio de restauração — sem isto, não há backup

```bash
bash postgres/backup/restore-drill.sh \
    --stanza dados-cnpj --db dados_cnpj \
    --tabela estabelecimento --esperado 72318968
```

O script cria `bdh_pg_restore` (volume **separado**), restaura, sobe um Postgres
temporário em `127.0.0.1:15499`, espera o recovery, conta a tabela e imprime o
**RTO medido**. É esse número que vai para o registro de execução — RTO
estimado só é conferido durante o incidente.

Três travas impedem que o ensaio toque produção: recusa de volume igual ao de
produção, recusa de porta ocupada e recusa de restaurar sobre o `pg1-path` da
stanza.

> ⚠️ **Com repositório `posix`, o ensaio precisa de `EXTRA_MOUNTS`.** Os
> containers que ele cria são **novos**: eles não herdam o mount que o
> [`docker-compose.backup-local.yml`](../docker-compose.backup-local.yml) deu ao
> Postgres e ao sidecar. A origem é o `BDH_BACKUP_REPO_DIR` do `.env`, e o
> destino é o `repo1-path` do `pgbackrest.conf`:
>
> ```bash
> EXTRA_MOUNTS="-v /mnt/bdh-backup/pgbackrest:/var/lib/pgbackrest" \
>   bash postgres/backup/restore-drill.sh --stanza dados-cnpj --db dados_cnpj \
>       --tabela estabelecimento --esperado 72318968
> ```
>
> Sem isso o pgBackRest abre um `/var/lib/pgbackrest` vazio e responde
> `ERROR: [075]: no backup set found to restore`, com o hint
> `has a stanza-create been performed?` — uma mensagem que manda procurar um
> backup ausente quando o backup existe e íntegro, e o que falta é o mount.
> Desde 07/2026 o script **recusa começar** nesse caso, dizendo isso. Com
> `repo1-type=s3` nada disso se aplica: o repositório é um endpoint.
>
> O volume `bdh_pg_restore` **não é removido** no fim (só o container é), e ele
> tem o tamanho do PGDATA restaurado. Apague-o quando terminar de inspecionar:
> `docker volume rm bdh_pg_restore`.

> **Detalhe que já quebrou o ensaio uma vez:** o `restore` grava em
> `postgresql.auto.conf` um `restore_command` com o `--pg1-path` usado na
> restauração. O cluster restaurado precisa ser iniciado com o PGDATA **no
> mesmo caminho** — o `restore-drill.sh` faz isso passando `PGDATA=/restore`.

## Rotina

O agendamento vive **dentro do sidecar** (`/etc/cron.d/pgbackrest`, escrito no
start a partir das envs) e não no cron do host: assim ele é versionado, sobe
junto com o serviço e não se perde numa reinstalação do host.

| Env | Default (UTC) | Equivalente BRT |
|---|---|---|
| `BDH_BACKUP_FULL_SCHEDULE` | `0 6 * * 0` | domingo 03:00 |
| `BDH_BACKUP_DIFF_SCHEDULE` | `0 6 * * 1-6` | demais dias 03:00 |
| `BDH_BACKUP_CHECK_SCHEDULE` | `0 */6 * * *` | a cada 6 h |

**Nome das envs.** Só `PGBACKREST_STANZA` usa o prefixo do produto. O pgBackRest
lê qualquer `PGBACKREST_<OPCAO>` como opção e, quando ela não existe, imprime um
aviso **no stdout** — que corrompe a saída de `info --output=json`. Todo o resto
usa `BDH_BACKUP_*`.

Com WAL archiving contínuo e `archive_timeout=60s`, o RPO é de **até 60
segundos**, não de 24 h.

## Métricas e alertas

O `backup-run.sh` escreve `/var/lib/node_exporter/textfile/pgbackrest.prom`, lido
pelo textfile collector do `node_exporter`:

| Métrica | Para quê |
|---|---|
| `pgbackrest_info_ok` | o repositório responde |
| `pgbackrest_repo_status_code` | 0 = ok |
| `pgbackrest_backup_count{type}` | **0 em `full` = não existe backup** |
| `pgbackrest_backup_last_completion_timestamp_seconds{type}` | idade do último backup |
| `pgbackrest_backup_last_{duration_seconds,size_bytes,repo_size_bytes}{type}` | custo e tendência |
| `pgbackrest_archive_segments_present` | 0 com full presente = backup **sem PITR** |
| `pgbackrest_run_last_success{type}` | a execução agendada rodou e deu erro |

As duas fontes são independentes de propósito: `pg_stat_archiver_*` é o que o
**banco** acha do arquivamento; `pgbackrest_*` é o que existe **de fato** no
repositório. Um repositório apagado por fora não move nenhuma série da primeira.

## Restore manual

```bash
docker volume create bdh_pg_restore

# completo:
docker run --rm --entrypoint /usr/local/bin/pgbackrest-restore-test.sh \
  -e PGBACKREST_STANZA=dados-cnpj \
  -v bdh_pg_restore:/restore -v /etc/pgbackrest:/etc/pgbackrest:ro \
  ghcr.io/brasildatahub/pgbackrest:17

# PITR, logo antes de um incidente:
docker run --rm --entrypoint /usr/local/bin/pgbackrest-restore-test.sh \
  -e PGBACKREST_STANZA=dados-cnpj \
  -v bdh_pg_restore:/restore -v /etc/pgbackrest:/etc/pgbackrest:ro \
  ghcr.io/brasildatahub/pgbackrest:17 \
  --type=time --target="2026-08-01 03:00:00-03"
```

Ou, com tudo junto e medido, `restore-drill.sh --tipo time --alvo "..."`.

**Teste de restore trimestral, no mínimo.** O `restore-drill.sh` é o
procedimento; o RTO medido é o entregável.

## Convivência com o resto do host

`process-max` e a compressão `zst` disputam CPU com o Postgres e, se houver, com
Redis e Meilisearch no mesmo host (ver
[coexistência](../docs/perfis.md#coexistência-com-outros-serviços-no-mesmo-host)).
O NVMe também é único: o full semanal está agendado fora da janela de
reindexação e da carga mensal.

## Testes

```bash
bash postgres/backup/test/backup.test.sh
```

Sobe banco + sidecar de verdade, com repositório `posix` num volume local, e
percorre o ciclo inteiro: `archive_command` → stanza → full → escrita nova →
diff → restore → contagem. Cada peça é trivial isolada; o que quebra é a junção
(uid do volume, socket compartilhado, binário ausente na imagem do banco,
`/etc/cron.d` sem nova linha no fim). Um teste que não sobe os containers não
pega nenhum desses.

## Alternativa avaliada

`wal-g` cobre o mesmo caso (backup físico + WAL para S3); pgBackRest foi
escolhido por retenção declarativa, `--type=diff` e verificação embutida
(`check`). Não há lock-in: os dois leem o mesmo PGDATA.
