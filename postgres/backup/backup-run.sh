#!/usr/bin/env bash
# Executa um comando do pgBackRest e publica o resultado como métricas.
#
#   pgbackrest-backup-run.sh full|diff|incr|check|publish
#
# O `publish` não roda backup nenhum: só relê `pgbackrest info` e reescreve o
# arquivo de métricas. É o que o entrypoint chama no start.
#
# POR QUE MÉTRICAS E NÃO SÓ LOG. Um backup agendado que falha em silêncio é
# indistinguível de um que funciona, e é assim que se descobre que não há backup
# no dia em que ele é necessário. O textfile collector do node_exporter
# transforma "rodou" em série temporal, e daí em alerta (backup.rules.yml).
#
# NOME DAS ENVS. Só `PGBACKREST_STANZA` usa o prefixo do produto; todas as
# outras são `BDH_BACKUP_*`. O motivo é concreto e custou um teste vermelho: o
# pgBackRest lê QUALQUER env `PGBACKREST_<OPCAO>` como se fosse uma opção de
# linha de comando e, ao encontrar uma que não existe, imprime
# `WARN: environment contains invalid option '...'` NO STDOUT — o mesmo stdout
# de `info --output=json`. O JSON sai corrompido e o parser quebra.
set -uo pipefail

MODO="${1:-publish}"
STANZA="${PGBACKREST_STANZA:?defina PGBACKREST_STANZA}"
TEXTFILE_DIR="${BDH_BACKUP_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
PROM_FILE="${TEXTFILE_DIR}/pgbackrest.prom"

log() { printf '%s pgbackrest-run[%s]: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODO" "$*"; }

# ---------------------------------------------------------------------------
# Publicação das métricas
# ---------------------------------------------------------------------------
# Escreve num temporário e move: o node_exporter lê o diretório a qualquer
# instante, e um arquivo pela metade faz o collector inteiro falhar
# (node_textfile_scrape_error 1), levando junto qualquer outro .prom do host.
publicar() {
    local tmp
    tmp="$(mktemp "${PROM_FILE}.XXXXXX")" || return 1

    local info status_code
    # `--log-level-console=off` é cinto além do suspensório: mesmo com as envs
    # renomeadas, qualquer aviso do pgBackRest no stdout invalidaria o JSON.
    info="$(pgbackrest --stanza="$STANZA" --log-level-console=off --output=json info 2>/dev/null)" || info=""
    if [ -z "$info" ] || ! printf '%s' "$info" | jq -e '.[0]' >/dev/null 2>&1; then
        # Sem info não há como saber a idade dos backups. Publicar
        # pgbackrest_info_ok 0 é melhor que não publicar nada: a série existe e o
        # alerta dispara, em vez de o alvo simplesmente sumir.
        {
            echo "# HELP pgbackrest_info_ok 1 se 'pgbackrest info' respondeu com JSON válido."
            echo "# TYPE pgbackrest_info_ok gauge"
            echo "pgbackrest_info_ok{stanza=\"${STANZA}\"} 0"
        } > "$tmp"
        mv -f "$tmp" "$PROM_FILE"
        return 1
    fi

    status_code="$(printf '%s' "$info" | jq -r '.[0].status.code // 99')"

    {
        echo "# GERADO por pgbackrest-backup-run.sh — lido pelo textfile collector do node_exporter."
        echo "# HELP pgbackrest_info_ok 1 se 'pgbackrest info' respondeu com JSON válido."
        echo "# TYPE pgbackrest_info_ok gauge"
        echo "pgbackrest_info_ok{stanza=\"${STANZA}\"} 1"
        echo "# HELP pgbackrest_repo_status_code Código de status da stanza (0 = ok)."
        echo "# TYPE pgbackrest_repo_status_code gauge"
        echo "pgbackrest_repo_status_code{stanza=\"${STANZA}\"} ${status_code}"

        echo "# HELP pgbackrest_backup_count Backups presentes no repositório, por tipo."
        echo "# TYPE pgbackrest_backup_count gauge"
        echo "# HELP pgbackrest_backup_last_completion_timestamp_seconds Fim do último backup bem-sucedido, por tipo."
        echo "# TYPE pgbackrest_backup_last_completion_timestamp_seconds gauge"
        echo "# HELP pgbackrest_backup_last_duration_seconds Duração do último backup, por tipo."
        echo "# TYPE pgbackrest_backup_last_duration_seconds gauge"
        echo "# HELP pgbackrest_backup_last_size_bytes Tamanho lógico do último backup, por tipo."
        echo "# TYPE pgbackrest_backup_last_size_bytes gauge"
        echo "# HELP pgbackrest_backup_last_repo_size_bytes Tamanho ocupado no repositório pelo último backup, por tipo."
        echo "# TYPE pgbackrest_backup_last_repo_size_bytes gauge"

        # Um bloco por tipo, sempre os três: um tipo AUSENTE do repositório
        # precisa aparecer como count 0, não como série inexistente — senão o
        # alerta de "nunca houve full" não teria em cima de que avaliar.
        printf '%s' "$info" | jq -r --arg s "$STANZA" '
            .[0].backup as $b
            | ["full","diff","incr"][]
            | . as $t
            | ($b | map(select(.type == $t))) as $m
            | (
                "pgbackrest_backup_count{stanza=\"\($s)\",type=\"\($t)\"} \($m | length)"
              ),
              (
                if ($m | length) > 0 then
                  ($m | last) as $l
                  | "pgbackrest_backup_last_completion_timestamp_seconds{stanza=\"\($s)\",type=\"\($t)\"} \($l.timestamp.stop)",
                    "pgbackrest_backup_last_duration_seconds{stanza=\"\($s)\",type=\"\($t)\"} \($l.timestamp.stop - $l.timestamp.start)",
                    "pgbackrest_backup_last_size_bytes{stanza=\"\($s)\",type=\"\($t)\"} \($l.info.size)",
                    "pgbackrest_backup_last_repo_size_bytes{stanza=\"\($s)\",type=\"\($t)\"} \($l.info.repository.size // 0)"
                else empty end
              )
        '

        # Faixa de WAL arquivada. `archive_min` ausente significa que nenhum
        # segmento chegou ao repositório — arquivamento parado, com backup full
        # presente. É o cenário em que existe backup e NÃO existe PITR.
        echo "# HELP pgbackrest_archive_segments_present 1 se há ao menos um segmento de WAL no repositório."
        echo "# TYPE pgbackrest_archive_segments_present gauge"
        printf '%s' "$info" | jq -r --arg s "$STANZA" '
            (.[0].archive // [] | map(select(.max != null)) | length > 0) as $tem
            | "pgbackrest_archive_segments_present{stanza=\"\($s)\"} \(if $tem then 1 else 0 end)"
        '

        # Resultado da última EXECUÇÃO deste script, preservado entre chamadas:
        # `publish` não sabe se o último full falhou, só que ele não está no
        # repositório. As duas informações são diferentes e as duas importam.
        if [ -f "${PROM_FILE}.estado" ]; then
            echo "# HELP pgbackrest_run_last_success 1 se a última execução agendada daquele tipo saiu 0."
            echo "# TYPE pgbackrest_run_last_success gauge"
            echo "# HELP pgbackrest_run_last_timestamp_seconds Momento da última execução agendada, por tipo."
            echo "# TYPE pgbackrest_run_last_timestamp_seconds gauge"
            cat "${PROM_FILE}.estado"
        fi
    } > "$tmp"

    mv -f "$tmp" "$PROM_FILE"
    chmod 0644 "$PROM_FILE"
}

# Registra o resultado de uma execução no arquivo de estado, substituindo a
# linha do mesmo tipo. Sem o estado, um `publish` posterior apagaria a memória de
# que o backup da madrugada falhou.
registrar_execucao() {
    local tipo="$1" sucesso="$2" agora="$3" duracao="$4"
    local estado="${PROM_FILE}.estado" tmp
    tmp="$(mktemp "${estado}.XXXXXX")" || return 1
    if [ -f "$estado" ]; then
        grep -v "type=\"${tipo}\"" "$estado" > "$tmp" || true
    fi
    {
        echo "pgbackrest_run_last_success{stanza=\"${STANZA}\",type=\"${tipo}\"} ${sucesso}"
        echo "pgbackrest_run_last_timestamp_seconds{stanza=\"${STANZA}\",type=\"${tipo}\"} ${agora}"
        echo "pgbackrest_run_last_duration_seconds{stanza=\"${STANZA}\",type=\"${tipo}\"} ${duracao}"
    } >> "$tmp"
    mv -f "$tmp" "$estado"
}

case "$MODO" in
    publish)
        publicar
        exit $?
        ;;
    check)
        inicio="$(date +%s)"
        if pgbackrest --stanza="$STANZA" check; then
            rc=0; log "check ok"
        else
            rc=1; log "check FALHOU"
        fi
        registrar_execucao check "$((1 - rc))" "$(date +%s)" "$(( $(date +%s) - inicio ))"
        publicar
        exit "$rc"
        ;;
    full|diff|incr)
        inicio="$(date +%s)"
        log "iniciando backup --type=${MODO}"
        if pgbackrest --stanza="$STANZA" --type="$MODO" backup; then
            rc=0
        else
            rc=1
        fi
        fim="$(date +%s)"
        log "terminou em $((fim - inicio))s com rc=${rc}"
        registrar_execucao "$MODO" "$((1 - rc))" "$fim" "$((fim - inicio))"
        publicar
        exit "$rc"
        ;;
    *)
        echo "uso: $0 full|diff|incr|check|publish" >&2
        exit 2
        ;;
esac
