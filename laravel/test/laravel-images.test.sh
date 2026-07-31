#!/usr/bin/env bash
# Teste-gate das imagens base de aplicação Laravel da BrasilDataHub.
#
#   bash laravel/test/laravel-images.test.sh
#
# Roda no CI ANTES do push, como o shm-guard do Postgres e o teste de pooling do
# PgBouncer. O motivo é o mesmo dos outros: o que ele afirma não falha no build
# — falha depois, em produção, de formas que não mencionam a causa.
#
# A afirmação central é a PARIDADE DE EXTENSÕES entre laravel-app e
# laravel-worker. Os dois rodam distribuições diferentes (Debian/glibc e
# Alpine/musl) a partir de uma lista compartilhada, e é justamente por serem
# ambientes distintos que a lista compartilhada não basta: uma extensão pode
# existir para uma libc e não para a outra, ou compilar num e falhar no outro
# sem derrubar o build. O sintoma seria um job de fila estourando "Class not
# found" com o container web funcionando perfeitamente ao lado.
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PREFIXO="bdhtest-laravel"
IMG_APP="${PREFIXO}/laravel-app"
IMG_WORKER="${PREFIXO}/laravel-worker"
IMG_BUILDER="${PREFIXO}/laravel-builder"
TMP="$(mktemp -d)"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
nok() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

limpar() { rm -rf "$TMP"; }
trap limpar EXIT

# `php -d error_reporting=0` mantém a saída limpa de eventuais depreciações que
# não têm nada a ver com o que está sendo afirmado.
php_em() { docker run --rm --entrypoint php "$1" -d error_reporting=0 "${@:2}"; }

echo
echo "Imagens base Laravel — teste-gate"
echo

echo "Build"
docker build -q -f "$RAIZ/Dockerfile.app" -t "$IMG_APP" "$RAIZ" >/dev/null \
    || { echo "build de laravel-app falhou"; exit 1; }
ok "laravel-app"
docker build -q -f "$RAIZ/Dockerfile.worker" -t "$IMG_WORKER" "$RAIZ" >/dev/null \
    || { echo "build de laravel-worker falhou"; exit 1; }
ok "laravel-worker"
# O builder deriva do app; no CI e aqui ele aponta para a imagem recém-buildada,
# não para a publicada — senão o teste validaria a imagem antiga do registry.
docker build -q -f "$RAIZ/Dockerfile.builder" \
    --build-arg BASE_IMAGE="$IMG_APP" --build-arg BASE_TAG=latest \
    -t "$IMG_BUILDER" "$RAIZ" >/dev/null \
    || { echo "build de laravel-builder falhou"; exit 1; }
ok "laravel-builder"

echo
echo "Paridade de extensões entre app e worker"

php_em "$IMG_APP"    -m | tr -d '\r' | sort > "$TMP/ext-app.txt"
php_em "$IMG_WORKER" -m | tr -d '\r' | sort > "$TMP/ext-worker.txt"

if diff -u "$TMP/ext-app.txt" "$TMP/ext-worker.txt" > "$TMP/ext.diff"; then
    ok "app e worker carregam exatamente os mesmos módulos ($(grep -c . "$TMP/ext-app.txt"))"
else
    nok "app e worker DIVERGEM em módulos carregados:"
    sed 's/^/      /' "$TMP/ext.diff"
fi

# E as da lista estão de fato lá — a paridade acima passaria também se as duas
# imagens estivessem igualmente incompletas.
faltando_app=""; faltando_worker=""
while read -r ext; do
    grep -qix "$ext" "$TMP/ext-app.txt"    || faltando_app="$faltando_app $ext"
    grep -qix "$ext" "$TMP/ext-worker.txt" || faltando_worker="$faltando_worker $ext"
done < <(grep -vE '^[[:space:]]*(#|$)' "$RAIZ/php-extensions.txt")

# `pdo_*` e `excimer` aparecem no `php -m` com o mesmo nome do arquivo da lista;
# quando um dia não aparecerem, é aqui que se descobre.
if [ -z "$faltando_app" ]; then
    ok "todas as extensões de php-extensions.txt no app"
else
    nok "faltam no app:$faltando_app"
fi
if [ -z "$faltando_worker" ]; then
    ok "todas as extensões de php-extensions.txt no worker"
else
    nok "faltam no worker:$faltando_worker"
fi

echo
echo "Diretivas de php/99-custom.ini aplicadas"

# Estas são decisões MEDIDAS (ver os comentários no próprio ini). Se uma delas
# sumir, o efeito é de desempenho e silencioso: ninguém percebe até medir de
# novo. `opcache.jit = disable` em particular precisa continuar legível num
# `php -i` — foi por isso que se escolheu `disable` em vez de buffer zero.
verifica_diretiva() {
    local img="$1" nome="$2" esperado="$3" rotulo="$4" obtido
    obtido="$(php_em "$img" -r "echo ini_get('$nome');" 2>/dev/null | tr -d '\r')"
    if [ "$obtido" = "$esperado" ]; then
        ok "$rotulo: $nome = $obtido"
    else
        nok "$rotulo: $nome = '$obtido', esperado '$esperado'"
    fi
}

for par in "$IMG_APP:app" "$IMG_WORKER:worker"; do
    img="${par%:*}"; rotulo="${par##*:}"
    verifica_diretiva "$img" "opcache.jit"                     "disable" "$rotulo"
    verifica_diretiva "$img" "opcache.enable_cli"              "1"       "$rotulo"
    verifica_diretiva "$img" "opcache.interned_strings_buffer" "32"      "$rotulo"
    verifica_diretiva "$img" "opcache.memory_consumption"      "192"     "$rotulo"
    verifica_diretiva "$img" "memory_limit"                    "256M"    "$rotulo"
    verifica_diretiva "$img" "variables_order"                 "EGPCS"   "$rotulo"
    verifica_diretiva "$img" "max_execution_time"              "0"       "$rotulo"
    verifica_diretiva "$img" "upload_max_filesize"             "5G"      "$rotulo"
    verifica_diretiva "$img" "post_max_size"                   "5G"      "$rotulo"
    verifica_diretiva "$img" "expose_php"                      ""        "$rotulo"
done

echo
echo "Ferramentas e arquivos"

for par in "$IMG_APP:app" "$IMG_WORKER:worker" "$IMG_BUILDER:builder"; do
    img="${par%:*}"; rotulo="${par##*:}"
    if docker run --rm --entrypoint composer "$img" --version --no-interaction >/dev/null 2>&1; then
        ok "$rotulo: composer responde"
    else
        nok "$rotulo: composer não responde"
    fi
    # O entrypoint tem de ser executável — um `chmod +x` perdido só se manifesta
    # como "permission denied" no start do container, já em produção.
    if docker run --rm --entrypoint test "$img" -x /usr/local/bin/entrypoint 2>/dev/null; then
        ok "$rotulo: /usr/local/bin/entrypoint é executável"
    elif [ "$rotulo" = "builder" ]; then
        ok "$rotulo: sem entrypoint, como esperado numa imagem de build"
    else
        nok "$rotulo: /usr/local/bin/entrypoint ausente ou não executável"
    fi
done

# O Caddyfile precisa estar no caminho que o entrypoint passa ao Octane em
# `--caddyfile=/etc/caddy/Caddyfile`. Sem ele o Octane sobe com o Caddyfile
# padrão e as regras de cache imutável de /build somem — sem erro nenhum.
if docker run --rm --entrypoint test "$IMG_APP" -f /etc/caddy/Caddyfile 2>/dev/null; then
    ok "app: /etc/caddy/Caddyfile presente"
else
    nok "app: /etc/caddy/Caddyfile ausente"
fi

# `bash` no worker não é conforto: os entrypoints usam `local`, e o `ash` do
# Alpine não o implementa da mesma forma.
if docker run --rm --entrypoint bash "$IMG_WORKER" -c 'exit 0' 2>/dev/null; then
    ok "worker: bash disponível (exigido pelo entrypoint)"
else
    nok "worker: bash ausente — o entrypoint não sobe"
fi

# O FrankenPHP só roda com PHP thread-safe. Se um dia a base mudar para uma
# variante NTS, o Octane falha no start com uma mensagem que não diz isso.
if php_em "$IMG_APP" -r 'exit(PHP_ZTS ? 0 : 1);' 2>/dev/null; then
    ok "app: PHP thread-safe (ZTS), exigido pelo FrankenPHP"
else
    nok "app: PHP não é thread-safe — o Octane/FrankenPHP não sobe"
fi

echo
echo "Toolchain de build"

node_ver="$(docker run --rm --entrypoint node "$IMG_BUILDER" --version 2>/dev/null | tr -d '\r')"
case "$node_ver" in
    v22.*) ok "builder: node $node_ver" ;;
    *)     nok "builder: node '$node_ver', esperado v22.x" ;;
esac

if docker run --rm --entrypoint npm "$IMG_BUILDER" --version >/dev/null 2>&1; then
    ok "builder: npm responde"
else
    nok "builder: npm não responde"
fi

# O ponto inteiro de o builder derivar do app: se as extensões divergirem, o
# vendor gerado no builder deixa de ser válido como vendor de produção e o
# `--ignore-platform-reqs` teria de voltar.
php_em "$IMG_BUILDER" -m | tr -d '\r' | sort > "$TMP/ext-builder.txt"
if diff -q "$TMP/ext-app.txt" "$TMP/ext-builder.txt" >/dev/null; then
    ok "builder: mesmas extensões do app (o vendor gerado nele serve ao runtime)"
else
    nok "builder: extensões divergem do app"
    diff -u "$TMP/ext-app.txt" "$TMP/ext-builder.txt" | sed 's/^/      /'
fi

echo
echo "  $PASS ok, $FAIL falhas"
echo
[ "$FAIL" -eq 0 ]
