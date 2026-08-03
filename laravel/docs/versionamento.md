# Versionamento das imagens base de aplicação

## Esquema

```
ghcr.io/brasildatahub/laravel-app:8.4        # móvel — revisão corrente
ghcr.io/brasildatahub/laravel-app:8.4-r3     # imutável — nunca reescrita
```

`8.4` = minor do PHP (stack). `-rN` = revisão da **imagem** (extensão,
FrankenPHP, `99-custom.ini`, etc. mudam a imagem sem mudar o patch do PHP).

## Quando incrementar

Sempre que o conteúdo da imagem mudar:

| Arquivo | Efeito |
|---|---|
| `php-extensions.txt` | o que a app pode usar |
| `php/99-custom.ini` | runtime |
| `caddy/Caddyfile` | roteamento, compressão, cache headers |
| `entrypoint.sh`, `entrypoint-worker.sh` | sequência de start |
| `Dockerfile.*` | base / pacotes de SO |

Não incrementar por `README.md`, `docs/` ou `test/` (fora da imagem e dos
`paths:` do workflow).

## Onde a versão é declarada

Precisam concordar:

1. `PHP_MINOR` e `REVISION` no `env:` global de
   `.github/workflows/build-publish.yml` (três jobs compartilham a tag)
2. `ARG BASE_TAG` em `Dockerfile.worker` e `Dockerfile.builder`
3. `FROM` dos projetos consumidores

`build.sh` lê as tags do workflow; `test/catalogo-build.test.sh` afirma a
leitura. README do módulo e da raiz mencionam só a tag móvel.

## Subir a minor do PHP

Minor nova (`8.5`) = imagem nova, lado a lado. Revisão recomeça em `-r1`. Minor
antiga sai do workflow só quando todos os verticais migrarem.

## Consumidor

Produção aponta para a **tag imutável**:

```dockerfile
ARG BASE_TAG=8.4-r3
FROM ghcr.io/brasildatahub/laravel-app:${BASE_TAG}
```

Atualizar = commit trocando `-r2` → `-r3`. Tag móvel `:8.4` ok em
desenvolvimento; em produção dois builds do mesmo commit podem divergir.

## Publicação

Push na `main` que toque arquivo da imagem:

```
laravel-teste ─→ laravel-app (amd64 e arm64, runners nativos)
                     └→ laravel-app-manifest ─→ laravel-derivados (worker, builder)
```

Ordem obrigatória: worker/builder fazem `FROM laravel-app` e precisam da tag
imutável **desta** execução. `laravel-app` publica por digest; a tag nasce no
manifest (impede tag pública de arquitetura única). Gate de teste primeiro —
falha → nenhuma das três publica.

## Republicar à mão

```bash
gh workflow run build-publish.yml -f servico=laravel
# ou
bash build.sh laravel --push
```
