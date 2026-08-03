#!/bin/bash

set -e

# Set default values if not provided
RUN_SETUP_TASKS=${RUN_SETUP_TASKS:-'true'}
RUN_MIGRATIONS=${RUN_MIGRATIONS:-'false'}
APP_ENV=${APP_ENV:-'production'}

ARTISAN=${ARTISAN:-"php -d variables_order=EGPCS /var/www/html/artisan"}

# Function to log messages
log() {
    local type="$1"
    local message="$2"
    echo "[$type] $message"
}

# CPU do cgroup, não nproc — respeita --cpus do container.
available_cpus() {
    local cpus quota period limited

    cpus=$(nproc 2>/dev/null || echo 1)

    if [ -r /sys/fs/cgroup/cpu.max ]; then
        # cgroup v2: "<quota> <period>" na mesma linha, quota='max' sem limite.
        read -r quota period < /sys/fs/cgroup/cpu.max
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        # cgroup v1: arquivos separados, quota=-1 sem limite.
        quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)
        period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
    fi

    if [ -n "${quota:-}" ] && [ "$quota" != "max" ] && [ "${quota:-0}" -gt 0 ] 2>/dev/null; then
        limited=$(( quota / ${period:-100000} ))
        [ "$limited" -lt 1 ] && limited=1
        [ "$limited" -lt "$cpus" ] && cpus=$limited
    fi

    [ "${cpus:-0}" -lt 1 ] && cpus=1
    echo "$cpus"
}

# Memória do container em MiB, ou 0 quando não há limite declarado.
container_memory_mb() {
    local bytes

    if [ -r /sys/fs/cgroup/memory.max ]; then
        bytes=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
    fi

    # 'max' (v2) ou o sentinela gigante do v1 significam "sem limite".
    case "${bytes:-max}" in
        max|''|*[!0-9]*) echo 0; return 0 ;;
    esac
    [ "$bytes" -gt 4611686018427387904 ] && { echo 0; return 0; }

    echo $(( bytes / 1048576 ))
}

# `memory_limit` do PHP em MiB. -1 (sem limite) devolve 0: nesse caso não há
# como orçar memória por thread, e a guarda abaixo simplesmente não se aplica.
php_memory_limit_mb() {
    local raw value unit

    raw=$(php -r 'echo ini_get("memory_limit");' 2>/dev/null)
    [ -z "$raw" ] && { echo 0; return 0; }
    [ "$raw" = "-1" ] && { echo 0; return 0; }

    value=$(echo "$raw" | tr -dc '0-9')
    unit=$(echo "$raw" | tr -d '0-9 ' | tr '[:upper:]' '[:lower:]')
    [ -z "$value" ] && { echo 0; return 0; }

    case "$unit" in
        g) echo $(( value * 1024 )) ;;
        k) echo $(( value / 1024 )) ;;
        '') echo $(( value / 1048576 )) ;;  # sem sufixo, o PHP lê bytes
        *) echo "$value" ;;                 # m, ou qualquer coisa já em MiB
    esac
}

# Dimensionamento FrankenPHP: num_threads, workers e teto por CPU/memória.
# Sem num_threads o FrankenPHP serializa requisições (auto vira 0 no Octane).
configure_frankenphp_workers() {
    local cpus mem_mb php_mb max_by_memory

    cpus=$(available_cpus)

    # 2 workers por núcleo — o padrão do próprio FrankenPHP, e o que foi medido
    # aqui. Muito acima disso a carga é CPU-bound e só se troca vazão por troca
    # de contexto.
    FRANKENPHP_WORKER_NUM=${FRANKENPHP_WORKER_NUM:-$(( cpus * 2 ))}

    # Folga acima dos workers para o que NÃO passa pelo worker script. Sem ela,
    # worker e requisições comuns disputam as mesmas threads.
    FRANKENPHP_NUM_THREADS=${FRANKENPHP_NUM_THREADS:-$(( FRANKENPHP_WORKER_NUM + cpus ))}

    # Teto do autoscaling do FrankenPHP, para absorver pico sem manter as
    # threads vivas o tempo todo.
    FRANKENPHP_MAX_THREADS=${FRANKENPHP_MAX_THREADS:-$(( FRANKENPHP_NUM_THREADS * 2 ))}

    # Cada thread carrega uma instância do PHP: `max_threads * memory_limit` não
    # pode passar da memória do container, ou quem decide o dimensionamento
    # passa a ser o OOM-killer. 70% deixa espaço para OPcache, Caddy e o pico de
    # resposta, que vivem fora desse orçamento.
    mem_mb=$(container_memory_mb)
    php_mb=$(php_memory_limit_mb)

    if [ "$mem_mb" -gt 0 ] && [ "$php_mb" -gt 0 ]; then
        max_by_memory=$(( mem_mb * 70 / 100 / php_mb ))
        [ "$max_by_memory" -lt 1 ] && max_by_memory=1

        if [ "$FRANKENPHP_MAX_THREADS" -gt "$max_by_memory" ]; then
            log "INFO" "Teto de threads reduzido de ${FRANKENPHP_MAX_THREADS} para ${max_by_memory} pelo orçamento de memória (${mem_mb} MiB / ${php_mb} MiB por thread)"
            FRANKENPHP_MAX_THREADS=$max_by_memory
        fi

        # num_threads nunca acima do teto, e workers nunca acima de num_threads:
        # o FrankenPHP recusa a configuração se essa ordem for violada.
        [ "$FRANKENPHP_NUM_THREADS" -gt "$FRANKENPHP_MAX_THREADS" ] && FRANKENPHP_NUM_THREADS=$FRANKENPHP_MAX_THREADS

        # A folga de uma thread não-worker sobrevive ao corte por memória.
        # Sem ela o modo worker volta a disputar thread com o que não passa
        # pelo worker script — que é a forma como a serialização aparece.
        # Só num orçamento de uma thread só não há o que reservar.
        if [ "$FRANKENPHP_NUM_THREADS" -ge 2 ] && [ "$FRANKENPHP_WORKER_NUM" -ge "$FRANKENPHP_NUM_THREADS" ]; then
            FRANKENPHP_WORKER_NUM=$(( FRANKENPHP_NUM_THREADS - 1 ))
        fi
        [ "$FRANKENPHP_WORKER_NUM" -gt "$FRANKENPHP_NUM_THREADS" ] && FRANKENPHP_WORKER_NUM=$FRANKENPHP_NUM_THREADS
    fi

    # O Caddyfile lê estas duas; o `num` do worker vem do --workers do Octane.
    export FRANKENPHP_NUM_THREADS FRANKENPHP_MAX_THREADS

    log "INFO" "FrankenPHP: ${cpus} CPU(s), ${FRANKENPHP_WORKER_NUM} workers, ${FRANKENPHP_NUM_THREADS} threads (teto ${FRANKENPHP_MAX_THREADS})"
}

configure_frankenphp_workers

APP_COMMAND=${APP_COMMAND:-"$ARTISAN octane:start --server=frankenphp --host=0.0.0.0 --port=8000 --caddyfile=/etc/caddy/Caddyfile --workers=${FRANKENPHP_WORKER_NUM} --max-requests=${OCTANE_MAX_REQUESTS:-500}"}

# validate_timestamps=0 só em produção (bind mount em dev).
configure_php_runtime() {
    local ini='/usr/local/etc/php/conf.d/99-runtime.ini'

    if [ ! -w "$(dirname "$ini")" ]; then
        log "WARNING" "Sem permissão para ajustar o PHP em $(dirname "$ini")"
        return 0
    fi

    : > "$ini"

    if [ "$APP_ENV" = "production" ]; then
        echo 'opcache.validate_timestamps=0' >> "$ini"
        log "INFO" "OPcache em modo produção (validate_timestamps=0)"
    fi

    if [ -n "${OPCACHE_JIT_BUFFER_SIZE:-}" ] && [ "${OPCACHE_JIT_BUFFER_SIZE}" != "0" ]; then
        # O MODO junto do buffer: php/99-custom.ini traz `opcache.jit = disable`
        # para que o estado desligado seja legível num `php -i`. Só o buffer não
        # ligaria nada.
        echo "opcache.jit=${OPCACHE_JIT_MODE:-tracing}" >> "$ini"
        echo "opcache.jit_buffer_size=${OPCACHE_JIT_BUFFER_SIZE}" >> "$ini"
        log "INFO" "JIT habilitado com buffer de ${OPCACHE_JIT_BUFFER_SIZE}"
    fi
}

# Function to run setup tasks
run_setup_tasks() {
    log "INFO" "Preparing application..."
    if [ -w /var/www/html/storage ]; then
        chown -R www-data:www-data /var/www/html/storage
    else
        log "WARNING" "Insufficient permissions to change ownership of storage directory"
    fi

    $ARTISAN storage:link || log "WARNING" "Failed to create storage link"

    # Fora de produção o cache de config/rotas/eventos só atrapalha: o código
    # vem por bind mount e uma alteração em config/ ou routes/ ficaria invisível
    # até alguém rodar `optimize:clear` na mão. Classes e views já refletem
    # sozinhas — quem as segurava era este cache, não o OPcache.
    if [ "$APP_ENV" = "production" ]; then
        $ARTISAN optimize || log "WARNING" "Failed to optimize"
    else
        log "INFO" "APP_ENV=$APP_ENV: caches de config/rotas desligados para desenvolvimento"
        $ARTISAN optimize:clear || log "WARNING" "Failed to clear caches"
    fi
    # $ARTISAN filament:optimize || log "WARNING" "Failed to run filament optimize"
}

# Function to handle signals
trap 'log "INFO" "Stopping container..."; exit 0;' SIGTERM SIGINT

# Check if vendor directory exists
while [ ! -d "/var/www/html/vendor" ]; do
    log "WARNING" "The directory /var/www/html/vendor does not exist yet. Please run the \"composer install\" command to ensure that all necessary dependencies are properly installed."
    log "INFO" "Retrying in 300 seconds..."
    sleep 300s
done

# Check if artisan file exists
if [ ! -f "/var/www/html/artisan" ]; then
    log "ERROR" "The artisan file does not exist at /var/www/html/artisan. Please ensure the application is properly set up."
    exit 1
fi

configure_php_runtime

# Run setup tasks if enabled
if [ "$RUN_SETUP_TASKS" = "true" ]; then
    run_setup_tasks
fi

# Run migrations only if explicitly enabled
if [ "$RUN_MIGRATIONS" = "true" ]; then
    $ARTISAN migrate --force || log "WARNING" "Failed to run migrations"
fi

log "INFO" "Starting web server..."
exec $APP_COMMAND
