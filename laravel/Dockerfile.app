# Runtime web Laravel (ghcr.io/brasildatahub/laravel-app): FrankenPHP + Octane.
#
# Stack fixa na imagem; aplicação vem do projeto que herda (composer, código, assets).
# Não roda composer install, não fixa APP_PUBLIC_PATH, não define usuário não-root.

# Versões antes do primeiro FROM — ARG após FROM não é visível nos estágios seguintes.
ARG FRANKENPHP_VERSION=1.12
ARG PHP_VERSION=8.4
ARG COMPOSER_VERSION=2

FROM composer:${COMPOSER_VERSION} AS composer

FROM dunglas/frankenphp:${FRANKENPHP_VERSION}-php${PHP_VERSION}-bookworm

# Mesma lista alimenta Dockerfile.worker (php-extensions.txt).
COPY php-extensions.txt /tmp/php-extensions.txt
RUN install-php-extensions $(grep -vE '^[[:space:]]*(#|$)' /tmp/php-extensions.txt | tr '\n' ' ') \
    && rm /tmp/php-extensions.txt

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# Composer no runtime: dump-autoload com extensões reais presentes.
COPY --from=composer /usr/bin/composer /usr/local/bin/composer

COPY php/99-custom.ini /usr/local/etc/php/conf.d/99-custom.ini
COPY caddy/Caddyfile /etc/caddy/Caddyfile

WORKDIR /var/www/html

COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8000/up || exit 1

EXPOSE 8000
