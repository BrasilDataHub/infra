# Versionamento das imagens base de aplicação

## O esquema

Duas tags por imagem, como nos demais módulos do repositório:

```
ghcr.io/brasildatahub/laravel-app:8.4        # móvel — segue a revisão corrente
ghcr.io/brasildatahub/laravel-app:8.4-r3     # imutável — nunca é reescrita
```

`8.4` é a minor do PHP, que identifica a stack. `-rN` é o contador de revisão
**da imagem**, e é o que distingue duas construções da mesma minor de PHP com
conteúdos diferentes.

Por que não usar a versão completa do PHP, como `postgres:17.10` faz: aqui a
imagem muda por motivos que não são a versão do PHP. Acrescentar uma extensão,
subir a minor do FrankenPHP ou ajustar o `99-custom.ini` produz uma imagem
diferente com o mesmo `8.4.24` embaixo. Uma tag `8.4.24` mentiria — duas
imagens distintas a carregariam.

## Quando incrementar a revisão

**Sempre** que o conteúdo da imagem mudar. Na prática, quando mudar qualquer um
destes arquivos:

| Arquivo | Efeito |
|---|---|
| `php-extensions.txt` | muda o que a aplicação pode usar |
| `php/99-custom.ini` | muda desempenho e limites em runtime |
| `caddy/Caddyfile` | muda roteamento, compressão e cabeçalhos de cache |
| `entrypoint.sh`, `entrypoint-worker.sh` | muda a sequência de start |
| `Dockerfile.*` (versões, pacotes de SO) | muda a base |

Não incremente por mudança em `README.md`, `docs/` ou `test/` — esses arquivos
não entram na imagem, e os filtros de `paths:` no workflow já os mantêm fora do
gatilho de publicação.

## Onde a versão é declarada

Como nas demais imagens da plataforma, a versão vive em lugares que **precisam
concordar**:

1. `PHP_MINOR` e `REVISION` no `env:` global de
   `.github/workflows/build-publish.yml` — de onde saem as duas tags de cada
   uma das três imagens. Ficam no escopo global, e não no de um job, porque
   agora são **três jobs** que precisam concordar na tag: um cria o manifest da
   `laravel-app` e outro deriva dela;
2. o `ARG BASE_TAG` de `Dockerfile.worker` e de `Dockerfile.builder`, que
   apontam para a `laravel-app`;
3. o `FROM` dos projetos consumidores.

O `build.sh` da raiz **não** é um quarto lugar: ele lê as tags do próprio
workflow a cada execução, e `test/catalogo-build.test.sh` afirma que essa
leitura continua batendo.

A tabela de imagens no [README do módulo](../README.md) e a linha na tabela
**Serviços** do README da raiz mencionam apenas a tag móvel — não precisam ser
tocadas a cada revisão.

## Quando subir a minor do PHP

Uma minor nova (`8.5`) é uma **imagem nova**, publicada lado a lado:
`laravel-app:8.5` passa a existir sem que `laravel-app:8.4` deixe de ser
atualizada. O contador de revisão recomeça em `-r1`.

Só quando todos os verticais tiverem migrado é que a minor antiga sai do
workflow. Isso é o que permite um projeto migrar por vez, e não todos no mesmo
dia.

## Como um projeto consumidor se atualiza

O `FROM` de uma aplicação deve apontar para a **tag imutável**:

```dockerfile
ARG BASE_TAG=8.4-r3
FROM ghcr.io/brasildatahub/laravel-app:${BASE_TAG}
```

Assim o build é reprodutível: nenhuma imagem de aplicação muda porque a base
mudou embaixo dela. Atualizar é um commit que troca `-r2` por `-r3` — visível
no diff, revisável, e reversível.

Usar a tag móvel `:8.4` funciona e é conveniente em desenvolvimento, mas em
produção significa que um `docker build` de hoje e outro de amanhã podem
produzir imagens diferentes a partir do mesmo commit. É exatamente o problema
que a tag `dunglas/frankenphp:1` causava antes desta refatoração.

## Publicação

A CI publica a cada push na `main` que toque um arquivo que entra na imagem, em
quatro jobs encadeados:

```
laravel-teste ─→ laravel-app (amd64 e arm64, runners nativos)
                     └→ laravel-app-manifest ─→ laravel-derivados (worker, builder)
```

A ordem é uma restrição real, não uma preferência: `laravel-worker` e
`laravel-builder` fazem `FROM laravel-app` e precisam da **tag imutável desta
execução** já publicada. Em paralelo, pegariam a imagem da publicação anterior —
passariam verdes entregando a base errada.

`laravel-app` é a única que compila alguma coisa, e por isso a única que ganha um
runner por arquitetura. Cada um publica **por digest**, sem tag; a tag só nasce
no `laravel-app-manifest`, quando as duas metades estão prontas. É o que impede
que exista, em algum momento, uma tag pública apontando para uma imagem de
arquitetura única.

O teste-gate é o primeiro job, e tudo o mais depende dele. Se ele falhar,
nenhuma das três é publicada.

## Republicar à mão

Pela CI, sem esperar um push:

```bash
gh workflow run build-publish.yml -f servico=laravel
```

Ou da sua máquina, com as mesmas tags:

```bash
bash build.sh laravel --push
```
