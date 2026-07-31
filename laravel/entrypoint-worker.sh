#!/bin/bash

set -e

# Set default values if not provided
RUN_SETUP_TASKS=${RUN_SETUP_TASKS:-'true'}
RUN_MIGRATIONS=${RUN_MIGRATIONS:-'false'}
CONTAINER_ROLE=${CONTAINER_ROLE:-'worker'}
SCHEDULER_MODE=${SCHEDULER_MODE:-'run'}
APP_ENV=${APP_ENV:-'production'}

ARTISAN=${ARTISAN:-"php -d variables_order=EGPCS /var/www/html/artisan"}
WORKER_COMMAND=${WORKER_COMMAND:-"$ARTISAN queue:work -vv --no-interaction --tries=3 --sleep=5 --timeout=300 --delay=10"}
HORIZON_COMMAND=${HORIZON_COMMAND:-"$ARTISAN horizon"}
SCHEDULER_COMMAND=${SCHEDULER_COMMAND:-"$ARTISAN schedule:run --no-interaction"}

# Function to log messages
log() {
    local type="$1"
    local message="$2"
    echo "[$type] $message"
}

# Ajustes de PHP que dependem do ambiente — mesma lógica do entrypoint da
# aplicação. validate_timestamps=0 só em produção, porque em desenvolvimento o
# código vem por bind mount e o worker deixaria de ver alterações.
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

    # Clear stale compiled views before optimize to prevent hash_file() errors.
    # When multiple containers share the same volume (e.g. in development), the
    # view:cache step inside optimize can fail with "No such file or directory"
    # due to a race condition: one container deletes compiled views while another
    # is trying to hash them. Clearing views first ensures a clean state.
    $ARTISAN view:clear --quiet || true

    # Mesma regra do entrypoint da aplicação: em desenvolvimento o cache de
    # config/rotas esconderia alterações feitas no host, que chegam por bind
    # mount. Ver entrypoint.sh.
    if [ "$APP_ENV" = "production" ]; then
        $ARTISAN optimize || log "WARNING" "Failed to optimize"
    else
        log "INFO" "APP_ENV=$APP_ENV: caches de config/rotas desligados para desenvolvimento"
        $ARTISAN optimize:clear || log "WARNING" "Failed to clear caches"
    fi
}

# Function to run scheduler command and log output
run_scheduler() {
    case "$SCHEDULER_MODE" in
        loop)
            while true; do
                log "INFO" "Running scheduled tasks."
                if $SCHEDULER_COMMAND 2>&1; then
                    log "INFO" "Scheduled tasks completed successfully."
                else
                    log "ERROR" "Failed to run scheduled tasks"
                fi
                sleep 60s
            done
            ;;
        run)
            log "INFO" "Running scheduled tasks (single execution)."
            if $SCHEDULER_COMMAND 2>&1; then
                log "INFO" "Scheduled tasks completed successfully."
                exit 0
            else
                log "ERROR" "Failed to run scheduled tasks"
                exit 1
            fi
            ;;
        *)
            log "ERROR" "Unknown scheduler mode: \"$SCHEDULER_MODE\". Use 'loop' or 'run'."
            exit 1
            ;;
    esac
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

# Execute role-specific commands
case "$CONTAINER_ROLE" in
    worker)
        log "INFO" "Starting queue worker..."
        exec $WORKER_COMMAND
        ;;
    horizon)
        log "INFO" "Starting Horizon..."
        exec $HORIZON_COMMAND
        ;;
    scheduler)
        log "INFO" "Starting scheduler..."
        run_scheduler
        ;;
    reverb)
        log "INFO" "Starting Reverb WebSocket server..."
        exec $ARTISAN reverb:start --host=0.0.0.0 --port=8080
        ;;
    *)
        log "ERROR" "Unknown container role: \"$CONTAINER_ROLE\""
        exit 1
        ;;
esac
