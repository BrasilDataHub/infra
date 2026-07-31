#!/usr/bin/env bash
# Ensaio de restauração — roda no HOST do banco.
#
#   bash restore-drill.sh --stanza dados-cnpj --db dados_cnpj \
#        --tabela estabelecimento --esperado 72318968
#
# Faz o caminho inteiro e mede o que interessa:
#   1. cria o volume de restauração (SEPARADO do de produção);
#   2. restaura a stanza nele, pelo sidecar;
#   3. sobe um Postgres temporário sobre esse volume, em porta própria;
#   4. espera o recovery terminar e roda a contagem de conferência;
#   5. imprime o RTO real (restore + recovery + verificação) e derruba tudo.
#
# "Backup não testado não é backup" é a razão de este script existir. O número
# que ele imprime — o RTO medido — é o que vai para EXECUCAO.md; sem ele, o RTO
# é uma estimativa, e estimativa de RTO é o tipo de número que só é conferido
# durante o incidente.
#
# NADA aqui toca o volume, a porta ou o container de produção. As três
# verificações que garantem isso estão em `checar_isolamento`.
set -euo pipefail

STANZA=""
DB=""
TABELA=""
ESPERADO=""
TOLERANCIA_PCT="${TOLERANCIA_PCT:-1}"
PG_VOLUME="${PG_VOLUME:-bdh_pg_data}"
RESTORE_VOLUME="${RESTORE_VOLUME:-bdh_pg_restore}"
RESTORE_PORT="${RESTORE_PORT:-15499}"
CONF_DIR="${PGBACKREST_CONF_DIR:-/etc/pgbackrest}"
IMAGEM="${PGBACKREST_IMAGE:-ghcr.io/brasildatahub/pgbackrest:17}"
NOME_TMP="${NOME_TMP:-bdh-pg-restore-drill}"
MANTER=false
RESTORE_ARGS=()
# Mounts extras para os dois containers do ensaio, no formato do `docker run`.
# Existe para o repositório `posix` (ou NFS), em que o repositório é um caminho
# e não um endpoint: `EXTRA_MOUNTS="-v bdh_repo:/repo"`. Com repo1-type=s3 —
# o caso de produção — fica vazio e nada muda.
read -r -a EXTRA_MOUNTS <<< "${EXTRA_MOUNTS:-}"

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Opções:
  --stanza NOME       stanza do pgBackRest (obrigatória)
  --db NOME           database a consultar no cluster restaurado (obrigatória)
  --tabela NOME       tabela de conferência (obrigatória)
  --esperado N        contagem esperada; a divergência é comparada com --tolerancia
  --tolerancia PCT    tolerância percentual da contagem (default 1)
  --tipo TIPO         --type do pgbackrest restore (ex.: time)
  --alvo ALVO         --target do pgbackrest restore (ex.: "2026-08-01 03:00:00-03")
  --manter            não derruba o Postgres temporário ao final (para inspeção)
  --volume-restore N  volume de destino (default bdh_pg_restore)
  --porta N           porta do Postgres temporário (default 15499)
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --stanza)          STANZA="$2"; shift 2 ;;
        --db)              DB="$2"; shift 2 ;;
        --tabela)          TABELA="$2"; shift 2 ;;
        --esperado)        ESPERADO="$2"; shift 2 ;;
        --tolerancia)      TOLERANCIA_PCT="$2"; shift 2 ;;
        --tipo)            RESTORE_ARGS+=("--type=$2"); shift 2 ;;
        --alvo)            RESTORE_ARGS+=("--target=$2"); shift 2 ;;
        --manter)          MANTER=true; shift ;;
        --volume-restore)  RESTORE_VOLUME="$2"; shift 2 ;;
        --porta)           RESTORE_PORT="$2"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "opção desconhecida: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$STANZA" ]  || { echo "--stanza é obrigatória" >&2; exit 2; }
[ -n "$DB" ]      || { echo "--db é obrigatória" >&2; exit 2; }
[ -n "$TABELA" ]  || { echo "--tabela é obrigatória" >&2; exit 2; }

C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_OFF=$'\033[0m'
log()  { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '%s  %s✓%s %s\n' "$(date -u +%H:%M:%S)" "$C_OK" "$C_OFF" "$*"; }
die()  { printf '%s  %s✗ %s%s\n' "$(date -u +%H:%M:%S)" "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Isolamento — as três formas de este script destruir produção, todas fechadas
# ---------------------------------------------------------------------------
checar_isolamento() {
    [ "$RESTORE_VOLUME" != "$PG_VOLUME" ] \
        || die "o volume de restauração é o MESMO de produção ($PG_VOLUME). Recusando."

    # Porta ocupada significa quase sempre que ela é a do banco de produção.
    if (exec 3<>"/dev/tcp/127.0.0.1/${RESTORE_PORT}") 2>/dev/null; then
        exec 3<&- 2>/dev/null || true
        die "a porta ${RESTORE_PORT} já está em uso. Escolha outra com --porta."
    fi

    # Um container com este nome, de uma execução anterior interrompida, seria
    # reaproveitado pelo `docker run` com um erro confuso.
    if docker ps -a --format '{{.Names}}' | grep -qx "$NOME_TMP"; then
        log "removendo container residual ${NOME_TMP} de um ensaio anterior"
        docker rm -f "$NOME_TMP" >/dev/null
    fi

    [ -d "$CONF_DIR" ] || die "$CONF_DIR não existe no host — sem configuração do pgBackRest."

    # REPOSITÓRIO POSIX SEM MOUNT — o erro que este bloco existe para traduzir.
    #
    # Com `repo1-type=posix` o repositório é um caminho de filesystem, e os
    # containers que este script cria são NOVOS: eles não herdam o mount que o
    # docker-compose.backup-local.yml deu ao Postgres e ao sidecar. Sem
    # EXTRA_MOUNTS, o pgBackRest abre `/var/lib/pgbackrest` vazio e responde:
    #
    #     ERROR: [075]: no backup set found to restore
    #     HINT: has a stanza-create been performed?
    #
    # Ou seja: a mensagem manda procurar um backup que não existe, quando o
    # backup existe e o que falta é o mount. Verificado em 31/07/2026, com um
    # full de 47,2 GB registrado e íntegro no repositório.
    local repo_tipo repo_caminho
    repo_tipo="$(sed -n 's/^[[:space:]]*repo1-type[[:space:]]*=[[:space:]]*//p' \
                 "$CONF_DIR/pgbackrest.conf" 2>/dev/null | head -1)"
    if [ "${repo_tipo:-s3}" = "posix" ]; then
        repo_caminho="$(sed -n 's/^[[:space:]]*repo1-path[[:space:]]*=[[:space:]]*//p' \
                        "$CONF_DIR/pgbackrest.conf" 2>/dev/null | head -1)"
        repo_caminho="${repo_caminho:-/var/lib/pgbackrest}"
        # O alvo do mount é o caminho de DENTRO do container, que é o que está
        # no pgbackrest.conf; o de origem é do host e o script não tem como
        # adivinhá-lo — por isso a checagem é "há mount para este alvo?", e não
        # "o caminho existe no host".
        case " ${EXTRA_MOUNTS[*]+${EXTRA_MOUNTS[*]}} " in
            *":${repo_caminho} "*|*":${repo_caminho}:"*) ;;
            *)
                die "repo1-type=posix e o repositório NÃO está montado nos containers do ensaio.
   O restore falharia com 'no backup set found to restore', que sugere um
   backup ausente — mas o que falta é o mount: os containers deste script são
   novos e não herdam o do docker-compose.backup-local.yml.

   Informe a origem no host (o BDH_BACKUP_REPO_DIR do .env do postgres):
     EXTRA_MOUNTS=\"-v /caminho/no/host:${repo_caminho}\" bash \$0 ...

   Com repo1-type=s3 esta checagem não se aplica: lá o repositório é um
   endpoint e nenhum mount é necessário."
                ;;
        esac
    fi
}

limpar() {
    if [ "$MANTER" = true ]; then
        log "--manter: o Postgres temporário continua no ar em 127.0.0.1:${RESTORE_PORT} (container ${NOME_TMP})"
        log "para derrubar:  docker rm -f ${NOME_TMP}"
        return
    fi
    docker rm -f "$NOME_TMP" >/dev/null 2>&1 || true
}
trap limpar EXIT

checar_isolamento

INICIO_TOTAL="$(date +%s)"

# ---------------------------------------------------------------------------
# 1 · Restore
# ---------------------------------------------------------------------------
log "criando o volume ${RESTORE_VOLUME} (se não existir)"
docker volume create "$RESTORE_VOLUME" >/dev/null

log "restaurando ${STANZA} em ${RESTORE_VOLUME}"
INICIO_RESTORE="$(date +%s)"
docker run --rm \
    --entrypoint /usr/local/bin/pgbackrest-restore-test.sh \
    -e "PGBACKREST_STANZA=${STANZA}" \
    -e "BDH_RESTORE_PATH=/restore" \
    -v "${RESTORE_VOLUME}:/restore" \
    -v "${CONF_DIR}:/etc/pgbackrest:ro" \
    ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"} \
    "$IMAGEM" "${RESTORE_ARGS[@]+"${RESTORE_ARGS[@]}"}" \
    || die "o restore falhou"
FIM_RESTORE="$(date +%s)"
ok "restore concluído em $((FIM_RESTORE - INICIO_RESTORE))s"

# ---------------------------------------------------------------------------
# 2 · Recovery
# ---------------------------------------------------------------------------
# Cinco parâmetros do cluster de ORIGEM são obrigatórios no recovery, e o
# Postgres se recusa a abrir com qualquer um deles menor:
#
#   FATAL: recovery aborted because of insufficient parameter settings
#   DETAIL: max_connections = 100 is a lower setting than on the primary
#           server, where its value was 150.
#
# Eles viajam no `pg_control` do backup, e é de lá que os lemos — não do
# deploy de produção. Assim o ensaio continua não dependendo de nenhuma env do
# host, e ao mesmo tempo funciona com qualquer valor que a origem tenha.
#
# Subir com os defaults do initdb faz o recovery falhar em TODO cluster que
# tenha mexido em algum dos cinco, que é praticamente todo cluster de produção.
log "lendo do backup os parâmetros que o recovery exige"
CONTROLDATA="$(docker run --rm \
    --entrypoint pg_controldata \
    -v "${RESTORE_VOLUME}:/restore" \
    ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"} \
    "$IMAGEM" /restore 2>/dev/null)" \
    || die "não foi possível ler o pg_control do PGDATA restaurado"

# `pg_controldata` imprime "max_connections setting:  150". O `-c` só entra
# quando o valor foi lido: um `-c max_connections=` vazio impede o Postgres de
# subir, e um default chutado aqui reintroduziria o mesmo defeito.
PARAMS=()
for par in max_connections max_worker_processes max_wal_senders \
           max_prepared_xacts max_locks_per_xact; do
    valor="$(printf '%s\n' "$CONTROLDATA" \
             | sed -n "s/^${par} setting:[[:space:]]*\([0-9]\{1,\}\)$/\1/p" | head -1)"
    [ -n "$valor" ] || continue
    case "$par" in
        max_prepared_xacts)   nome=max_prepared_transactions ;;
        max_locks_per_xact)   nome=max_locks_per_transaction ;;
        *)                    nome="$par" ;;
    esac
    PARAMS+=(-c "${nome}=${valor}")
    log "  ${nome} = ${valor} (da origem)"
done

# A porta é publicada em 127.0.0.1 e não em 0.0.0.0: um cluster restaurado tem a
# MESMA senha do de produção, e publicá-lo na interface externa por dez minutos
# é o tipo de atalho que vira incidente.
# PGDATA=/restore, e NÃO o caminho default. O motivo não é cosmético: o
# `pgbackrest restore` grava em postgresql.auto.conf um
# `restore_command = pgbackrest ... --pg1-path=<caminho usado no restore> ...`.
# Subir o cluster com o volume montado em outro lugar faz todo `archive-get`
# morrer com "unable to chdir() to '/restore'", o recovery não acha o
# checkpoint e o Postgres sai com FATAL. O cluster restaurado precisa enxergar
# o PGDATA no MESMO caminho em que foi restaurado.
log "subindo o Postgres temporário na porta ${RESTORE_PORT}"
INICIO_RECOVERY="$(date +%s)"
docker run -d --name "$NOME_TMP" \
    --entrypoint docker-entrypoint.sh \
    -e POSTGRES_PASSWORD=ensaio-nao-usada \
    -e PGDATA=/restore \
    -v "${RESTORE_VOLUME}:/restore" \
    -v "${CONF_DIR}:/etc/pgbackrest:ro" \
    -p "127.0.0.1:${RESTORE_PORT}:5432" \
    ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"} \
    "$IMAGEM" postgres ${PARAMS[@]+"${PARAMS[@]}"} >/dev/null \
    || die "não foi possível subir o Postgres temporário"

log "esperando o recovery terminar (pode levar tanto quanto o volume de WAL a aplicar)"
DEADLINE=$(( $(date +%s) + ${RECOVERY_TIMEOUT:-3600} ))
while :; do
    if docker exec "$NOME_TMP" psql -U postgres -d postgres -tAc \
           'SELECT NOT pg_is_in_recovery()' 2>/dev/null | grep -qx t; then
        break
    fi
    # Container morto NÃO é "ainda em recovery". Sem esta verificação, um
    # Postgres que sai com FATAL nos primeiros 3 segundos deixa o laço rodando
    # até o timeout inteiro — uma hora de espera por um erro que já aconteceu.
    if [ "$(docker inspect -f '{{.State.Running}}' "$NOME_TMP" 2>/dev/null)" != "true" ]; then
        docker logs --tail 40 "$NOME_TMP" >&2
        die "o Postgres temporário morreu durante o recovery (log acima)"
    fi
    [ "$(date +%s)" -lt "$DEADLINE" ] || {
        docker logs --tail 40 "$NOME_TMP" >&2
        die "o recovery não terminou no tempo limite"
    }
    sleep 5
done
FIM_RECOVERY="$(date +%s)"
ok "recovery concluído em $((FIM_RECOVERY - INICIO_RECOVERY))s"

# ---------------------------------------------------------------------------
# 3 · Conferência
# ---------------------------------------------------------------------------
log "contando ${TABELA} em ${DB}"
INICIO_CHECK="$(date +%s)"
CONTAGEM="$(docker exec "$NOME_TMP" psql -U postgres -d "$DB" -tAc "SELECT count(*) FROM ${TABELA}")" \
    || die "a contagem falhou — o database ${DB} ou a tabela ${TABELA} não existem no cluster restaurado"
FIM_CHECK="$(date +%s)"
ok "${TABELA} tem ${CONTAGEM} linhas (contadas em $((FIM_CHECK - INICIO_CHECK))s)"

VEREDITO="ok"
if [ -n "$ESPERADO" ]; then
    DIF=$(( CONTAGEM > ESPERADO ? CONTAGEM - ESPERADO : ESPERADO - CONTAGEM ))
    # bash não tem ponto flutuante; a comparação é feita em inteiros
    # multiplicando os dois lados por 100.
    if [ $(( DIF * 100 )) -le $(( ESPERADO * TOLERANCIA_PCT )) ]; then
        ok "dentro da tolerância de ${TOLERANCIA_PCT}% sobre ${ESPERADO} (diferença de ${DIF})"
    else
        VEREDITO="divergente"
        printf '%s✗ contagem fora da tolerância: esperado ~%s, obtido %s (diferença de %s)%s\n' \
            "$C_ERR" "$ESPERADO" "$CONTAGEM" "$DIF" "$C_OFF" >&2
    fi
fi

FIM_TOTAL="$(date +%s)"

echo
echo "──────────────────────────────────────────────────────────────"
echo " Ensaio de restauração — ${STANZA}"
echo "──────────────────────────────────────────────────────────────"
printf ' restore .................. %6ss\n' "$((FIM_RESTORE - INICIO_RESTORE))"
printf ' recovery ................. %6ss\n' "$((FIM_RECOVERY - INICIO_RECOVERY))"
printf ' verificação .............. %6ss\n' "$((FIM_CHECK - INICIO_CHECK))"
printf ' RTO medido (total) ....... %6ss  (%s min)\n' \
    "$((FIM_TOTAL - INICIO_TOTAL))" "$(( (FIM_TOTAL - INICIO_TOTAL) / 60 ))"
printf ' contagem de %-12s %6s\n' "$TABELA" "$CONTAGEM"
printf ' veredito ................. %6s\n' "$VEREDITO"
echo "──────────────────────────────────────────────────────────────"
echo
echo "Registre o RTO acima em docs/roadmap/.../EXECUCAO.md."

[ "$VEREDITO" = "ok" ] || exit 1
