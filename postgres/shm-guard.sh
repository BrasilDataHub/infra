#!/usr/bin/env bash
# shm-guard.sh — impede o modo de falha "could not resize shared memory segment".
#
# Com dynamic_shared_memory_type=posix, as hash tables de Parallel Hash Join
# vivem em /dev/shm. Em container, /dev/shm é um tmpfs de 64 MB por default do
# Docker — e o `shm_size` do compose é DESCARTADO SILENCIOSAMENTE por Docker
# Swarm (e portanto pelo Dokploy), razão pela qual a receita do repositório usa
# um mount tmpfs. O resultado de um deploy sem isso é uma query paralela que
# morre no meio com um erro que aponta para o lugar errado:
#
#   psycopg2.errors.DiskFull: could not resize shared memory segment
#   "/PostgreSQL.3316007114" to 16814080 bytes: No space left on device
#
# "No space left on device" não é o disco — é o tmpfs de /dev/shm. O sintoma
# aparece horas depois do deploy, na primeira query pesada, e é contraintuitivo:
# perfis MAIORES estouram mais fácil, porque o orçamento de hash é
# (workers+1) × work_mem × hash_mem_multiplier — cresce com o perfil, enquanto
# /dev/shm fica nos mesmos 64 MB.
#
# Este script roda no start do container, compara o /dev/shm real com o que o
# perfil precisa e age conforme PG_SHM_PREFLIGHT:
#
#   adapt (default) — reduz max_parallel_workers_per_gather até caber e avisa.
#                     O banco sobe e nenhuma query quebra; fica mais lento.
#   fail            — aborta o start com instruções. Para quem prefere que um
#                     deploy mal configurado não entre no ar.
#   warn            — apenas avisa e mantém os valores do perfil.
#
# Sourced por generate-config.sh antes da geração do postgresql.conf.

# --- helpers ----------------------------------------------------------------

# Converte "32MB", "2GB", "512kB", "1048576" em bytes.
# Sem unidade = kB, como o postgresql.conf faz para work_mem.
_shm_to_bytes() {
    local raw="${1:-0}" num unit
    raw="$(echo "$raw" | tr -d '[:space:]')"
    num="$(echo "$raw" | sed -E 's/[^0-9].*$//')"
    unit="$(echo "$raw" | sed -E 's/^[0-9]+//' | tr '[:upper:]' '[:lower:]')"
    [ -z "$num" ] && { echo 0; return; }
    case "$unit" in
        b)        echo $(( num )) ;;
        kb|k|"")  echo $(( num * 1024 )) ;;
        mb|m)     echo $(( num * 1024 * 1024 )) ;;
        gb|g)     echo $(( num * 1024 * 1024 * 1024 )) ;;
        tb|t)     echo $(( num * 1024 * 1024 * 1024 * 1024 )) ;;
        *)        echo $(( num * 1024 )) ;;
    esac
}

# "2.0" -> 200 ; "3" -> 300 ; "1.5" -> 150  (aritmética inteira em centésimos)
_shm_mult_x100() {
    local raw="${1:-1.0}" int frac
    raw="$(echo "$raw" | tr -d '[:space:]')"
    int="${raw%%.*}"
    frac="${raw#*.}"
    [ "$frac" = "$raw" ] && frac="0"
    frac="$(printf '%s' "${frac}00" | cut -c1-2)"
    [ -z "$int" ] && int=0
    echo $(( 10#${int} * 100 + 10#${frac} ))
}

_shm_human() {
    local b="${1:-0}"
    if   [ "$b" -ge 1073741824 ]; then echo "$(( b / 1073741824 )) GB"
    elif [ "$b" -ge 1048576 ];    then echo "$(( b / 1048576 )) MB"
    elif [ "$b" -ge 1024 ];       then echo "$(( b / 1024 )) kB"
    else echo "${b} B"; fi
}

# --- cálculo ----------------------------------------------------------------

# Bytes disponíveis em /dev/shm (o tamanho do tmpfs, não o uso atual).
_shm_available_bytes() {
    local size
    # Override para os testes (test/shm-guard.test.sh) — nunca definido em produção.
    if [ -n "${SHM_GUARD_FAKE_BYTES:-}" ]; then
        echo "${SHM_GUARD_FAKE_BYTES}"; return
    fi
    # `|| true`: sob `set -o pipefail` um df que falhe abortaria o start.
    size="$(df -B1 /dev/shm 2>/dev/null | awk 'NR==2 {print $2}' || true)"
    # Fallback portável: BSD/macOS não têm `df -B1`.
    case "$size" in
        ''|*[!0-9]*)
            size="$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2 * 1024}' || true)" ;;
    esac
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    echo "$size"
}

# Pico de /dev/shm estimado para N workers por gather.
# (N+1) participantes × work_mem × hash_mem_multiplier × nós de hash simultâneos.
# Com N=0 não há Parallel Hash: o consumo cai para as tuple queues do Gather.
_shm_required_bytes() {
    local workers="$1" work_mem_b="$2" mult_x100="$3" nodes="$4"
    if [ "$workers" -le 0 ]; then
        echo $(( 4 * 1024 * 1024 ))   # folga para tuple queues e DSM de controle
        return
    fi
    echo $(( (workers + 1) * work_mem_b * mult_x100 / 100 * nodes ))
}

shm_guard_run() {
    local mode shm_bytes work_mem_b mult_x100 nodes want need fits margin_pct

    mode="$(echo "${PG_SHM_PREFLIGHT:-adapt}" | tr '[:upper:]' '[:lower:]')"
    # `case` em vez de `[ ] || [ ] && return`: a forma com && tem precedência
    # traiçoeira e, sob `set -e`, aborta o start quando nenhum ramo casa.
    case "$mode" in off|skip|disabled) return 0 ;; esac

    shm_bytes="$(_shm_available_bytes)"
    # Sem medição confiável (df indisponível), não interferir no perfil.
    if [ "$shm_bytes" -le 0 ]; then
        return 0
    fi

    work_mem_b="$(_shm_to_bytes "${PG_WORK_MEM:-16MB}")"
    mult_x100="$(_shm_mult_x100 "${PG_HASH_MEM_MULTIPLIER:-2.0}")"
    nodes="${PG_SHM_HASH_NODES:-2}"
    want="${PG_MAX_PARALLEL_WORKERS_PER_GATHER:-2}"

    # Reserva de segurança: o Postgres também usa /dev/shm para o segmento
    # principal de DSM e para as tuple queues. Trabalhamos com 85% do tmpfs.
    local usable=$(( shm_bytes * 85 / 100 ))

    need="$(_shm_required_bytes "$want" "$work_mem_b" "$mult_x100" "$nodes")"

    if [ "$need" -le "$usable" ]; then
        margin_pct=$(( need * 100 / shm_bytes ))
        echo "shm-guard: /dev/shm=$(_shm_human "$shm_bytes") — pico estimado de Parallel Hash $(_shm_human "$need") (~${margin_pct}%). OK."
        return 0
    fi

    # Não cabe. Descobre o maior número de workers que caberia.
    fits=0
    local w
    for w in $(seq "$want" -1 1); do
        if [ "$(_shm_required_bytes "$w" "$work_mem_b" "$mult_x100" "$nodes")" -le "$usable" ]; then
            fits="$w"; break
        fi
    done

    cat >&2 <<BANNER

================================================================================
 shm-guard: /dev/shm INSUFICIENTE PARA O PERFIL — risco de "could not resize
            shared memory segment ... No space left on device"
--------------------------------------------------------------------------------
  /dev/shm disponível .............. $(_shm_human "$shm_bytes")
  pico estimado (Parallel Hash) .... $(_shm_human "$need")
    = (${want} workers + 1) x work_mem ${PG_WORK_MEM:-16MB} x hash_mem_multiplier ${PG_HASH_MEM_MULTIPLIER:-2.0} x ${nodes} nos de hash

  CAUSA MAIS COMUM: o deploy nao aplicou o /dev/shm do perfil. Atencao ao
  shm_size do compose: Docker Swarm (e portanto Dokploy) NAO o suporta --
  ele e descartado sem erro e /dev/shm fica no default de 64 MB.

  COMO CORRIGIR -- mount tmpfs no compose (funciona em compose E em Swarm;
  passo a passo em postgres/docs/deploy.md):

    volumes:
      - type: tmpfs
        target: /dev/shm
        tmpfs:
          size: 2147483648        # bytes, pelo perfil

  Servico Swarm ja no ar, sem recriar o stack:
    docker service update \\
      --mount-add type=tmpfs,destination=/dev/shm,tmpfs-size=2147483648 <servico>

  Kubernetes: emptyDir { medium: Memory, sizeLimit: 2Gi } montado em /dev/shm

  Bytes por perfil: 8gb->1073741824  16gb->2147483648  32gb/64gb->4294967296
                    128gb->8589934592
================================================================================

BANNER

    case "$mode" in
        fail)
            echo "shm-guard: PG_SHM_PREFLIGHT=fail — abortando o start." >&2
            exit 1
            ;;
        warn)
            echo "shm-guard: PG_SHM_PREFLIGHT=warn — mantendo max_parallel_workers_per_gather=${want}." >&2
            echo "shm-guard: queries paralelas pesadas PODEM falhar com DiskFull." >&2
            ;;
        *)  # adapt
            export PG_MAX_PARALLEL_WORKERS_PER_GATHER="$fits"
            echo "shm-guard: PG_SHM_PREFLIGHT=adapt — max_parallel_workers_per_gather ${want} -> ${fits}." >&2
            if [ "$fits" -eq 0 ]; then
                echo "shm-guard: paralelismo por query DESLIGADO. Nenhuma query quebra, mas as pesadas ficam" >&2
                echo "shm-guard: sensivelmente mais lentas. Corrija o /dev/shm e remova esta degradacao." >&2
            fi
            ;;
    esac
}

shm_guard_run
