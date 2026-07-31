#!/bin/bash

set -e

# Set default values if not provided
RUN_SETUP_TASKS=${RUN_SETUP_TASKS:-'true'}
RUN_MIGRATIONS=${RUN_MIGRATIONS:-'false'}
APP_ENV=${APP_ENV:-'production'}

ARTISAN=${ARTISAN:-"php -d variables_order=EGPCS /var/www/html/artisan"}
APP_COMMAND=${APP_COMMAND:-"$ARTISAN octane:start --server=frankenphp --host=0.0.0.0 --port=8000 --caddyfile=/etc/caddy/Caddyfile"}

# Function to log messages
log() {
    local type="$1"
    local message="$2"
    echo "[$type] $message"
}

# Ajustes de PHP que dependem do ambiente e por isso não cabem no ini da imagem.
#
# validate_timestamps=0 elimina um stat() por arquivo incluído, mas faz o PHP
# ignorar alterações no código até reiniciar — correto em produção, onde a
# imagem é imutável, e péssimo em desenvolvimento, onde o código vem por bind
# mount. Por isso o valor é escrito aqui, e não em php/99-custom.ini.
#
# O buffer do JIT fica em variável de ambiente para poder ser medido em
# produção sem rebuild (0 = desligado, que é o padrão medido como melhor).
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
