# Runtime web das aplicações Laravel da BrasilDataHub
# (ghcr.io/brasildatahub/laravel-app): FrankenPHP + Octane.
#
# Mesma divisão dos demais módulos do repositório: o que é DECISÃO DE STACK vai
# na imagem — versão do PHP, extensões, tuning do OPcache, Caddyfile, entrypoint
# —, e o que é APLICAÇÃO vem do projeto que herda daqui: composer.json, código,
# assets compilados e o public/frankenphp-worker.php.
#
# Por que a imagem existe: até julho/2026 cada projeto carregava um Dockerfile
# de 107 linhas que instalava as 14 extensões do zero a cada build sem cache —
# de longe a camada mais cara, e a que menos muda. Pior, o worker repetia a
# mesma instalação numa distribuição diferente. Aqui a camada é construída uma
# vez, publicada, e todos os verticais (baseempresarial, baseescolar,
# basehospitalar, ...) fazem `docker pull` dela.
#
# O que esta imagem NÃO faz, deliberadamente:
# - não roda `composer install`: a aplicação traz o próprio composer.lock;
# - não define usuário não-root. O processo roda como root, como antes desta
#   refatoração. Mudar isso alteraria o dono dos arquivos em bind mount de
#   desenvolvimento, e é decisão de outra tarefa;
# - não fixa APP_PUBLIC_PATH: quem a define é o próprio Octane, ao subir o
#   Caddy (laravel/octane, StartFrankenPhpCommand). O Caddyfile daqui a lê.

# Todas as versões num bloco só, e ANTES do primeiro FROM: um ARG declarado
# depois de um FROM pertence àquele estágio e não é visível nos FROM seguintes,
# que é como se chega ao erro "invalid reference format" com a tag vazia.
#
# A minor do FrankenPHP é pinada — a tag `1` que se usava antes trocava de Caddy
# e de PHP sem que nenhum arquivo do repositório mudasse, o que é o oposto do
# que uma imagem base deve oferecer aos projetos que dependem dela.
ARG FRANKENPHP_VERSION=1.12
ARG PHP_VERSION=8.4
ARG COMPOSER_VERSION=2

# O Composer entra por um estágio nomeado, e não por um `COPY --from=composer:2`
# direto, porque o `--from` de um COPY não aceita expansão de variável: a versão
# só pode ser um ARG se ela aparecer num FROM.
FROM composer:${COMPOSER_VERSION} AS composer

FROM dunglas/frankenphp:${FRANKENPHP_VERSION}-php${PHP_VERSION}-bookworm

# A lista de extensões é um ARQUIVO, e o mesmo arquivo alimenta o
# Dockerfile.worker. A justificativa de cada grupo está lá dentro.
COPY php-extensions.txt /tmp/php-extensions.txt
RUN install-php-extensions $(grep -vE '^[[:space:]]*(#|$)' /tmp/php-extensions.txt | tr '\n' ' ') \
    && rm /tmp/php-extensions.txt

# `curl` sustenta o HEALTHCHECK abaixo; `unzip` é usado pelo Composer ao
# instalar de dist; `sqlite3` é o cliente de linha de comando, útil para
# inspecionar o banco da suíte de testes dentro do container.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# O Composer entra na imagem de RUNTIME, e não só na de build, porque o
# `composer dump-autoload` da aplicação roda neste estágio — é ele que gera o
# autoload otimizado com as extensões reais presentes, de modo que uma extensão
# faltante quebre o build em vez de a produção.
COPY --from=composer /usr/bin/composer /usr/local/bin/composer

# Tuning de PHP que é decisão medida da organização (JIT desligado, buffer de
# strings internas em 32 MB, opcache.enable_cli para o Horizon). Os números e o
# porquê estão dentro do arquivo.
COPY php/99-custom.ini /usr/local/etc/php/conf.d/99-custom.ini

# Caddyfile genérico de Octane: root, compressão, cache imutável em /build e os
# pontos de extensão por variável de ambiente (CADDY_SERVER_EXTRA_DIRECTIVES,
# CADDY_EXTRA_CONFIG, CADDY_SERVER_WATCH_DIRECTIVES). Um projeto que precise de
# mais do que isso sobrescreve o arquivo no próprio Dockerfile.
COPY caddy/Caddyfile /etc/caddy/Caddyfile

WORKDIR /var/www/html

COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint"]

# `/up` é a rota de health do Laravel. O start-period cobre o `artisan optimize`
# que o entrypoint roda antes de subir o servidor.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8000/up || exit 1

EXPOSE 8000
