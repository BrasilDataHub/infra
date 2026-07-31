#!/usr/bin/env bash
# Testes do filtro por escopo do build-publish.yml.
#
#   bash test/filtro-build.test.sh
#
# O que ele protege: cada push só deve reconstruir as imagens que o push de fato
# tocou. Sem isso, mudar duas linhas do `redis/Dockerfile` reconstrói também as
# imagens de aplicação — e o build multi-arch delas compila 14 extensões PHP sob
# emulação, o que leva dezenas de minutos por nada.
#
# O mapa de padrões é LIDO DO PRÓPRIO WORKFLOW, e não copiado para cá. Uma cópia
# passaria a divergir no primeiro serviço novo, e o teste continuaria verde
# testando uma regra que não é mais a que roda.
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$RAIZ/.github/workflows/build-publish.yml"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
nok() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

MAPA="$(python3 - "$WORKFLOW" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
step = [s for s in d["jobs"]["changes"]["steps"] if s.get("id") == "filtro"][0]
for linha in step["run"].splitlines():
    if "|^" in linha:
        print(linha)
PY
)"

if [ -z "$MAPA" ]; then
    echo "não consegui ler o mapa de escopos de $WORKFLOW" >&2
    exit 1
fi

echo
echo "Filtro por escopo do build-publish.yml"
echo

# Todo serviço com job no workflow precisa de uma linha no mapa. Sem esta
# verificação, um serviço novo entraria com `if: needs.changes.outputs.novo ==
# 'true'` contra um output que nunca existe — e o job NUNCA rodaria, em silêncio.
echo "Cobertura"
JOBS="$(python3 - "$WORKFLOW" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for nome in d["jobs"]:
    if nome != "changes":
        print(nome)
PY
)"
for job in $JOBS; do
    if printf '%s\n' "$MAPA" | grep -q "^${job}|"; then
        ok "job '$job' tem padrão no mapa"
    else
        nok "job '$job' NÃO tem padrão no mapa — nunca rodaria"
    fi
done

# Espelha o laço do workflow: dado um arquivo, quais escopos ele ativa.
escopos_de() {
    local arquivo="$1" nome padrao
    while IFS='|' read -r nome padrao; do
        [ -n "$nome" ] || continue
        if printf '%s\n' "$arquivo" | grep -qE "$padrao"; then
            printf '%s ' "$nome"
        fi
    done <<< "$MAPA"
}

verifica() { # arquivo, escopos esperados (separados por espaço, "" = nenhum)
    local arquivo="$1" esperado="$2" obtido
    obtido="$(escopos_de "$arquivo" | xargs || true)"
    if [ "$obtido" = "$esperado" ]; then
        if [ -z "$esperado" ]; then
            ok "$arquivo → não reconstrói nada"
        else
            ok "$arquivo → $obtido"
        fi
    else
        nok "$arquivo → '$obtido', esperado '$esperado'"
    fi
}

echo
echo "Documentação nunca reconstrói imagem"
# É o caso que originou este filtro: um commit de README não pode custar uma
# hora de emulação.
verifica "laravel/README.md"          ""
verifica "laravel/docs/versionamento.md" ""
verifica "README.md"                  ""
verifica "postgres/docs/perfis.md"    ""
verifica "redis/README.md"            ""
verifica "monitoring/README.md"       ""
verifica "opensearch/README.md"       ""

echo
echo "O próprio workflow não republica a stack inteira"
# Era por aqui que um ajuste de comentário reconstruía tudo. Para republicar de
# propósito existe o workflow_dispatch, que aceita escolher a imagem.
verifica ".github/workflows/build-publish.yml" ""
verifica ".github/workflows/lint-setup.yml"    ""

echo
echo "Cada imagem responde só ao que entra nela"
verifica "redis/Dockerfile"                    "redis"
verifica "redis/redis.conf"                    "redis"
verifica "meilisearch/Dockerfile"              "meilisearch"
verifica "opensearch/index/busca.json"         "opensearch"
verifica "opensearch/test/opensearch.test.sh"  "opensearch"
verifica "pgbouncer/generate-config.sh"        "pgbouncer"
verifica "monitoring/prometheus/prometheus.yml" "monitoring"
verifica "monitoring/grafana/dashboards/x.json" "monitoring"

echo
echo "Postgres e pgbackrest não se confundem"
# `postgres/*.sh` e `postgres/backup/*.sh` são imagens DIFERENTES e o segundo
# mora dentro do diretório do primeiro. Um padrão frouxo faria todo commit do
# sidecar reconstruir também o banco.
verifica "postgres/Dockerfile"              "postgres"
verifica "postgres/shm-guard.sh"            "postgres"
verifica "postgres/initdb/01-extensions.sql" "postgres"
verifica "postgres/test/shm-guard.test.sh"  "postgres"
verifica "postgres/backup/Dockerfile"       "pgbackrest"
verifica "postgres/backup/entrypoint.sh"    "pgbackrest"
verifica "postgres/backup/test/backup.test.sh" "pgbackrest"
# Overlays de compose não entram em imagem nenhuma.
verifica "postgres/docker-compose.backup.yml" ""
verifica "redis/docker-compose.metrics.yml"   ""
verifica "redis/profiles/cache-512mb.env"     ""

echo
echo "Imagens de aplicação"
verifica "laravel/Dockerfile.app"        "laravel"
verifica "laravel/Dockerfile.worker"     "laravel"
verifica "laravel/Dockerfile.builder"    "laravel"
verifica "laravel/php-extensions.txt"    "laravel"
verifica "laravel/php/99-custom.ini"     "laravel"
verifica "laravel/caddy/Caddyfile"       "laravel"
verifica "laravel/entrypoint.sh"         "laravel"
verifica "laravel/entrypoint-worker.sh"  "laravel"
verifica "laravel/test/laravel-images.test.sh" "laravel"

echo
echo "  $PASS ok, $FAIL falhas"
echo
[ "$FAIL" -eq 0 ]
