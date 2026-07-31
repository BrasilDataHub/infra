# Usando as imagens base numa aplicação

Receita para um vertical novo — Base Escolar, Base Hospitalar ou qualquer
aplicação Laravel/Octane da organização — e para migrar uma existente.

As imagens são **públicas** no GHCR: `docker pull` sem autenticação, e nenhuma
credencial de registry no ambiente de deploy.

## O que a aplicação precisa ter

| Arquivo | Por quê |
|---|---|
| `composer.json` + `composer.lock` | as dependências PHP; o `lock` é o que torna o build reprodutível |
| `package.json` + `package-lock.json` | a toolchain do Vite |
| `public/frankenphp-worker.php` | ponto de entrada do Octane; gerado por `artisan octane:install --server=frankenphp` |
| `artisan` | o entrypoint aborta sem ele |
| `.dockerignore` | sem ele o contexto vai a centenas de MB |

## O que a aplicação **não** precisa mais ter

Estes vinham no repositório de cada projeto e agora moram na imagem base.
Apague-os ao migrar:

- `docker/Caddyfile`
- `docker/conf.d/custom.ini`
- `docker/entrypoint.sh`
- `docker/entrypoint-worker.sh`

## `docker/Dockerfile` — a aplicação web

```dockerfile
ARG BASE_TAG=8.4-r1

FROM ghcr.io/brasildatahub/laravel-builder:${BASE_TAG} AS builder
WORKDIR /app

# Dependências antes do código, nos dois gerenciadores: mudar um .blade.php não
# pode invalidar nem o vendor nem o node_modules.
COPY composer.json composer.lock ./
RUN composer install --no-interaction --no-dev --no-scripts --no-autoloader

# `.npmrc` traz `ignore-scripts=true`. Se o projeto não tiver o arquivo, tire-o
# desta linha — um `COPY` de arquivo inexistente falha o build.
COPY package.json package-lock.json .npmrc ./
RUN npm ci

COPY . .
RUN npm run build

FROM ghcr.io/brasildatahub/laravel-app:${BASE_TAG}
WORKDIR /var/www/html

# O vendor vem PRONTO do builder. Ele deriva desta mesma imagem, então tem o
# mesmo PHP e as mesmas extensões — não há segundo `composer install`.
COPY --from=builder /app/vendor ./vendor
COPY . .
COPY --from=builder /app/public/build ./public/build

# Sem --ignore-platform-reqs: extensão faltante quebra o build, não a produção.
# É aqui que os scripts do Laravel (package:discover) rodam.
RUN composer dump-autoload --optimize --no-dev --no-interaction \
    && chown -R www-data:www-data storage

# POR ÚLTIMO, e isso importa: estes ARGs mudam a cada commit. Em qualquer
# posição acima, invalidariam todas as camadas seguintes — inclusive o
# dump-autoload, que é caro.
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

Não é preciso repetir `ENTRYPOINT`, `EXPOSE`, `HEALTHCHECK` nem copiar o
`Caddyfile`: tudo vem da base.

## `docker/Dockerfile.worker`

```dockerfile
ARG BASE_TAG=8.4-r1

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

O worker roda o próprio `composer install` em vez de copiar o `vendor/` do
builder: o builder é Debian/glibc e o worker é Alpine/musl. O `vendor` do
Composer é PHP puro e na prática funcionaria, mas reinstalar preserva a
garantia sem depender dessa suposição — e o custo é baixo perto do que já se
economizou nas extensões.

## `docker-compose.yml`

Nada muda em relação ao formato que os projetos já usam: `context: .`,
`dockerfile: docker/Dockerfile` (ou `.worker`), e os papéis do worker escolhidos
por `CONTAINER_ROLE`:

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

Limites de memória, CPU e réplicas continuam sendo decisão do projeto — a
imagem base não opina sobre dimensionamento, pela mesma razão que
`ghcr.io/brasildatahub/postgres` não embute `shared_buffers`.

## `.dockerignore` recomendado

O ponto de partida é o do Base Empresarial. Três itens merecem atenção porque
já causaram problema:

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

- **`vendor` e `node_modules` fora do contexto** — são reconstruídos no builder;
  mandá-los ao daemon é o que fazia o contexto passar de 370 MB.
- **`*.md` só alcança a raiz do contexto**: no Docker o `*` não atravessa `/`.
  É o que mantém `resources/markdown/` na imagem, se o projeto servir conteúdo
  de lá em runtime.
- **Se o projeto usa `l5-swagger` com `generate_always = false`**, `storage/api-docs`
  **não** pode entrar no `.dockerignore`: o JSON versionado é o que a rota
  `/docs` serve em produção.

## Verificando a adoção

```bash
docker compose build
docker compose up -d
curl -f localhost:8000/up
docker compose exec app php artisan about
```

E o que de fato costuma quebrar numa migração:

- uma página pública renderizando **com CSS** — prova que `public/build` chegou
  à imagem;
- `docker compose logs worker` mostrando o Horizon de pé;
- `docker compose logs scheduler` mostrando o loop de 60 s;
- `php -m` com as 14 extensões, se o projeto depender de alguma além delas.

Se a aplicação precisar de uma extensão que não está em
[`php-extensions.txt`](../php-extensions.txt), acrescente-a **lá** e publique
uma revisão nova — não a instale no Dockerfile do projeto. Uma extensão
instalada por fora reintroduz exatamente a divergência entre verticais que
estas imagens existem para eliminar.
