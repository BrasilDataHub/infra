# laravel

Imagens base das aplicações Laravel da BrasilDataHub — a camada que os
verticais (`baseempresarial`, `baseescolar`, `basehospitalar`, …) herdam em vez
de reconstruir.

| Imagem | Base | Papel |
|---|---|---|
| `ghcr.io/brasildatahub/laravel-app:8.4` | `dunglas/frankenphp:1.12-php8.4-bookworm` | runtime **web** — Octane + Caddy |
| `ghcr.io/brasildatahub/laravel-worker:8.4` | `laravel-app` | runtime **worker** — fila, Horizon, scheduler, Reverb |
| `ghcr.io/brasildatahub/laravel-builder:8.4` | `laravel-app` + Node 22 | **build** — Composer e npm/Vite |

## Por que elas existem

Até julho de 2026 cada projeto carregava um `Dockerfile` de 107 linhas e um
`Dockerfile.worker` de 73 que instalavam **as mesmas 14 extensões PHP** em
distribuições diferentes. Num runner sem cache — que é o caso de todo build
limpo — essa camada é de longe a mais cara do build, e é a que menos muda. Era
construída duas vezes por projeto, e seria construída duas vezes por vertical.

Além do custo, havia o risco: duas listas mantidas à mão, uma no Dockerfile do
app e outra no do worker. Nada as obrigava a concordar, e uma divergência não
aparece no build — aparece como job de fila estourando `Class not found`, com o
container web funcionando perfeitamente ao lado.

Aqui a lista é **um arquivo**, [`php-extensions.txt`](php-extensions.txt), lido
pelos dois runtimes, e a paridade entre eles é afirmada no CI antes de qualquer
publicação.

### O que mudou, medido

Build limpo (`docker builder prune -af` antes de cada um, `--no-cache`) das duas
imagens do Base Empresarial, no mesmo host (Apple Silicon, OrbStack):

| | antes | depois | |
|---|---|---|---|
| imagem web | 83 s | **21 s** | −75% |
| imagem worker | 92 s | **13 s** | −84% |
| **total** | **175 s** | **34 s** | **−81%** |
| tamanho da imagem web | 1,38 GB | **1,14 GB** | −240 MB |
| tamanho da imagem worker | 925 MB | **704 MB** | −221 MB |
| instruções no Dockerfile web | 71 | **32** | −55% |
| instruções no Dockerfile worker | 55 | **24** | −56% |

O "depois" tem as imagens base presentes no host, que é o cenário real: elas
chegam por `docker pull` e não são reconstruídas a cada deploy. O tempo que
sumiu é o de instalar as 14 extensões duas vezes.

Os tamanhos caem porque o segundo `composer install` deixou de existir e o
contexto passou a ser copiado duas vezes em vez de três — camadas que antes
guardavam cópias do mesmo conteúdo.

## O que vai na imagem e o que vem da aplicação

Mesma divisão dos demais módulos do repositório.

| Na imagem (decisão de stack) | Na aplicação (decisão de projeto) |
|---|---|
| versão do PHP, do FrankenPHP e do Composer | `composer.json` / `composer.lock` |
| as 14 extensões PHP | `package.json` / `package-lock.json` |
| tuning do OPcache (`php/99-custom.ini`) | código, views, rotas |
| `Caddyfile` genérico de Octane | `public/frankenphp-worker.php` |
| entrypoints (web e worker) | `public/build` gerado pelo Vite |
| `curl`, `unzip`, `sqlite3`/`sqlite` | `public/version.json` |
| `WORKDIR /var/www/html`, `EXPOSE 8000`, healthcheck | limites de memória e CPU, réplicas |

## Este módulo não é um serviço

Diferente de `postgres/`, `redis/` ou `opensearch/`, aqui **não há**
`docker-compose.yml`, `profiles/*.env`, entrada no `setup.sh`, `job_name` no
Prometheus nem dashboard no Grafana. A ausência é deliberada, não esquecimento:
uma imagem base não sobe sozinha e não é provisionada numa VPS — ela é herdada
por um `FROM` no Dockerfile de uma aplicação. Quem define limites, réplicas,
volumes e variáveis é o compose **do projeto** que a consome.

## Como uma aplicação usa

O caminho completo, com os dois Dockerfiles prontos para copiar, está em
[docs/uso-em-novas-aplicacoes.md](docs/uso-em-novas-aplicacoes.md). Em resumo:

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

O worker é ainda mais curto — `FROM ghcr.io/brasildatahub/laravel-worker:8.4`,
`composer install`, `COPY . .`, `dump-autoload`.

**O builder deriva do app**, e isso é o que faz o `vendor/` gerado nele servir
como vendor de produção: mesmo PHP, mesmas extensões. Foi o que permitiu
eliminar o segundo `composer install` e o `--ignore-platform-reqs`, que existia
apenas porque o antigo estágio `composer:2` não tinha as extensões do projeto.

## Variáveis de ambiente

Lidas pelos entrypoints em tempo de execução. Nenhuma precisa ser definida para
a imagem subir; os defaults são os de produção.

### Comuns aos dois runtimes

| Variável | Default | O que controla |
|---|---|---|
| `APP_ENV` | `production` | em `production` liga `opcache.validate_timestamps=0` e roda `artisan optimize`; fora dele roda `optimize:clear`, porque o código chega por bind mount |
| `RUN_SETUP_TASKS` | `true` | `storage:link` + `optimize`/`optimize:clear` no start |
| `RUN_MIGRATIONS` | `false` | `artisan migrate --force` no start |
| `ARTISAN` | `php -d variables_order=EGPCS /var/www/html/artisan` | como o artisan é invocado |
| `OPCACHE_JIT_BUFFER_SIZE` | vazio (JIT desligado) | liga o JIT sem rebuild, para remedição |
| `OPCACHE_JIT_MODE` | `tracing` | modo do JIT, escrito junto do buffer |

### Só no `laravel-app`

| Variável | Default | O que controla |
|---|---|---|
| `APP_COMMAND` | `artisan octane:start --server=frankenphp … --workers=<calculado> --max-requests=500` | o processo do container |
| `FRANKENPHP_WORKER_NUM` | `2 × CPU` | threads que servem o worker script |
| `FRANKENPHP_NUM_THREADS` | `workers + CPU` | total de threads PHP do processo |
| `FRANKENPHP_MAX_THREADS` | `2 × num_threads`, limitado pela memória | teto do autoscaling de threads |
| `OCTANE_MAX_REQUESTS` | `500` | requisições por worker antes do reciclo |
| `CADDY_SERVER_SERVER_NAME` | `:8000` | endereço em que o Caddy escuta |
| `CADDY_SERVER_LOG_LEVEL` | `warn` | verbosidade do log de acesso |
| `CADDY_SERVER_WATCH_DIRECTIVES` | vazio | reinício automático do worker Octane ao mudar arquivo — só faz sentido em desenvolvimento |
| `CADDY_SERVER_EXTRA_DIRECTIVES`, `CADDY_EXTRA_CONFIG`, `CADDY_GLOBAL_OPTIONS` | vazio | pontos de extensão do Caddyfile |
| `CADDY_SERVER_ADMIN_PORT` | `2019` | porta da API admin do Caddy |

`APP_PUBLIC_PATH` **não** se define: quem a injeta é o próprio Octane ao subir
o Caddy, e o Caddyfile da imagem a lê de lá.

#### Os três `FRANKENPHP_*`, e por que existem

Nenhum precisa ser definido: o entrypoint calcula os três a partir da CPU e da
memória que o container **realmente** tem — lê o cgroup, e não `nproc`, que
enxerga o host inteiro e faria um container de 2 CPUs num host de 8 abrir quatro
vezes mais worker do que consegue executar. O que ficar definido por fora vence
o cálculo. A escolha vai na primeira linha do boot:

```
[INFO] FrankenPHP: 2 CPU(s), 4 workers, 6 threads (teto 12)
```

Existem porque, sem elas, **a aplicação atendia uma requisição por vez**. O
Octane sobe com `--workers=auto`; `auto` vira `0` em
`StartFrankenPhpCommand::workerCount()`, e com 0 a diretiva `num` fica **fora**
do Caddyfile. Sem `num` e sem `num_threads` global, o FrankenPHP mantém uma
única thread ativa e serializa tudo.

Diagnosticado no Base Empresarial em 01/08/2026, em produção, sob carga
sustentada de 10 conexões por 30 s: a thread `php-0` acumulou 22,4 s de CPU e as
outras quatro **não se moveram um único tick**, com mais de um núcleo ocioso o
tempo inteiro. Trinta requisições paralelas viraram uma escada linear de 1,84 s
a 3,32 s — a assinatura de uma fila com um servidor só.

Passar apenas `--workers=N` **não resolve**: foi testado com `num: 4` presente no
config e o comportamento não mudou. É o `num_threads` do bloco global que
destrava a distribuição — por isso ele vive no Caddyfile desta imagem.

Medido no mesmo host, mesma imagem, mesmo banco, 2 vCPUs:

| Concorrência | 1 worker (antes) | 4 workers (depois) | |
|---|---|---|---|
| 4 | p50 1,107 s · 25,9 req/s | **p50 0,291 s · 65,7 req/s** | p50 −74% |
| 10 | p50 1,720 s · 19,9 req/s | **p50 0,620 s · 37,9 req/s** | p50 −64% |

Como conferir depois de subir, em qualquer projeto:

```bash
docker exec <container> curl -s http://127.0.0.1:2019/config/ \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['apps']['frankenphp'])"
```

Tem de trazer `num_threads`, `max_threads` e `workers[0].num`. Se `num` vier
ausente, a imagem voltou ao comportamento de uma thread.

### Só no `laravel-worker`

| Variável | Default | O que controla |
|---|---|---|
| `CONTAINER_ROLE` | `worker` | `worker`, `horizon`, `scheduler` ou `reverb` |
| `SCHEDULER_MODE` | `run` | `run` (execução única) ou `loop` (a cada 60 s) |
| `WORKER_COMMAND` | `artisan queue:work -vv --tries=3 --sleep=5 --timeout=300 --delay=10` | comando do papel `worker` |
| `HORIZON_COMMAND` | `artisan horizon` | comando do papel `horizon` |
| `SCHEDULER_COMMAND` | `artisan schedule:run --no-interaction` | comando do papel `scheduler` |

## Por que o worker deriva do app (e não é mais Alpine)

Até agosto de 2026 o worker era `php:8.4-cli-alpine`: outra distribuição, outra
libc, outra árvore de camadas. A escolha vinha do ambiente em que o worker desta
organização já rodava, e havia sido mantida para não trocar a libc de um
processo que executa jobs de longa duração.

O que mudou a conta foi a medição do CI. Publicar as três imagens levava **64
minutos**, e o log dizia exatamente onde:

```
#17 [linux/amd64 …] RUN install-php-extensions …   DONE   102.1s
#18 [linux/arm64 …] RUN install-php-extensions …   DONE  1764.8s
```

As 14 extensões compilam de fonte; o `arm64` emulado é **17× mais lento** que o
`amd64` nativo. E compilavam quatro vezes por publicação — duas distribuições ×
duas arquiteturas. Metade desse trabalho existia só porque o worker tinha base
própria.

Hoje `Dockerfile.worker` é `FROM laravel-app` mais um `COPY` do entrypoint. A
compilação acontece uma vez, e a paridade de extensões deixou de ser uma
afirmação verificada para ser **estrutural**: não há mais duas instalações que
possam divergir.

O que isso custou, e vale estar escrito tanto quanto o ganho:

- **O worker roda PHP ZTS.** É o que o FrankenPHP exige e o que a base traz.
  `queue:work` e o Horizon funcionam em ZTS; o custo é da ordem de alguns por
  cento em execução single-thread. O teste-gate afirma o ZTS nas duas imagens,
  para que uma volta a NTS apareça no CI e não num benchmark de fila meses
  depois.
- **A imagem do worker ficou maior**, e depende de onde se olha. Sozinha, saiu
  de 66 MB para 199 MB comprimidos (`arm64`). Mas ela agora compartilha **todas**
  as camadas com o `laravel-app`: num host que roda web e worker — o caso normal
  —, o par saiu de 265 MB para 199 MB de camadas distintas. Só um host que rode
  exclusivamente worker paga a diferença.
- **O worker herda `EXPOSE 8000` e o binário do FrankenPHP.** Ambos inertes num
  processo que não atende porta.

## Multi-arch

As três imagens publicam `linux/amd64` **e** `linux/arm64` — diferente dos
módulos de infraestrutura deste repositório, que são só `amd64`. O motivo é que
estas imagens são consumidas em **tempo de build**, inclusive na estação de
desenvolvimento, e as estações da equipe são Apple Silicon. Sem `arm64` no
manifest, todo build local cairia em emulação.

O custo disso no CI **era** a emulação: `arm64` sob QEMU, dezenas de minutos por
imagem. Não é mais. O `laravel-app` builda cada arquitetura no seu **runner
nativo** — `ubuntu-24.04` e `ubuntu-24.04-arm`, este último gratuito porque o
repositório é público — e um job de manifest junta as duas por digest. Worker e
builder continuam saindo de um runner só, e podem: eles não compilam nada.

Os filtros de `paths:` no workflow continuam estreitos, por arquivo que entra na
imagem. O motivo agora é outro: não é mais a emulação que custa caro, é a
compilação em si.

## Build local

Publicar não é mais exclusividade do CI:

```bash
bash build.sh laravel            # as três, arquitetura nativa, sem publicar
bash build.sh laravel-app        # só a base, para iterar num Dockerfile
bash build.sh laravel --push     # multi-arch, no mesmo GHCR e com as mesmas tags
```

O script lê contexto, Dockerfile, plataformas e tags do próprio
`build-publish.yml` — não guarda uma segunda cópia da configuração. Detalhes em
`bash build.sh --help`.

## Versionamento

Duas tags por imagem, como no resto do repositório: `:8.4` acompanha a revisão
corrente e `:8.4-r3` é imutável. A política, e quando incrementar a revisão,
estão em [docs/versionamento.md](docs/versionamento.md).

## Testes

```bash
bash laravel/test/laravel-images.test.sh
```

Builda as três imagens e afirma: paridade de extensões entre app e worker, as
extensões da lista presentes nas duas, as diretivas de `99-custom.ini`
aplicadas, Composer respondendo, entrypoints executáveis, `Caddyfile` no lugar
que o Octane espera, `bash` no worker, PHP thread-safe nos dois runtimes, o
dimensionamento de workers do FrankenPHP com CPU e memória reais, e Node 22 no
builder. É o gate que roda no CI antes da publicação — e o mesmo que o
`build.sh` roda antes de um build local.
