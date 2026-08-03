# Backup da instância — pgBackRest + PITR

## Papel

Backup físico incremental e WAL archiving via [pgBackRest](https://pgbackrest.org/), com PITR. Cobre qualquer perfil em [docs/perfis.md](../docs/perfis.md) (NVMe local para PGDATA; repositório em object storage ou volume local).

Pré-condição: tabelas **LOGGED**. Backup físico não protege UNLOGGED (truncadas no restore).

## Componentes / imagem

| Componente | Papel |
|---|---|
| imagem `postgres` | `archive-push` de cada segmento de WAL (`pgbackrest` na imagem do banco) |
| sidecar `ghcr.io/brasildatahub/pgbackrest:17` | `stanza-create`, `check`, `backup`, `restore`, cron, métricas |
| `/etc/pgbackrest/pgbackrest.conf` no host | mesmo arquivo, read-only, nos dois containers |

| Arquivo | Função |
|---|---|
| `Dockerfile` | imagem do sidecar |
| `entrypoint.sh` | valida, espera banco, stanza, agenda, PID 1 = cron |
| `backup-run.sh` | `full`/`diff`/`incr`/`check` + métricas Prometheus |
| `restore-test.sh` | restore em caminho separado no sidecar |
| `restore-drill.sh` | ensaio no host: restore + Postgres temp + contagem + RTO |
| `pgbackrest.conf.example` | modelo S3 |
| `pgbackrest.conf.local.example` | modelo posix |
| `test/backup.test.sh` | integração e2e (repo posix) |

Compose: [`../docker-compose.backup.yml`](../docker-compose.backup.yml). Overlay local: [`../docker-compose.backup-local.yml`](../docker-compose.backup-local.yml).

| | s3 | posix |
|---|---|---|
| sobrevive à perda do host | sim | não |
| velocidade de restore | rede | disco local |
| custo | por GB/mês | volume já pago |
| credencial no conf | sim | nenhuma |

Os dois coexistem (`repo1` local + `repo2` S3) quando o dado não é reproduzível.

## Perfis e configuração

Agendamento no sidecar (`/etc/cron.d/pgbackrest`, a partir das envs):

| Env | Default (UTC) | Equivalente BRT |
|---|---|---|
| `BDH_BACKUP_FULL_SCHEDULE` | `0 6 * * 0` | domingo 03:00 |
| `BDH_BACKUP_DIFF_SCHEDULE` | `0 6 * * 1-6` | demais dias 03:00 |
| `BDH_BACKUP_CHECK_SCHEDULE` | `0 */6 * * *` | a cada 6 h |

Com WAL contínuo e `archive_timeout=60s`, RPO ≤ **60 s**.

Só `PGBACKREST_STANZA` usa prefixo do produto. Demais envs: `BDH_BACKUP_*` (pgBackRest mapeia `PGBACKREST_*` para opções; inválidas corrompem `info --output=json`).

Comentários no conf: `#` apenas (`;` não é comentário). Overlay posix: variável `BDH_BACKUP_REPO_DIR` (não `PGBACKREST_*`).

## Deploy / operação

### 1. Configuração no host

```bash
install -d -m 0750 /etc/pgbackrest
cp pgbackrest.conf.example /etc/pgbackrest/pgbackrest.conf
# ou: cp pgbackrest.conf.local.example /etc/pgbackrest/pgbackrest.conf
$EDITOR /etc/pgbackrest/pgbackrest.conf
chown -R 999:999 /etc/pgbackrest
chmod 0640 /etc/pgbackrest/pgbackrest.conf

install -d -o 999 -g 999 -m 0755 /var/lib/node_exporter/textfile
```

Credenciais só no conf (não em `.env` / inspect / git).

Repo posix:

```bash
install -d -o 999 -g 999 -m 0750 /mnt/<volume>/pgbackrest
echo 'BDH_BACKUP_REPO_DIR=/mnt/<volume>/pgbackrest' >> .env
```

Overlay `docker-compose.backup-local.yml` monta o repo nos **dois** containers (Postgres faz `archive-push`).

Se `initdb` sem `--data-checksums`: pgBackRest desliga `checksum-page` com aviso. Ligar depois: `pg_checksums` com cluster parado. Verificar: `SELECT current_setting('data_checksums')`.

### 2. Alerta antes de `archive_mode`

Com `archive_mode=on` e `archive_command` falhando, Postgres retém WAL até encher o disco. Confirmar série antes do passo 3:

```bash
curl -s localhost:9090/api/v1/query --data-urlencode \
  'query=pg_stat_archiver_last_archive_age' | jq '.data.result'
```

Métrica: `pg_stat_archiver_last_archive_age` (postgres_exporter v0.20.1). Regra: [`../../monitoring/prometheus/rules/backup.rules.yml`](../../monitoring/prometheus/rules/backup.rules.yml).

### 3. Subir

```bash
docker compose -f docker-compose.yml -f docker-compose.metrics.yml \
               -f docker-compose.backup.yml up -d
```

Overlay **recria** o Postgres (`archive_mode` exige restart). Entrypoint faz `stanza-create` + `check`; log `agendado: ...` confirma arquivamento.

### 4. Primeiro full

```bash
docker exec -u postgres <sidecar> /usr/local/bin/pgbackrest-backup-run.sh full
```

### 5. Ensaio de restauração

```bash
bash postgres/backup/restore-drill.sh \
    --stanza dados-cnpj --db dados_cnpj \
    --tabela estabelecimento --esperado 72318968
```

Cria `bdh_pg_restore`, sobe Postgres em `127.0.0.1:15499`, conta tabela, imprime RTO. Travas: volume ≠ produção, porta livre, não restaura sobre `pg1-path` da stanza.

Repo posix — montar o repositório nos containers do ensaio:

```bash
EXTRA_MOUNTS="-v /mnt/bdh-backup/pgbackrest:/var/lib/pgbackrest" \
  bash postgres/backup/restore-drill.sh --stanza dados-cnpj --db dados_cnpj \
      --tabela estabelecimento --esperado 72318968
```

Sem mount: `ERROR: [075]: no backup set found`. Script recusa começar nesse caso. Volume `bdh_pg_restore` não é removido: `docker volume rm bdh_pg_restore`. Restore inicia com `PGDATA=/restore` (mesmo path do `--pg1-path` no `restore_command`).

### Restore manual

```bash
docker volume create bdh_pg_restore

docker run --rm --entrypoint /usr/local/bin/pgbackrest-restore-test.sh \
  -e PGBACKREST_STANZA=dados-cnpj \
  -v bdh_pg_restore:/restore -v /etc/pgbackrest:/etc/pgbackrest:ro \
  ghcr.io/brasildatahub/pgbackrest:17

# PITR:
docker run --rm --entrypoint /usr/local/bin/pgbackrest-restore-test.sh \
  -e PGBACKREST_STANZA=dados-cnpj \
  -v bdh_pg_restore:/restore -v /etc/pgbackrest:/etc/pgbackrest:ro \
  ghcr.io/brasildatahub/pgbackrest:17 \
  --type=time --target="2026-08-01 03:00:00-03"
```

Ou `restore-drill.sh --tipo time --alvo "..."`.

### Métricas

`backup-run.sh` → `/var/lib/node_exporter/textfile/pgbackrest.prom`:

| Métrica | Para quê |
|---|---|
| `pgbackrest_info_ok` | repositório responde |
| `pgbackrest_repo_status_code` | 0 = ok |
| `pgbackrest_backup_count{type}` | 0 em `full` = sem backup |
| `pgbackrest_backup_last_completion_timestamp_seconds{type}` | idade |
| `pgbackrest_backup_last_{duration_seconds,size_bytes,repo_size_bytes}{type}` | custo/tendência |
| `pgbackrest_archive_segments_present` | 0 com full = backup sem PITR |
| `pgbackrest_run_last_success{type}` | execução agendada |

`pg_stat_archiver_*` = visão do banco; `pgbackrest_*` = conteúdo real do repo.

```bash
bash postgres/backup/test/backup.test.sh
```

## Variáveis e segredos

| Variável | Descrição |
|---|---|
| Credenciais S3 | só em `/etc/pgbackrest/pgbackrest.conf` |
| `PGBACKREST_STANZA` | stanza |
| `BDH_BACKUP_*_SCHEDULE` | cron (tabela acima) |
| `BDH_BACKUP_REPO_DIR` | path do repo posix no host |
| `PG_ARCHIVE_MODE` / `PG_ARCHIVE_COMMAND` | no Postgres (via overlay de backup) |
| `EXTRA_MOUNTS` | mounts extras no `restore-drill.sh` |

## Restrições

- Sem binário `pgbackrest` na imagem do banco, `archive_mode=on` enche `pg_wal`.
- Repo posix montado só no sidecar: backup/`info` ok, WAL não arquiva.
- Full semanal fora da janela de reindexação/carga mensal (CPU + NVMe compartilhados).
- Ensaio trimestral mínimo; RTO medido é o entregável.

## Links

- [`../README.md`](../README.md)
- [docs/perfis.md](../docs/perfis.md) — coexistência
- [`../../monitoring/prometheus/rules/backup.rules.yml`](../../monitoring/prometheus/rules/backup.rules.yml)
