#!/usr/bin/env bash
# Teste de integração do sidecar de backup — ciclo COMPLETO, de ponta a ponta:
# archive_command → stanza → full → escrita nova → diff → restore → contagem.
#
#   bash postgres/backup/test/backup.test.sh
#
# Por que integração e não unitário: cada peça deste item é trivial isolada, e o
# que quebra é a junção — o uid do volume, o socket compartilhado, o binário que
# está no sidecar mas não no banco, o /etc/cron.d sem nova linha no fim. Um teste
# que não sobe os dois containers de verdade não pega nenhum desses.
#
# O repositório do teste é `posix` num volume local, não S3: o que está sob teste
# é a mecânica do sidecar, e um bucket real transformaria o teste numa
# dependência de rede e de credencial. A diferença entre posix e s3 é uma seção
# do pgbackrest.conf.
#
# Precisa de Docker. Não toca em nada de produção: nomes, volumes e portas são
# próprios e removidos ao final.
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/../../.." && pwd)"
PREFIXO="bdhtest-backup"
REDE="${PREFIXO}-net"
VOL_DATA="${PREFIXO}-pgdata"
VOL_SOCKET="${PREFIXO}-socket"
VOL_REPO="${PREFIXO}-repo"
VOL_RESTORE="${PREFIXO}-restore"
IMG_PG="${PREFIXO}/postgres"
IMG_BK="${PREFIXO}/pgbackrest"
STANZA="teste"
DB="dados_teste"
CONF_DIR="$(mktemp -d)"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
nok() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
info(){ echo "    · $1"; }

limpar() {
    docker rm -f "${PREFIXO}-pg" "${PREFIXO}-sidecar" bdh-pg-restore-drill >/dev/null 2>&1
    docker volume rm -f "$VOL_DATA" "$VOL_SOCKET" "$VOL_REPO" "$VOL_RESTORE" >/dev/null 2>&1
    docker network rm "$REDE" >/dev/null 2>&1
    rm -rf "$CONF_DIR"
}
trap limpar EXIT
# Limpa restos de uma execução interrompida ANTES de criar o que este teste usa —
# daí o mkdir logo depois: `limpar` também apaga o CONF_DIR.
limpar
mkdir -p "$CONF_DIR"

echo
echo "Sidecar de backup (pgBackRest) — teste de integração"

# ---------------------------------------------------------------------------
# Preparação
# ---------------------------------------------------------------------------
docker build -q -t "$IMG_PG" "$RAIZ/postgres" >/dev/null || { echo "build do postgres falhou"; exit 1; }
docker build -q -t "$IMG_BK" "$RAIZ/postgres/backup" >/dev/null || { echo "build do sidecar falhou"; exit 1; }
docker network create "$REDE" >/dev/null
docker volume create "$VOL_DATA" >/dev/null
docker volume create "$VOL_SOCKET" >/dev/null
docker volume create "$VOL_REPO" >/dev/null

cat > "$CONF_DIR/pgbackrest.conf" <<EOF
[global]
repo1-type=posix
repo1-path=/repo
repo1-retention-full=2
compress-type=zst
process-max=2
start-fast=y
checksum-page=y
log-level-console=info

[${STANZA}]
pg1-path=/var/lib/postgresql/data
pg1-port=5432
pg1-socket-path=/var/run/postgresql
pg1-user=postgres
EOF
chmod 640 "$CONF_DIR/pgbackrest.conf"

# O `chown` que o README manda fazer em produção, e que este teste não fazia.
#
# O pgbackrest roda como `postgres` (uid 999) e lê a config por bind-mount do
# host. Com modo 640 e dono diferente, ele não consegue ler a PRÓPRIA
# configuração: `unable to open file '/etc/pgbackrest/pgbackrest.conf' for
# read: [13] Permission denied`.
#
# No Docker Desktop do macOS o compartilhamento de arquivos mascara a
# propriedade e isso passa despercebido; num runner Linux, onde o mapeamento de
# uid é real, o teste falha. Foi assim que o defeito ficou verde localmente e
# vermelho no CI.
#
# Só o ARQUIVO, não o diretório: o TEXTFILE_DIR é criado dentro dele mais
# adiante, e precisa continuar gravável por quem roda o teste.
if ! chown 999:999 "$CONF_DIR/pgbackrest.conf" 2>/dev/null; then
    sudo chown 999:999 "$CONF_DIR/pgbackrest.conf" 2>/dev/null || true
fi

# O binário do pgBackRest tem de existir NA IMAGEM DO BANCO: quem roda o
# archive_command é o postmaster, não o sidecar. É o erro de desenho mais fácil
# de cometer aqui, e o sintoma seria o pg_wal enchendo em produção.
if docker run --rm --entrypoint pgbackrest "$IMG_PG" version >/dev/null 2>&1; then
    ok "a imagem do Postgres tem o binário do pgBackRest (archive_command)"
else
    nok "a imagem do Postgres NÃO tem pgbackrest — o archive_command falharia a cada segmento"
fi

# ---------------------------------------------------------------------------
# Banco com arquivamento ligado
# ---------------------------------------------------------------------------
docker run -d --name "${PREFIXO}-pg" --network "$REDE" \
    -e POSTGRES_DB="$DB" -e POSTGRES_PASSWORD=teste \
    -e PG_ARCHIVE_MODE=on \
    -e PG_ARCHIVE_COMMAND="pgbackrest --stanza=${STANZA} archive-push %p" \
    -e PG_ARCHIVE_TIMEOUT=30s \
    -e PG_SHARED_BUFFERS=128MB -e PG_EFFECTIVE_CACHE_SIZE=256MB \
    -v "$VOL_DATA:/var/lib/postgresql/data" \
    -v "$VOL_SOCKET:/var/run/postgresql" \
    -v "$VOL_REPO:/repo" \
    -v "$CONF_DIR:/etc/pgbackrest:ro" \
    "$IMG_PG" >/dev/null

# O repositório posix precisa ser gravável pelo uid do postgres. Num repo S3 esta
# etapa não existe — é a única diferença operacional do teste para produção.
docker exec -u root "${PREFIXO}-pg" chown postgres:postgres /repo

echo -n "    esperando o Postgres"
for _ in $(seq 1 60); do
    docker exec "${PREFIXO}-pg" psql -U postgres -d "$DB" -tAc 'SELECT 1' >/dev/null 2>&1 && break
    echo -n "."; sleep 2
done
echo
if docker exec "${PREFIXO}-pg" psql -U postgres -d "$DB" -tAc 'SHOW archive_mode' 2>/dev/null | grep -qx on; then
    ok "archive_mode = on no banco"
else
    nok "archive_mode não ficou on"; echo "$(docker logs --tail 30 "${PREFIXO}-pg" 2>&1)"; exit 1
fi

docker exec "${PREFIXO}-pg" psql -U postgres -d "$DB" -tAc \
    "CREATE TABLE estabelecimento AS SELECT g AS id, md5(g::text) AS cnpj FROM generate_series(1, 50000) g" >/dev/null

# ---------------------------------------------------------------------------
# Sidecar
# ---------------------------------------------------------------------------
TEXTFILE_DIR="$CONF_DIR/textfile"
mkdir -p "$TEXTFILE_DIR"
docker run -d --name "${PREFIXO}-sidecar" --network "$REDE" \
    -e PGBACKREST_STANZA="$STANZA" \
    -e BDH_BACKUP_TEXTFILE_DIR=/var/lib/node_exporter/textfile \
    -v "$VOL_DATA:/var/lib/postgresql/data" \
    -v "$VOL_SOCKET:/var/run/postgresql" \
    -v "$VOL_REPO:/repo" \
    -v "$CONF_DIR:/etc/pgbackrest:ro" \
    -v "$TEXTFILE_DIR:/var/lib/node_exporter/textfile" \
    "$IMG_BK" >/dev/null

echo -n "    esperando o sidecar criar a stanza"
for _ in $(seq 1 45); do
    docker logs "${PREFIXO}-sidecar" 2>&1 | grep -q "agendado:" && break
    docker inspect -f '{{.State.Running}}' "${PREFIXO}-sidecar" 2>/dev/null | grep -qx false && break
    echo -n "."; sleep 2
done
echo

if docker logs "${PREFIXO}-sidecar" 2>&1 | grep -q "agendado:"; then
    ok "stanza-create e check passaram, e o agendamento foi escrito"
else
    nok "o sidecar não chegou ao agendamento"
    docker logs --tail 40 "${PREFIXO}-sidecar" 2>&1 | sed 's/^/      /'
    exit 1
fi

# /etc/cron.d ignora em SILÊNCIO um arquivo sem nova linha no fim e um arquivo
# com permissão diferente de 0644. As duas falhas são invisíveis até a madrugada
# em que o backup não roda.
CRON="$(docker exec "${PREFIXO}-sidecar" cat /etc/cron.d/pgbackrest)"
if printf '%s' "$CRON" | grep -q 'postgres /usr/local/bin/pgbackrest-backup-run.sh full'; then
    ok "o job de full está no /etc/cron.d com o usuário postgres"
else
    nok "job de full ausente ou malformado"
fi
if [ "$(docker exec "${PREFIXO}-sidecar" stat -c '%a %U' /etc/cron.d/pgbackrest)" = "644 root" ]; then
    ok "/etc/cron.d/pgbackrest com dono e permissão que o cron aceita"
else
    nok "/etc/cron.d/pgbackrest com dono/permissão que o cron IGNORA em silêncio"
fi
if docker exec "${PREFIXO}-sidecar" sh -c 'tail -c1 /etc/cron.d/pgbackrest | od -An -c | grep -q "\\\\n"'; then
    ok "o arquivo de cron termina em nova linha"
else
    nok "o arquivo de cron NÃO termina em nova linha — o cron descarta a última entrada"
fi
if docker exec "${PREFIXO}-sidecar" pgrep -x cron >/dev/null; then
    ok "o cron está rodando como PID 1 do container"
else
    nok "o cron não está rodando"
fi

# O healthcheck é extraído aqui e AFIRMADO depois do primeiro backup — ver
# `checar_healthcheck`, chamada logo após o `--type=full`.
#
# A ordem é o ponto. Rodá-lo aqui, com a stanza recém-criada e nenhum backup
# ainda, testava duas coisas ao mesmo tempo e reprovava pela errada: o
# `pgbackrest info` de uma stanza sem backup devolve `status.code = 2`
# ("no valid backups"), então o `jq -e '.code == 0'` falha mesmo com o `su` e o
# usuário perfeitamente corretos. O que este bloco existe para pegar é OUTRA
# coisa — o pgBackRest recusando comandos sob root —, e essa falha some no meio.
#
# Que um sidecar sem backup nenhum fique `unhealthy` é o comportamento
# desejado, e não um defeito a contornar: `start_period` é de 2 min e o passo 4
# do README manda rodar o primeiro full logo depois de subir.
HC="$(python3 - "$RAIZ/postgres/docker-compose.backup.yml" <<'PY'
import json, re, sys
texto = open(sys.argv[1], encoding='utf-8').read()
linha = re.search(r'^\s*test:\s*(\[.*\])\s*$', texto, re.M)
print(json.loads(linha.group(1))[1] if linha else '')
PY
)"
HC="${HC//\$\$/\$}"
[ -n "$HC" ] || nok "não achei o healthcheck em docker-compose.backup.yml"

# Executado COMO O DOCKER EXECUTA: usuário padrão do container (root) e a mesma
# linha de comando. Rodá-lo como `postgres` deixaria passar a única forma de ele
# quebrar — o pgBackRest recusa comandos sob root, e a recusa sai pelo stdout,
# onde o `jq` a lê como se fosse JSON.
checar_healthcheck() {
    [ -n "$HC" ] || return 0
    if docker exec -e PGBACKREST_STANZA="$STANZA" "${PREFIXO}-sidecar" sh -c "$HC" >/dev/null 2>&1; then
        ok "o healthcheck do compose passa com o usuário que o Docker usa"
    else
        nok "o healthcheck do compose FALHA como o Docker o executa — o container fica unhealthy para sempre"
        docker exec -e PGBACKREST_STANZA="$STANZA" "${PREFIXO}-sidecar" sh -c "$HC" 2>&1 | head -3 | sed 's/^/      /'
    fi
}

# ---------------------------------------------------------------------------
# Backup completo
# ---------------------------------------------------------------------------
info "rodando o backup completo"
if docker exec -u postgres -e PGBACKREST_STANZA="$STANZA" \
       -e BDH_BACKUP_TEXTFILE_DIR=/var/lib/node_exporter/textfile \
       "${PREFIXO}-sidecar" /usr/local/bin/pgbackrest-backup-run.sh full >/dev/null 2>&1; then
    ok "backup --type=full concluiu"
else
    nok "backup --type=full falhou"
    docker exec -u postgres "${PREFIXO}-sidecar" pgbackrest --stanza="$STANZA" info 2>&1 | sed 's/^/      /'
fi

# Agora sim: com um backup no repositório, `info` devolve status 0 e o que
# sobra para o healthcheck reprovar é o que ele existe para pegar.
checar_healthcheck

PROM="$TEXTFILE_DIR/pgbackrest.prom"
if [ -f "$PROM" ]; then
    ok "o arquivo de métricas foi escrito"
else
    nok "nenhum arquivo de métricas em $PROM"
fi
for metrica in pgbackrest_info_ok pgbackrest_repo_status_code pgbackrest_backup_count \
               pgbackrest_backup_last_completion_timestamp_seconds \
               pgbackrest_archive_segments_present pgbackrest_run_last_success; do
    if grep -q "^${metrica}{" "$PROM" 2>/dev/null; then
        ok "métrica ${metrica} presente"
    else
        nok "métrica ${metrica} AUSENTE — o alerta correspondente ficaria sem série"
    fi
done
if grep -q '^pgbackrest_backup_count{stanza="'"$STANZA"'",type="full"} 1$' "$PROM" 2>/dev/null; then
    ok "pgbackrest_backup_count{type=full} = 1"
else
    nok "contagem de full errada: $(grep 'backup_count.*full' "$PROM" 2>/dev/null)"
fi
# Os três tipos sempre presentes, mesmo os que não existem no repositório: sem
# a série em 0, o alerta NenhumBackupCompleto não teria em cima de que avaliar.
if grep -q 'type="incr"} 0$' "$PROM" 2>/dev/null; then
    ok "tipos sem backup aparecem com contagem 0 (e não ausentes)"
else
    nok "tipo sem backup ficou sem série"
fi
if grep -q '^pgbackrest_archive_segments_present{stanza="'"$STANZA"'"} 1$' "$PROM" 2>/dev/null; then
    ok "há segmentos de WAL no repositório (PITR de fato disponível)"
else
    nok "nenhum WAL no repositório — haveria backup sem PITR"
fi

# ---------------------------------------------------------------------------
# Escrita nova + diferencial: é o que prova que o WAL depois do full é
# recuperável, e não só que o full existe.
# ---------------------------------------------------------------------------
docker exec "${PREFIXO}-pg" psql -U postgres -d "$DB" -tAc \
    "INSERT INTO estabelecimento SELECT g, md5(g::text) FROM generate_series(50001, 60000) g" >/dev/null
docker exec "${PREFIXO}-pg" psql -U postgres -d "$DB" -tAc "SELECT pg_switch_wal()" >/dev/null
sleep 3

if docker exec -u postgres -e PGBACKREST_STANZA="$STANZA" \
       -e BDH_BACKUP_TEXTFILE_DIR=/var/lib/node_exporter/textfile \
       "${PREFIXO}-sidecar" /usr/local/bin/pgbackrest-backup-run.sh diff >/dev/null 2>&1; then
    ok "backup --type=diff concluiu"
else
    nok "backup --type=diff falhou"
fi

IDADE="$(docker exec "${PREFIXO}-pg" psql -U postgres -d "$DB" -tAc \
    "SELECT coalesce(extract(epoch from now() - last_archived_time)::int, -1) FROM pg_stat_archiver")"
if [ "$IDADE" -ge 0 ] && [ "$IDADE" -lt 300 ]; then
    ok "pg_stat_archiver.last_archived_time está fresco (${IDADE}s) — o alerta ficaria verde"
else
    nok "idade do último arquivamento = ${IDADE}s"
fi

# ---------------------------------------------------------------------------
# Restore: o ensaio inteiro, pelo mesmo script que roda em produção
# ---------------------------------------------------------------------------
info "ensaio de restauração (restore-drill.sh)"
SAIDA="$(PG_VOLUME="$VOL_DATA" \
    EXTRA_MOUNTS="-v ${VOL_REPO}:/repo" \
    PGBACKREST_CONF_DIR="$CONF_DIR" \
    PGBACKREST_IMAGE="$IMG_BK" \
    RESTORE_VOLUME="$VOL_RESTORE" \
    RESTORE_PORT=15498 \
    bash "$RAIZ/postgres/backup/restore-drill.sh" \
        --stanza "$STANZA" --db "$DB" --tabela estabelecimento --esperado 60000 2>&1)"
RC=$?
# O drill roda o pgbackrest num container próprio; o repositório posix precisa
# estar visível ali também.
if [ "$RC" -eq 0 ]; then
    ok "restore-drill.sh restaurou e conferiu a contagem"
    printf '%s\n' "$SAIDA" | grep -E 'RTO medido|contagem de' | sed 's/^/      /'
else
    nok "restore-drill.sh falhou"
    printf '%s\n' "$SAIDA" | tail -25 | sed 's/^/      /'
fi

# A trava de isolamento: apontar o drill para o volume de produção tem de ser
# recusado ANTES de qualquer escrita.
if PG_VOLUME="$VOL_DATA" PGBACKREST_CONF_DIR="$CONF_DIR" PGBACKREST_IMAGE="$IMG_BK" \
   EXTRA_MOUNTS="-v ${VOL_REPO}:/repo" \
   RESTORE_VOLUME="$VOL_DATA" RESTORE_PORT=15497 \
   bash "$RAIZ/postgres/backup/restore-drill.sh" \
       --stanza "$STANZA" --db "$DB" --tabela estabelecimento >/dev/null 2>&1; then
    nok "o drill ACEITOU restaurar sobre o volume de produção"
else
    ok "o drill recusa restaurar sobre o volume de produção"
fi

echo
echo "  ${PASS} passaram, ${FAIL} falharam"
[ "$FAIL" -eq 0 ]
