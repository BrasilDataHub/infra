#!/usr/bin/env bash
# Testes do catálogo que o build.sh lê do build-publish.yml.
#
#   bash test/catalogo-build.test.sh
#
# O build.sh lê contexto, Dockerfile, tags e build-args do workflow a cada execução.
# Estes testes são estruturais (não repetem versões literais como 8.4-r3).
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

echo "Cobertura"
# Lista de referência: cabeçalho do workflow (ghcr.io/brasildatahub/...).
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

echo
echo "Cada imagem do catálogo"

while IFS= read -r linha; do
    [ -n "$linha" ] || continue
    nome="$(campo "$linha" 1)"
    contexto="$(campo "$linha" 2)"
    dockerfile="$(campo "$linha" 3)"
    tags="$(campo "$linha" 5)"

    # Oito campos exatos — pipe dentro de valor quebraria o cut.
    quantos="$(awk -F'|' '{print NF}' <<< "$linha")"
    [ "$quantos" = 8 ] || nok "$nome: $quantos campos, esperado 8"

    [ -d "$RAIZ/$contexto" ]  || nok "$nome: contexto '$contexto' não existe"
    [ -f "$RAIZ/$dockerfile" ] || nok "$nome: Dockerfile '$dockerfile' não existe"
    [ -n "$tags" ]            || nok "$nome: sem nenhuma tag — o build não teria nome"

    # Nenhuma variável GitHub Actions sem expandir.
    # shellcheck disable=SC2016
    case "$linha" in
        *'${'*) nok "$nome: sobrou variável por expandir na linha do catálogo" ;;
    esac
done < "$CATALOGO"

[ "$FAIL" -eq 0 ] && ok "contexto, Dockerfile e tags conferem em todas"

echo
echo "Matriz, manifest e derivação"

linha_de() { grep -m1 "^${1}|" "$CATALOGO"; }

# laravel-app: build multi-arch + tags do imagetools create.
plataformas="$(campo "$(linha_de laravel-app)" 4)"
case "$plataformas" in
    *linux/amd64*) case "$plataformas" in
        *linux/arm64*) ok "laravel-app funde as arquiteturas da matriz ($plataformas)" ;;
        *) nok "laravel-app sem linux/arm64: '$plataformas'" ;;
    esac ;;
    *) nok "laravel-app sem linux/amd64: '$plataformas'" ;;
esac

tags_app="$(campo "$(linha_de laravel-app)" 5)"
case "$tags_app" in
    *ghcr.io/*/laravel-app:*) ok "tags de laravel-app vieram do imagetools create" ;;
    *) nok "laravel-app sem tag utilizável: '$tags_app'" ;;
esac

for derivado in laravel-worker laravel-builder; do
    if [ "$(campo "$(linha_de "$derivado")" 8)" = "laravel-app" ]; then
        ok "$derivado deriva de laravel-app, e o build.sh a constrói antes"
    else
        nok "$derivado não declara a derivação de laravel-app"
    fi
done

echo
echo "Teste-gate por módulo"

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

echo
echo "Sem --push, nada sai da máquina"

# Só linhas de comando docker buildx — o rodapé do script menciona --push em prosa.
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
