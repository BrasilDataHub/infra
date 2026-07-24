# Backup da instância dedicada — pgBackRest + PITR

> **Escopo.** Esta estratégia vale para a instância **dedicada** (cenários
> 2 e 3 do README do postgres), depois da migração (F7–F9). A instância
> atual usa o paliativo da F1: snapshot Hetzner + `pg_dump` diário agendado
> pelo Dokploy para Object Storage.
>
> **Pré-condição:** tabelas LOGGED (AG8/F6). Backup físico não protege
> tabelas UNLOGGED — elas são truncadas no restore de qualquer forma.

## Arquitetura

- **Ferramenta:** [pgBackRest](https://pgbackrest.org/) — backup físico
  incremental + WAL archiving → **PITR** (restauração a qualquer ponto no
  tempo, não só ao momento do último dump).
- **Destino:** Hetzner Object Storage (S3-compatível), bucket dedicado
  `baseempresarial-pgbackrest` (~€5/mês).
- **Execução:** container sidecar no mesmo host do Postgres, compartilhando
  o PGDATA (`/data/pgdata`) e o socket.

## Configuração (modelo)

`/etc/pgbackrest/pgbackrest.conf` no host (ou montado no sidecar):

```ini
[global]
repo1-type=s3
repo1-s3-endpoint=fsn1.your-objectstorage.com
repo1-s3-bucket=baseempresarial-pgbackrest
repo1-s3-region=fsn1
repo1-s3-key=<ACCESS_KEY>
repo1-s3-key-secret=<SECRET_KEY>
repo1-path=/dados-cnpj
repo1-retention-full=2
repo1-retention-diff=7
compress-type=zst
process-max=4
start-fast=y

[dados-cnpj]
pg1-path=/data/pgdata
pg1-port=5432
pg1-socket-path=/var/run/postgresql
```

No deploy da instância dedicada, definir as envs de archiving da imagem:

```env
PG_ARCHIVE_MODE=on
PG_ARCHIVE_COMMAND=pgbackrest --stanza=dados-cnpj archive-push %p
```

(mudar `archive_mode` exige restart do Postgres; fazer junto com a primeira
implantação — F7).

## Rotina

```bash
# Uma vez, após subir a instância:
pgbackrest --stanza=dados-cnpj stanza-create
pgbackrest --stanza=dados-cnpj check

# Agendado (cron do host):
# full semanal (domingo 03:00 BRT), diff diário (03:00 BRT)
0 6 * * 0  pgbackrest --stanza=dados-cnpj --type=full backup
0 6 * * 1-6 pgbackrest --stanza=dados-cnpj --type=diff backup
```

Com WAL archiving contínuo, o ponto de perda máxima (RPO) é o intervalo de
archive de um segmento de WAL (segundos a poucos minutos), não 24 h.

## Restore (testar antes de precisar — backup não testado não é backup)

```bash
# Restauração completa numa máquina/diretório limpo:
pgbackrest --stanza=dados-cnpj --pg1-path=/data/pgdata-restore restore

# PITR (ex.: logo antes de um incidente):
pgbackrest --stanza=dados-cnpj --pg1-path=/data/pgdata-restore \
    --type=time --target="2026-08-01 03:00:00-03" restore
```

Depois do restore: subir o Postgres apontando para o diretório restaurado e
validar contagem de linhas de ao menos uma tabela grande
(`SELECT count(*) FROM estabelecimento;` ≈ 72,3 M no mês de referência).

**Teste de restore trimestral** (mínimo): executar o fluxo acima num
servidor temporário e registrar o resultado.

## Alternativa avaliada

`wal-g` cobre o mesmo caso (backup físico + WAL para S3); pgBackRest foi
escolhido por retenção declarativa, `--type=diff` e verificação embutida
(`check`). Não há lock-in: os dois leem o mesmo PGDATA.
