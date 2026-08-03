#!/usr/bin/env bash
# Testes do filtro por escopo do build-publish.yml.
#
#   bash test/filtro-build.test.sh
#
# Cada push só deve reconstruir imagens cujos arquivos foram tocados.
# O mapa de padrões é lido do próprio workflow (não duplicado aqui).
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

# Todo job deve ser decidido por um output do mapa (direto ou via cadeia needs:).
echo "Cobertura"
JOBS="$(python3 - "$WORKFLOW" <<'PY'
import re
import sys

import yaml

jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]


def pais(nome):
    n = jobs[nome].get("needs") or []
    return [n] if isinstance(n, str) else list(n)


def escopo(nome, visto=None):
    """O output de `changes` que decide se este job roda."""
    visto = visto if visto is not None else set()
    if nome in visto or nome not in jobs:
        return None
    visto.add(nome)
    achado = re.search(
        r"needs\.changes\.outputs\.([A-Za-z0-9_-]+)", str(jobs[nome].get("if") or "")
    )
    if achado:
        return achado.group(1)
    for pai in pais(nome):
        herdado = escopo(pai, visto)
        if herdado:
            return herdado
    return None


for nome in jobs:
    if nome != "changes":
        print(f"{nome}|{escopo(nome) or ''}")
PY
)"
while IFS='|' read -r job escopo; do
    [ -n "$job" ] || continue
    if [ -z "$escopo" ]; then
        nok "job '$job' não é decidido por nenhum output de 'changes' — rodaria sempre"
    elif printf '%s\n' "$MAPA" | grep -q "^${escopo}|"; then
        ok "job '$job' decidido pelo escopo '$escopo'"
    else
        nok "job '$job' depende do escopo '$escopo', que não está no mapa — nunca rodaria"
    fi
done <<< "$JOBS"

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
verifica "laravel/README.md"          ""
verifica "laravel/docs/versionamento.md" ""
verifica "README.md"                  ""
verifica "postgres/docs/perfis.md"    ""
verifica "redis/README.md"            ""
verifica "monitoring/README.md"       ""
verifica "opensearch/README.md"       ""

echo
echo "O próprio workflow não republica a stack inteira"
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
# postgres/*.sh e postgres/backup/*.sh são imagens diferentes.
verifica "postgres/Dockerfile"              "postgres"
verifica "postgres/shm-guard.sh"            "postgres"
verifica "postgres/initdb/01-extensions.sql" "postgres"
verifica "postgres/test/shm-guard.test.sh"  "postgres"
verifica "postgres/backup/Dockerfile"       "pgbackrest"
verifica "postgres/backup/entrypoint.sh"    "pgbackrest"
verifica "postgres/backup/test/backup.test.sh" "pgbackrest"
# Overlays de compose não entram em imagem.
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
