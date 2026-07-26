# Backup da instância dedicada — pgBackRest + PITR

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
- **Destino:** object storage S3-compatível, um bucket por projeto
  (ex.: `baseempresarial-pgbackrest` na Hetzner, ~€5/mês).
- **Execução:** container sidecar no mesmo host do Postgres, montando o **volume
  de dados** (`bdh_pg_data`) e o socket.

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
pg1-path=/var/lib/postgresql/data
pg1-port=5432
pg1-socket-path=/var/run/postgresql
```

`pg1-path` é o caminho **dentro do container** — o sidecar monta o volume de
dados ali, exatamente como o Postgres faz:

```yaml
  pgbackrest:
    image: <imagem com pgbackrest>
    volumes:
      - pg_data:/var/lib/postgresql/data
      - /etc/pgbackrest:/etc/pgbackrest:ro
      - pg_socket:/var/run/postgresql
```

Com isso a configuração não depende de nenhum caminho do host. Para snapshot ou
inspeção pelo host, o diretório real do volume sai de
`docker volume inspect bdh_pg_data -f '{{.Mountpoint}}'` — mas **copiar dali com
o banco no ar não é backup consistente**; use o pgBackRest.

No deploy da instância dedicada, definir as envs de archiving da imagem:

```env
PG_ARCHIVE_MODE=on
PG_ARCHIVE_COMMAND=pgbackrest --stanza=dados-cnpj archive-push %p
```

(mudar `archive_mode` exige restart do Postgres; fazer junto com a primeira
implantação).

**Convivência com o resto do host.** `process-max` e a compressão `zst` do
pgBackRest disputam CPU com o Postgres e, se houver, com Redis e Meilisearch no
mesmo host (ver
[coexistência](../docs/perfis.md#coexistência-com-outros-serviços-no-mesmo-host)).
O NVMe também é único: agende o full semanal fora da janela de reindexação e da
carga mensal.

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

Restaure num **volume separado** (ex.: `bdh_pg_restore`), montado no sidecar em
`/restore`, para nunca escrever sobre o volume em produção:

```bash
docker volume create bdh_pg_restore

# Restauração completa:
pgbackrest --stanza=dados-cnpj --pg1-path=/restore restore

# PITR (ex.: logo antes de um incidente):
pgbackrest --stanza=dados-cnpj --pg1-path=/restore \
    --type=time --target="2026-08-01 03:00:00-03" restore
```

Depois do restore: subir um Postgres com `bdh_pg_restore` montado em
`/var/lib/postgresql/data` e validar contagem de linhas de ao menos uma tabela
grande
(`SELECT count(*) FROM estabelecimento;` ≈ 72,3 M no mês de referência).

**Teste de restore trimestral** (mínimo): executar o fluxo acima num
servidor temporário e registrar o resultado.

## Alternativa avaliada

`wal-g` cobre o mesmo caso (backup físico + WAL para S3); pgBackRest foi
escolhido por retenção declarativa, `--type=diff` e verificação embutida
(`check`). Não há lock-in: os dois leem o mesmo PGDATA.
