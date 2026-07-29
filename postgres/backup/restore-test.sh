#!/usr/bin/env bash
# Restaura a stanza num caminho SEPARADO do PGDATA de produção.
#
#   pgbackrest-restore-test.sh [--type=time --target="2026-08-01 03:00:00-03"]
#
# Roda DENTRO do sidecar. A orquestração completa do ensaio (criar o volume,
# subir um Postgres temporário, conferir a contagem, medir o RTO) está em
# restore-drill.sh, que roda no host.
#
# A trava mais importante deste script é a primeira verificação: recusar-se a
# escrever no PGDATA de produção. `pgbackrest restore` sobre um diretório com
# dados NÃO pergunta nada — ele reconcilia o diretório com o backup, e num
# banco no ar isso é perda de dados.
set -euo pipefail

STANZA="${PGBACKREST_STANZA:?defina PGBACKREST_STANZA}"
RESTORE_PATH="${BDH_RESTORE_PATH:-/restore}"
PGDATA_DIR="${BDH_PGDATA:-/var/lib/postgresql/data}"

log() { printf '%s pgbackrest-restore: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERRO: $*" >&2; exit 1; }

[ "$RESTORE_PATH" != "$PGDATA_DIR" ] \
    || die "RESTORE_PATH é igual ao PGDATA de produção ($PGDATA_DIR). Recusando."
[ "$RESTORE_PATH" != "/" ] || die "RESTORE_PATH = / . Recusando."
[ -d "$RESTORE_PATH" ] || die "$RESTORE_PATH não existe — monte o volume de restauração."

# PG_VERSION dentro do destino significa que ali já há um cluster. Pode ser o
# resto de um ensaio anterior (ok) ou um volume trocado por engano (não ok).
if [ -f "$RESTORE_PATH/PG_VERSION" ] && [ "${BDH_RESTORE_DELTA:-true}" != "true" ]; then
    die "$RESTORE_PATH já contém um cluster. Use BDH_RESTORE_DELTA=true ou esvazie o volume."
fi

chown postgres:postgres "$RESTORE_PATH"
chmod 0700 "$RESTORE_PATH"

ARGS=(--stanza="$STANZA" --pg1-path="$RESTORE_PATH")
# --delta reaproveita os arquivos já presentes conferindo checksum. Num ensaio
# repetido isso é a diferença entre minutos e a transferência inteira de novo.
[ "${BDH_RESTORE_DELTA:-true}" = "true" ] && ARGS+=(--delta)
# `restore` num caminho que não é o pg1-path da stanza exige a flag: é a
# confirmação explícita de que a divergência é intencional.
ARGS+=(--log-level-console=info)

# Argumentos extras (--type=time --target=...) vêm da linha de comando.
if [ "$#" -gt 0 ]; then
    ARGS+=("$@")
fi

log "iniciando restore de ${STANZA} em ${RESTORE_PATH}"
INICIO="$(date +%s)"
su -s /bin/bash postgres -c "pgbackrest $(printf '%q ' "${ARGS[@]}") restore"
FIM="$(date +%s)"

log "restore concluído em $((FIM - INICIO))s"
# Consumido pelo restore-drill.sh para compor o RTO.
echo "RESTORE_WALL_CLOCK_SECONDS=$((FIM - INICIO))"
