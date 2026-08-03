# laravel

## Papel

Imagens base das aplicações Laravel da BrasilDataHub. Os verticais (`baseempresarial`, `baseescolar`, `basehospitalar`, …) herdam estas imagens via `FROM` em vez de instalar PHP, extensões e runtime nos próprios Dockerfiles.

Este módulo **não** é um serviço: não há `docker-compose.yml`, `profiles/*.env`, entrada no `setup.sh`, `job_name` no Prometheus nem dashboard no Grafana. Limites, réplicas, volumes e variáveis de aplicação ficam no compose do projeto consumidor.

## Componentes / imagem

| Imagem | Base | Papel |
|---|---|---|
| `ghcr.io/brasildatahub/laravel-app:8.4` | `dunglas/frankenphp:1.12-php8.4-bookworm` | runtime **web** — Octane + Caddy |
| `ghcr.io/brasildatahub/laravel-worker:8.4` | `laravel-app` | runtime **worker** — fila, Horizon, scheduler, Reverb |
| `ghcr.io/brasildatahub/laravel-builder:8.4` | `laravel-app` + Node 22 | **build** — Composer e npm/Vite |

As 14 extensões PHP estão em [`php-extensions.txt`](php-extensions.txt), lido pelos dois runtimes. A paridade entre app e worker é verificada no CI.

| Na imagem (stack) | Na aplicação (projeto) |
|---|---|
| versão do PHP, FrankenPHP e Composer | `composer.json` / `composer.lock` |
| as 14 extensões PHP | `package.json` / `package-lock.json` |
| tuning do OPcache (`php/99-custom.ini`) | código, views, rotas |
| `Caddyfile` genérico de Octane | `public/frankenphp-worker.php` |
| entrypoints (web e worker) | `public/build` gerado pelo Vite |
| `curl`, `unzip`, `sqlite3`/`sqlite` | `public/version.json` |
| `WORKDIR /var/www/html`, `EXPOSE 8000`, healthcheck | limites de memória e CPU, réplicas |

O worker deriva de `laravel-app` (PHP ZTS). As três imagens publicam `linux/amd64` e `linux/arm64`. Tags: `:8.4` (revisão corrente) e `:8.4-rN` (imutável) — ver [docs/versionamento.md](docs/versionamento.md).

## Perfis e configuração

Não há perfis `.env`. O dimensionamento de workers do FrankenPHP é calculado no entrypoint a partir do cgroup (CPU e memória do container). Valores definidos por env sobrescrevem o cálculo.

Uso típico na aplicação:

```dockerfile
FROM ghcr.io/brasildatahub/laravel-builder:8.4 AS builder
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-interaction --no-dev --no-scripts --no-autoloader
COPY package.json package-lock.json .npmrc ./
RUN npm ci
COPY . .
RUN npm run build

FROM ghcr.io/brasildatahub/laravel-app:8.4
WORKDIR /var/www/html
COPY --from=builder /app/vendor ./vendor
COPY . .
COPY --from=builder /app/public/build ./public/build
RUN composer dump-autoload --optimize --no-dev --no-interaction \
    && chown -R www-data:www-data storage
```

Worker: `FROM ghcr.io/brasildatahub/laravel-worker:8.4`, `composer install`, `COPY . .`, `dump-autoload`.

Detalhes e Dockerfiles prontos: [docs/uso-em-novas-aplicacoes.md](docs/uso-em-novas-aplicacoes.md).

## Deploy / operação

```bash
bash build.sh laravel            # as três, arquitetura nativa, sem publicar
bash build.sh laravel-app        # só a base
bash build.sh laravel --push     # multi-arch no GHCR, mesmas tags do CI
```

O script lê contexto, Dockerfile, plataformas e tags de `build-publish.yml`. Ver `bash build.sh --help`.

```bash
bash laravel/test/laravel-images.test.sh
```

Afirma: paridade de extensões app/worker, diretivas de `99-custom.ini`, Composer, entrypoints, `Caddyfile`, `bash` no worker, PHP ZTS nos dois runtimes, dimensionamento FrankenPHP e Node 22 no builder. Gate do CI e do `build.sh` local.

Conferir workers/threads após subir:

```bash
docker exec <container> curl -s http://127.0.0.1:2019/config/ \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['apps']['frankenphp'])"
```

Deve trazer `num_threads`, `max_threads` e `workers[0].num`. Sem `num`, o FrankenPHP serializa em uma thread.

## Variáveis e segredos

Nenhuma é obrigatória para a imagem subir; defaults são de produção.

### Comuns aos dois runtimes

| Variável | Default | O que controla |
|---|---|---|
| `APP_ENV` | `production` | em `production`: `opcache.validate_timestamps=0` + `artisan optimize`; fora: `optimize:clear` |
| `RUN_SETUP_TASKS` | `true` | `storage:link` + `optimize`/`optimize:clear` no start |
| `RUN_MIGRATIONS` | `false` | `artisan migrate --force` no start |
| `ARTISAN` | `php -d variables_order=EGPCS /var/www/html/artisan` | invocação do artisan |
| `OPCACHE_JIT_BUFFER_SIZE` | vazio (JIT desligado) | liga o JIT sem rebuild |
| `OPCACHE_JIT_MODE` | `tracing` | modo do JIT |

### Só no `laravel-app`

| Variável | Default | O que controla |
|---|---|---|
| `APP_COMMAND` | `artisan octane:start --server=frankenphp … --workers=<calculado> --max-requests=500` | processo do container |
| `FRANKENPHP_WORKER_NUM` | `2 × CPU` | threads do worker script |
| `FRANKENPHP_NUM_THREADS` | `workers + CPU` | total de threads PHP |
| `FRANKENPHP_MAX_THREADS` | `2 × num_threads`, limitado pela memória | teto do autoscaling |
| `OCTANE_MAX_REQUESTS` | `500` | requisições por worker antes do reciclo |
| `CADDY_SERVER_SERVER_NAME` | `:8000` | endereço do Caddy |
| `CADDY_SERVER_LOG_LEVEL` | `warn` | verbosidade do log de acesso |
| `CADDY_SERVER_WATCH_DIRECTIVES` | vazio | reinício ao mudar arquivo (dev) |
| `CADDY_SERVER_EXTRA_DIRECTIVES`, `CADDY_EXTRA_CONFIG`, `CADDY_GLOBAL_OPTIONS` | vazio | extensão do Caddyfile |
| `CADDY_SERVER_ADMIN_PORT` | `2019` | API admin do Caddy |

`APP_PUBLIC_PATH` não se define: o Octane a injeta ao subir o Caddy.

Sem `FRANKENPHP_NUM_THREADS` / `num` no Caddyfile, o Octane com `--workers=auto` deixa de definir `num` e o FrankenPHP mantém uma única thread. Passar só `--workers=N` não basta — é o `num_threads` global que distribui a carga.

### Só no `laravel-worker`

| Variável | Default | O que controla |
|---|---|---|
| `CONTAINER_ROLE` | `worker` | `worker`, `horizon`, `scheduler` ou `reverb` |
| `SCHEDULER_MODE` | `run` | `run` (única) ou `loop` (a cada 60 s) |
| `WORKER_COMMAND` | `artisan queue:work -vv --tries=3 --sleep=5 --timeout=300 --delay=10` | papel `worker` |
| `HORIZON_COMMAND` | `artisan horizon` | papel `horizon` |
| `SCHEDULER_COMMAND` | `artisan schedule:run --no-interaction` | papel `scheduler` |

## Restrições

- Worker herda `EXPOSE 8000` e o binário FrankenPHP (inertes no processo de fila).
- `FRANKENPHP_*` devem refletir o cgroup do container, não o host (`nproc` enxerga o host inteiro).
- Builder deriva do app: mesmo PHP e mesmas extensões — o `vendor/` do builder serve como vendor de produção.

## Links

- [docs/uso-em-novas-aplicacoes.md](docs/uso-em-novas-aplicacoes.md)
- [docs/versionamento.md](docs/versionamento.md)
- [`php-extensions.txt`](php-extensions.txt)
