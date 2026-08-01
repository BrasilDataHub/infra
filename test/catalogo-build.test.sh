#!/usr/bin/env bash
# Testes do catálogo que o build.sh lê do build-publish.yml.
#
#   bash test/catalogo-build.test.sh
#
# O que ele protege: o `build.sh` não guarda cópia nenhuma da configuração das
# imagens — contexto, Dockerfile, plataformas, tags e build-args são LIDOS do
# workflow a cada execução. Isso resolve a divergência, mas cria uma dependência
# nova: a leitura precisa continuar entendendo a forma do YAML.
#
# É uma dependência que falha CALADA. Se um dia o workflow trocar
# `docker/build-push-action` por outra action, mover as tags para uma
# metadata-action, ou publicar por digest sem um `imagetools create` que dê nome
# à imagem, o catálogo sai a menos — e o `build.sh` publica a tag errada, ou
# simplesmente não publica aquela imagem, sem erro nenhum. Nada no build local
# diria que faltou uma.
#
# Por isso as afirmações abaixo são ESTRUTURAIS e não literais: elas não repetem
# `8.4-r3` nem `postgres:17.10`. Repetir os valores criaria um terceiro lugar
# para manter em concordância — exatamente o que o `build.sh` existe para
# eliminar. O que se afirma é que o conjunto de imagens do catálogo é o conjunto
# de imagens do workflow, que nada ficou por expandir e que os caminhos existem.
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$RAIZ/.github/workflows/build-publish.yml"
BUILD="$RAIZ/build.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
nok() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
limpar() { rm -rf "$TMP"; }
trap limpar EXIT

CATALOGO="$TMP/catalogo"
if ! bash "$BUILD" --catalogo > "$CATALOGO" 2>"$TMP/erro"; then
    echo "build.sh --catalogo falhou:" >&2
    sed 's/^/    /' "$TMP/erro" >&2
    exit 1
fi

echo
echo "Catálogo de imagens lido do build-publish.yml"
echo

campo() { cut -d'|' -f"$2" <<< "$1"; }

# ---------------------------------------------------------------------------
# Cobertura — nenhuma imagem some, nenhuma sobra
# ---------------------------------------------------------------------------
# A lista de referência sai do CABEÇALHO do workflow — aquele bloco de
# comentário que enumera `ghcr.io/brasildatahub/...`, uma imagem por linha.
#
# Duas razões para tirá-la de lá, e não de um segundo parser do YAML. A primeira
# é independência: um erro no parser que está sendo testado apareceria nos dois
# lados de uma comparação feita pelo mesmo caminho, e o teste passaria verde. A
# segunda é que metade dos nomes nem está escrita literalmente no YAML — vêm de
# `${{ matrix.image }}` e de `laravel-${{ matrix.imagem }}` —, então "grepar os
# nomes" sem expandir matriz não daria a lista inteira.
#
# De brinde, isto afirma que o cabeçalho não mente: uma imagem nova que não seja
# anunciada ali, ou uma removida que continue anunciada, cai aqui.
echo "Cobertura"

grep -oE '^# +ghcr\.io/[a-z0-9.-]+/[a-z0-9.-]+' "$WORKFLOW" \
    | sed 's#.*/##' | sort -u > "$TMP/no-workflow"

[ -s "$TMP/no-workflow" ] \
    || { echo "não achei a lista de imagens no cabeçalho de $WORKFLOW" >&2; exit 1; }

campo "$(cat "$CATALOGO")" 1 | sort -u > "$TMP/no-catalogo"

if diff -u "$TMP/no-workflow" "$TMP/no-catalogo" > "$TMP/cobertura.diff"; then
    ok "as $(grep -c . "$TMP/no-catalogo") imagens anunciadas no workflow estão no catálogo"
else
    nok "o catálogo não bate com o cabeçalho do workflow (- anunciado, + no catálogo):"
    sed 's/^/      /' "$TMP/cobertura.diff"
fi

# ---------------------------------------------------------------------------
# Integridade de cada linha
# ---------------------------------------------------------------------------
echo
echo "Cada imagem do catálogo"

while IFS= read -r linha; do
    [ -n "$linha" ] || continue
    nome="$(campo "$linha" 1)"
    contexto="$(campo "$linha" 2)"
    dockerfile="$(campo "$linha" 3)"
    tags="$(campo "$linha" 5)"

    # Oito campos exatos. Menos que isso é campo perdido; mais é um `|` dentro
    # de um valor, que quebraria o `cut` de quem consome o catálogo.
    quantos="$(awk -F'|' '{print NF}' <<< "$linha")"
    [ "$quantos" = 8 ] || nok "$nome: $quantos campos, esperado 8"

    [ -d "$RAIZ/$contexto" ]  || nok "$nome: contexto '$contexto' não existe"
    [ -f "$RAIZ/$dockerfile" ] || nok "$nome: Dockerfile '$dockerfile' não existe"
    [ -n "$tags" ]            || nok "$nome: sem nenhuma tag — o build não teria nome"

    # A afirmação que pega uma expansão incompleta. Sem ela, um `${{ env.X }}`
    # que o parser não resolvesse viraria uma tag LITERAL com chaves dentro:
    # o docker aceita o argumento, falha no push com "invalid reference format",
    # e o motivo não aparece em lugar nenhum.
    # shellcheck disable=SC2016
    # As aspas simples são de propósito: `${` aqui é o texto procurado dentro do
    # catálogo, não uma expansão a ser feita.
    case "$linha" in
        *'${'*) nok "$nome: sobrou variável por expandir na linha do catálogo" ;;
    esac
done < "$CATALOGO"

[ "$FAIL" -eq 0 ] && ok "contexto, Dockerfile e tags conferem em todas"

# ---------------------------------------------------------------------------
# O que só a matriz e o job de manifest produzem
# ---------------------------------------------------------------------------
echo
echo "Matriz, manifest e derivação"

linha_de() { grep -m1 "^${1}|" "$CATALOGO"; }

# `laravel-app` é buildada por DOIS jobs, um por arquitetura, e publicada por
# digest. Se a fusão das plataformas parar de funcionar, o build local sairia
# com uma arquitetura só — e as estações Apple Silicon voltariam a emular sem
# que nada avisasse.
plataformas="$(campo "$(linha_de laravel-app)" 4)"
case "$plataformas" in
    *linux/amd64*) case "$plataformas" in
        *linux/arm64*) ok "laravel-app funde as arquiteturas da matriz ($plataformas)" ;;
        *) nok "laravel-app sem linux/arm64: '$plataformas'" ;;
    esac ;;
    *) nok "laravel-app sem linux/amd64: '$plataformas'" ;;
esac

# As tags de `laravel-app` não estão no step do build: quem as cria é o
# `imagetools create` do job de manifest. Se essa leitura quebrar, o catálogo
# fica sem a única imagem que compila extensão.
tags_app="$(campo "$(linha_de laravel-app)" 5)"
case "$tags_app" in
    *ghcr.io/*/laravel-app:*) ok "tags de laravel-app vieram do imagetools create" ;;
    *) nok "laravel-app sem tag utilizável: '$tags_app'" ;;
esac

# Publicar um derivado sem a base que ele acabou de receber entrega uma imagem
# construída sobre a publicação anterior — verde, e errada.
for derivado in laravel-worker laravel-builder; do
    if [ "$(campo "$(linha_de "$derivado")" 8)" = "laravel-app" ]; then
        ok "$derivado deriva de laravel-app, e o build.sh a constrói antes"
    else
        nok "$derivado não declara a derivação de laravel-app"
    fi
done

# ---------------------------------------------------------------------------
# Teste-gate
# ---------------------------------------------------------------------------
echo
echo "Teste-gate por módulo"

# O `build.sh` roda o mesmo gate que a CI roda antes de publicar. Um módulo que
# tenha teste no workflow e não o tenha aqui publicaria localmente sem passar
# por ele — que é o oposto do que este repositório faz com os outros módulos.
while IFS= read -r linha; do
    nome="$(campo "$linha" 1)"
    contexto="$(campo "$linha" 2)"
    teste="$(campo "$linha" 7)"
    modulo="${contexto%%/*}"
    if ! grep -qE "bash .*${modulo}/.*test\.sh|bash test/" "$WORKFLOW"; then
        continue
    fi
    if [ -n "$teste" ]; then
        ok "$nome → $teste"
    else
        nok "$nome: o workflow tem teste-gate para '$modulo' e o catálogo não o associou"
    fi
done < "$CATALOGO"

# ---------------------------------------------------------------------------
# O padrão é NÃO publicar
# ---------------------------------------------------------------------------
echo
echo "Sem --push, nada sai da máquina"

# Esta é a afirmação de segurança do script. Se um dia o `--push` virar o padrão
# por um `PUSH=true` deixado para trás, é aqui que aparece — e não num registro
# com uma tag sobrescrita por engano.
# Só as linhas de comando: o rodapé do script menciona `--push` em prosa, para
# dizer como publicar, e um `case` sobre a saída inteira acusaria isso.
comandos_de() { bash "$BUILD" "$@" --dry-run 2>&1 | grep 'docker buildx build'; }

SECO="$(comandos_de redis)"
case "$SECO" in
    *" --push"*) nok "o build padrão publicaria: $SECO" ;;
    *" --load"*) ok "o build padrão carrega no daemon local (--load), não publica" ;;
    *) nok "o dry-run não mostrou nem --load nem --push: $SECO" ;;
esac

case "$(comandos_de redis --push)" in
    *" --push"*) ok "com --push, o comando publica" ;;
    *) nok "--push não chegou ao comando do buildx" ;;
esac

# A seleção por diretório é o que o pedido original chamava de "poder passar o
# diretório": `monitoring` tem de trazer as quatro imagens de monitoring/*.
QUANTAS="$(bash "$BUILD" monitoring --dry-run 2>&1 | grep -c 'docker buildx build')"
if [ "$QUANTAS" = 4 ]; then
    ok "selecionar o diretório 'monitoring' traz as 4 imagens de monitoring/*"
else
    nok "'monitoring' selecionou $QUANTAS imagens, esperado 4"
fi

echo
echo "  $PASS ok, $FAIL falhas"
echo
[ "$FAIL" -eq 0 ]
