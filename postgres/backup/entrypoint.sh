#!/usr/bin/env bash
# Entrypoint do sidecar de backup. Faz quatro coisas, nesta ordem:
#
#   1. valida a configuração ANTES de agendar qualquer coisa;
#   2. espera o Postgres aceitar conexão pelo socket compartilhado;
#   3. cria a stanza (idempotente) e roda `check`;
#   4. escreve /etc/cron.d/pgbackrest e entrega o PID 1 ao cron.
#
# A ordem importa: agendar primeiro e validar depois produz exatamente o modo de
# falha que este item existe para eliminar — um backup que "está agendado" e
# falha em silêncio toda madrugada.
set -euo pipefail

log() { printf '%s pgbackrest-sidecar: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERRO: $*" >&2; exit 1; }

STANZA="${PGBACKREST_STANZA:-}"
[ -n "$STANZA" ] || die "defina PGBACKREST_STANZA (ex.: dados-cnpj)"

CONF="${BDH_BACKUP_CONFIG:-/etc/pgbackrest/pgbackrest.conf}"
SOCKET_DIR="${BDH_BACKUP_SOCKET_DIR:-/var/run/postgresql}"
PGDATA_DIR="${BDH_PGDATA:-/var/lib/postgresql/data}"
TEXTFILE_DIR="${BDH_BACKUP_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"

# Cron do Debian roda em UTC dentro do container. Os horários dos schedules
# abaixo são UTC de propósito: 06:00 UTC = 03:00 BRT, a janela fora da
# reindexação e da carga mensal exigida pelo README.
FULL_SCHEDULE="${BDH_BACKUP_FULL_SCHEDULE:-0 6 * * 0}"
DIFF_SCHEDULE="${BDH_BACKUP_DIFF_SCHEDULE:-0 6 * * 1-6}"
# Verificação de integridade do repositório. Barata (lê metadados, não dados) e
# é o que distingue "o backup rodou" de "o backup é restaurável".
CHECK_SCHEDULE="${BDH_BACKUP_CHECK_SCHEDULE:-0 */6 * * *}"
INIT_STANZA="${BDH_BACKUP_INIT_STANZA:-true}"
WAIT_TIMEOUT="${BDH_BACKUP_WAIT_TIMEOUT:-300}"

# ---------------------------------------------------------------------------
# 1. Configuração
# ---------------------------------------------------------------------------
[ -f "$CONF" ] || die "$CONF não existe. Monte /etc/pgbackrest do host (ver README)."

# `[stanza]` precisa existir no arquivo, senão todo comando morre com um erro
# genérico de opção faltando, muito depois — na primeira madrugada.
grep -q "^\[${STANZA}\]" "$CONF" \
    || die "$CONF não tem a seção [${STANZA}]. A stanza do compose e a do arquivo têm de ser a mesma."

# O pgBackRest RECUSA um arquivo de configuração legível por outros usuários
# quando ele contém segredos, e o erro é sutil. Avisar aqui é mais barato.
PERM="$(stat -c '%a' "$CONF")"
case "$PERM" in
    600|640|400|440) : ;;
    *) log "AVISO: $CONF está com permissão $PERM; o esperado é 640 ou mais restrito." ;;
esac

[ -d "$PGDATA_DIR" ] || die "$PGDATA_DIR não existe — o volume de dados do banco não foi montado."
install -d -o postgres -g postgres -m 0755 "$TEXTFILE_DIR"

# ---------------------------------------------------------------------------
# 2. Esperar o banco
# ---------------------------------------------------------------------------
log "esperando o Postgres no socket ${SOCKET_DIR} (timeout ${WAIT_TIMEOUT}s)"
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
until su -s /bin/bash postgres -c "psql -h '$SOCKET_DIR' -U postgres -d postgres -tAc 'SELECT 1'" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || die "o Postgres não respondeu em ${WAIT_TIMEOUT}s no socket ${SOCKET_DIR}"
    sleep 3
done
log "Postgres respondeu"

# ---------------------------------------------------------------------------
# 3. Stanza
# ---------------------------------------------------------------------------
# `stanza-create` é idempotente: com a stanza já existente e coerente, ele sai 0
# ("stanza already exists and is valid"). Divergiu (ex.: o PGDATA foi
# recriado)? Ele FALHA — e falhar aqui é o comportamento certo, porque
# sobrescrever a stanza apagaria a linhagem de backups anteriores.
if [ "$INIT_STANZA" = "true" ]; then
    log "stanza-create --stanza=${STANZA}"
    su -s /bin/bash postgres -c "pgbackrest --stanza='$STANZA' stanza-create" \
        || die "stanza-create falhou. Se o PGDATA foi recriado, use 'stanza-upgrade' ou uma stanza nova — nunca --force sobre um repositório com histórico."

    log "check --stanza=${STANZA}"
    # O `check` força uma troca de segmento de WAL e confirma que ele chegou ao
    # repositório. É a única prova de que o archive_command do banco está
    # funcionando de verdade; sem ele, o primeiro sinal viria do pg_wal cheio.
    su -s /bin/bash postgres -c "pgbackrest --stanza='$STANZA' check" \
        || die "check falhou. Confirme PG_ARCHIVE_MODE=on e PG_ARCHIVE_COMMAND no serviço postgres, e que o banco foi REINICIADO depois de mudá-los."
fi

# ---------------------------------------------------------------------------
# 4. Agendamento
# ---------------------------------------------------------------------------
# /etc/cron.d exige dono root, modo 0644, sexto campo com o usuário, e o arquivo
# TEM de terminar em nova linha — sem ela o cron ignora a última entrada em
# silêncio. As três armadilhas estão cobertas abaixo.
CRON_FILE=/etc/cron.d/pgbackrest
{
    echo "# GERADO por pgbackrest-entrypoint.sh no start do container — não editar."
    echo "SHELL=/bin/bash"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    echo "PGBACKREST_STANZA=${STANZA}"
    echo "BDH_BACKUP_TEXTFILE_DIR=${TEXTFILE_DIR}"
    echo "BDH_BACKUP_SOCKET_DIR=${SOCKET_DIR}"
    echo ""
    # A saída vai para o stdout do PID 1 (o cron), que é o que o `docker logs`
    # lê. Sem esse redirecionamento o cron tenta entregar por e-mail, não há MTA
    # no container, e o resultado do backup some.
    echo "${FULL_SCHEDULE} postgres /usr/local/bin/pgbackrest-backup-run.sh full  >> /proc/1/fd/1 2>&1"
    echo "${DIFF_SCHEDULE} postgres /usr/local/bin/pgbackrest-backup-run.sh diff  >> /proc/1/fd/1 2>&1"
    echo "${CHECK_SCHEDULE} postgres /usr/local/bin/pgbackrest-backup-run.sh check >> /proc/1/fd/1 2>&1"
} > "$CRON_FILE"
chown root:root "$CRON_FILE"
chmod 0644 "$CRON_FILE"

log "agendado: full '${FULL_SCHEDULE}' · diff '${DIFF_SCHEDULE}' · check '${CHECK_SCHEDULE}' (UTC)"

# Publica o estado inicial já no start, para que a ausência de métrica signifique
# "o sidecar não está no ar" e não "ainda não deu a hora do primeiro backup".
su -s /bin/bash postgres -c "/usr/local/bin/pgbackrest-backup-run.sh publish" || true

exec "$@"
