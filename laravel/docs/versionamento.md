# Versionamento das imagens base de aplicação

## O esquema

Duas tags por imagem, como nos demais módulos do repositório:

```
ghcr.io/brasildatahub/laravel-app:8.4        # móvel — segue a revisão corrente
ghcr.io/brasildatahub/laravel-app:8.4-r1     # imutável — nunca é reescrita
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

1. `tags:` do job `laravel` em `.github/workflows/build-publish.yml` — as duas
   tags de cada imagem;
2. o `ARG BASE_TAG` de `Dockerfile.builder`, que aponta para a `laravel-app`;
3. o `FROM` dos projetos consumidores.

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
ARG BASE_TAG=8.4-r1
FROM ghcr.io/brasildatahub/laravel-app:${BASE_TAG}
```

Assim o build é reprodutível: nenhuma imagem de aplicação muda porque a base
mudou embaixo dela. Atualizar é um commit que troca `-r1` por `-r2` — visível
no diff, revisável, e reversível.

Usar a tag móvel `:8.4` funciona e é conveniente em desenvolvimento, mas em
produção significa que um `docker build` de hoje e outro de amanhã podem
produzir imagens diferentes a partir do mesmo commit. É exatamente o problema
que a tag `dunglas/frankenphp:1` causava antes desta refatoração.

## Publicação

A CI publica a cada push na `main` que toque um arquivo que entra na imagem. Os
três builds rodam **no mesmo job e em sequência**, porque `laravel-builder`
deriva de `laravel-app` e precisa dela já publicada:

```
laravel-app  →  laravel-worker  →  laravel-builder
```

O teste-gate roda antes do primeiro push. Se ele falhar, nenhuma das três é
publicada.
