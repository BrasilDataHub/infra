# Usando as imagens base numa aplicação

Receita para vertical novo (Laravel/Octane) ou migração. Imagens públicas no
GHCR — `docker pull` sem autenticação.

## O que a aplicação precisa

| Arquivo | Por quê |
|---|---|
| `composer.json` + `composer.lock` | dependências PHP; lock = build reprodutível |
| `package.json` + `package-lock.json` | toolchain Vite |
| `public/frankenphp-worker.php` | Octane (`artisan octane:install --server=frankenphp`) |
| `artisan` | entrypoint aborta sem ele |
| `.dockerignore` | sem ele o contexto vai a centenas de MB |

## O que apagar na migração

Moram na imagem base:

- `docker/Caddyfile`
- `docker/conf.d/custom.ini`
- `docker/entrypoint.sh`
- `docker/entrypoint-worker.sh`

## `docker/Dockerfile`

```dockerfile
ARG BASE_TAG=8.4-r3

FROM ghcr.io/brasildatahub/laravel-builder:${BASE_TAG} AS builder
WORKDIR /app

COPY composer.json composer.lock ./
RUN composer install --no-interaction --no-dev --no-scripts --no-autoloader

# Se não houver `.npmrc`, tire-o desta linha — COPY de arquivo inexistente falha.
COPY package.json package-lock.json .npmrc ./
RUN npm ci

COPY . .
RUN npm run build

FROM ghcr.io/brasildatahub/laravel-app:${BASE_TAG}
WORKDIR /var/www/html

COPY --from=builder /app/vendor ./vendor
COPY . .
COPY --from=builder /app/public/build ./public/build

RUN composer dump-autoload --optimize --no-dev --no-interaction \
    && chown -R www-data:www-data storage

# POR ÚLTIMO: ARGs mudam a cada commit e invalidariam camadas acima.
ARG GIT_REF
ARG GIT_SHA
ARG BUILD_TIMESTAMP
RUN set -eux; \
    VERSION=$(echo "${GIT_REF}" | sed -e 's,.*/\(.*\),\1,'); \
    if echo "${GIT_REF}" | grep -q '^refs/tags/'; then \
        VERSION=$(echo "${VERSION}" | sed -e 's/^v//'); \
    fi; \
    if [ "${VERSION}" = "main" ] || [ "${VERSION}" = "merge" ]; then \
        VERSION=edge; \
    fi; \
    if [ -z "${BUILD_TIMESTAMP:-}" ]; then \
        BUILD_TIMESTAMP=$(TZ=UTC date '+%Y-%m-%d %H:%M:%S %Z'); \
    fi; \
    SHORT_SHA=$(printf '%s' "${GIT_SHA:-}" | cut -c1-7); \
    printf '{"version": "%s", "build": "%s", "commit": "%s", "dockerImage": "true"}' \
        "${VERSION}" "${BUILD_TIMESTAMP}" "${SHORT_SHA}" > public/version.json
```

Não repetir `ENTRYPOINT`, `EXPOSE`, `HEALTHCHECK` nem `Caddyfile` — vêm da base.
Sem `--ignore-platform-reqs`: extensão faltante quebra o build, não a produção.

## `docker/Dockerfile.worker`

```dockerfile
ARG BASE_TAG=8.4-r3

FROM ghcr.io/brasildatahub/laravel-worker:${BASE_TAG}
WORKDIR /var/www/html

COPY composer.json composer.lock ./
RUN composer install --no-interaction --no-dev --no-scripts --no-autoloader

COPY . .
RUN composer dump-autoload --optimize --no-dev --no-interaction \
    && chown -R www-data:www-data storage

ARG GIT_REF
ARG GIT_SHA
ARG BUILD_TIMESTAMP
RUN set -eux; \
    ... # mesmo bloco de version.json do Dockerfile acima
```

O worker deriva de `laravel-app` (mesmo PHP/extensões que o builder). Caminho
aberto nos verticais: copiar `vendor` do builder como no Dockerfile web
(`COPY --from=builder /app/vendor ./vendor`), acrescentando estágio `builder`.

## `docker-compose.yml`

```yaml
  worker:
    build: { context: ., dockerfile: docker/Dockerfile.worker }
    environment:
      CONTAINER_ROLE: horizon

  scheduler:
    build: { context: ., dockerfile: docker/Dockerfile.worker }
    environment:
      CONTAINER_ROLE: scheduler
      SCHEDULER_MODE: loop
```

Limites de memória/CPU/réplicas = decisão do projeto.

## `.dockerignore`

```
vendor
node_modules
public/build
public/hot
.git
.env
.env.*
!.env.example
```

- `vendor` / `node_modules` fora do contexto (reconstruídos no builder).
- `*.md` no Docker não atravessa `/` — `resources/markdown/` permanece se
  necessário em runtime.
- Com `l5-swagger` e `generate_always = false`, **não** ignore
  `storage/api-docs` — a rota `/docs` serve o JSON versionado.

## Verificação

```bash
docker compose build
docker compose up -d
curl -f localhost:8000/up
docker compose exec app php artisan about
```

Checklist de migração: página pública **com CSS**; Horizon e scheduler nos
logs; `php -m` com as 14 extensões. Extensão nova →
[`php-extensions.txt`](../php-extensions.txt) + revisão nova da imagem, não no
Dockerfile do projeto.
