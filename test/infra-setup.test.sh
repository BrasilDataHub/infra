#!/usr/bin/env bash
# Testes de infra-setup.sh — carregam o script como biblioteca
# (BDH_SETUP_LIB_ONLY=1) e exercitam a lógica que decide o que vai para o
# servidor. A parte mais importante valida os ARQUIVOS DE PERFIL
# (postgres/profiles/, redis/profiles/, meilisearch/profiles/): eles são a única
# fonte dos valores de tuning, usada tanto pelo script quanto por quem segue a
# documentação, então precisam estar íntegros e coerentes com o guia.
#
#   bash test/infra-setup.test.sh
#
# WORKDIR, DATA_DIR e *_DATA_DIR parecem não usadas para o shellcheck, mas são
# lidas pelas funções carregadas do script — daí o disable abaixo.
# shellcheck disable=SC2034
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  ✓ %s\n' "$desc"; PASS=$((PASS + 1))
    else
        printf '  ✗ %s\n      esperado: %s\n      obtido:   %s\n' "$desc" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}
pass() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=infra-setup.sh
BDH_SETUP_LIB_ONLY=1 . "$REPO_ROOT/infra-setup.sh"
# O script carregado ativa `set -e` e um trap ERR; nos testes queremos avaliar
# falhas em vez de abortar no primeiro comando que retorna != 0.
set +e
trap - ERR

# Só as linhas de atribuição de um arquivo de perfil.
profile_vars() { grep -E '^[A-Z][A-Z0-9_]*=' "$1"; }

printf '\nDetecção de perfil pela RAM\n'
check "8 GB  → dedicada-8gb"    "dedicada-8gb"    "$(detect_pg_profile 8)"
check "15 GB → dedicada-16gb"   "dedicada-16gb"   "$(detect_pg_profile 15)"
check "31 GB → dedicada-32gb"   "dedicada-32gb"   "$(detect_pg_profile 31)"
check "62 GB → dedicada-64gb"   "dedicada-64gb"   "$(detect_pg_profile 62)"
check "125 GB → dedicada-128gb" "dedicada-128gb"  "$(detect_pg_profile 125)"
check "2 GB → menor perfil"     "dedicada-8gb"    "$(detect_pg_profile 2)"
check "13 GB não sobe de perfil" "dedicada-8gb"   "$(detect_pg_profile 13)"

printf '\nValidação de nomes de perfil\n'
profile_valid dedicada-16gb "$PG_PROFILES";       check "perfil de PG válido" "0" "$?"
profile_valid dedicada-999gb "$PG_PROFILES";      check "perfil de PG inválido" "1" "$?"
profile_valid cache-1gb "$REDIS_PROFILES";        check "perfil de Redis válido" "0" "$?"
profile_valid busca-16gb "$MEILI_PROFILES";       check "perfil de Meili válido" "0" "$?"
profile_valid busca-999gb "$MEILI_PROFILES";      check "perfil de Meili inválido" "1" "$?"

printf '\nTodo perfil declarado tem arquivo .env no repositório\n'
for svc_profiles in "postgres:$PG_PROFILES" "redis:$REDIS_PROFILES" "meilisearch:$MEILI_PROFILES"; do
    svc="${svc_profiles%%:*}"
    for prof in ${svc_profiles#*:}; do
        f="$REPO_ROOT/$svc/profiles/$prof.env"
        if [[ -f "$f" ]]; then pass "$svc/profiles/$prof.env"; else fail "FALTA $svc/profiles/$prof.env"; fi
    done
done

printf '\nArquivos de perfil: nenhuma linha malformada\n'
for f in "$REPO_ROOT"/{postgres,redis,meilisearch}/profiles/*.env; do
    bad="$(grep -vE '^([A-Z][A-Z0-9_]*=[^[:space:]]+|#.*|)$' "$f" || true)"
    check "$(basename "$(dirname "$(dirname "$f")")")/$(basename "$f")" "" "$bad"
done

printf '\nPerfis do Postgres: envs reconhecidas pela imagem\n'
known="$(grep -ohE '\$\{PG_[A-Z0-9_]+' "$REPO_ROOT/postgres/generate-config.sh" \
    "$REPO_ROOT/postgres/shm-guard.sh" | sed 's/^\${//' | sort -u)"
# Não são parâmetros do Postgres: são consumidas pelo docker-compose.yml.
compose_vars="PG_MEMORY_LIMIT PG_SHM_BYTES"
for prof in $PG_PROFILES; do
    unknown=""
    while IFS='=' read -r key _; do
        grep -qx "$key" <<< "$known" && continue
        grep -qw "$key" <<< "$compose_vars" && continue
        unknown+="$key "
    done < <(profile_vars "$REPO_ROOT/postgres/profiles/$prof.env")
    check "$prof: nenhuma env desconhecida" "" "${unknown% }"
done

printf '\nPerfis do Postgres: recursos do container conferem com o guia\n'
# Tabela "Recursos do container" de docs/perfis.md — limite e /dev/shm em bytes.
doc_limits="$(awk -F'|' '/^\| Limite de memória/ {for (i=2;i<=NF;i++) gsub(/ /,"",$i); print $3, $4, $5, $6, $7}' \
    "$REPO_ROOT/postgres/docs/perfis.md" | head -1)"
doc_shm="$(awk -F'|' '/^\| em bytes/ {for (i=2;i<=NF;i++) gsub(/ /,"",$i); print $3, $4, $5, $6, $7}' \
    "$REPO_ROOT/postgres/docs/perfis.md" | head -1)"
i=1
for prof in $PG_PROFILES; do
    f="$REPO_ROOT/postgres/profiles/$prof.env"
    check "$prof: PG_MEMORY_LIMIT = $(echo "$doc_limits" | cut -d' ' -f$i)" \
        "$(echo "$doc_limits" | cut -d' ' -f$i)" \
        "$(grep '^PG_MEMORY_LIMIT=' "$f" | cut -d= -f2)"
    check "$prof: PG_SHM_BYTES = $(echo "$doc_shm" | cut -d' ' -f$i)" \
        "$(echo "$doc_shm" | cut -d' ' -f$i)" \
        "$(grep '^PG_SHM_BYTES=' "$f" | cut -d= -f2)"
    i=$((i + 1))
done

printf '\nPerfis do Postgres: tuning confere com a tabela-resumo do guia\n'
# | perfil | Orçamento | vCPU | shared_buffers | effective_cache_size | work_mem | workers/gather | uso |
while IFS='|' read -r _ nome _ _ sb ecs wm par _; do
    prof="$(echo "$nome" | tr -d ' `')"
    [[ -f "$REPO_ROOT/postgres/profiles/$prof.env" ]] || continue
    f="$REPO_ROOT/postgres/profiles/$prof.env"
    got_sb="$(grep '^PG_SHARED_BUFFERS=' "$f" | cut -d= -f2)"
    got_ecs="$(grep '^PG_EFFECTIVE_CACHE_SIZE=' "$f" | cut -d= -f2)"
    got_wm="$(grep '^PG_WORK_MEM=' "$f" | cut -d= -f2)"
    got_par="$(grep '^PG_MAX_PARALLEL_WORKERS=' "$f" | cut -d= -f2)/$(grep '^PG_MAX_PARALLEL_WORKERS_PER_GATHER=' "$f" | cut -d= -f2)"
    check "$prof: shared_buffers/effective_cache/work_mem/paralelismo" \
        "$(echo "$sb" | tr -d ' ')|$(echo "$ecs" | tr -d ' ')|$(echo "$wm" | tr -d ' ')|$(echo "$par" | tr -d ' ')" \
        "$got_sb|$got_ecs|$got_wm|$got_par"
done < <(grep -E '^\| `dedicada-' "$REPO_ROOT/postgres/docs/perfis.md")

printf '\nPerfis de Redis e Meilisearch: chaves obrigatórias\n'
for prof in $REDIS_PROFILES; do
    f="$REPO_ROOT/redis/profiles/$prof.env"
    missing=""
    for k in REDIS_MAXMEMORY REDIS_MAXMEMORY_POLICY REDIS_MEMORY_LIMIT; do
        grep -q "^$k=" "$f" || missing+="$k "
    done
    check "$prof: chaves presentes" "" "${missing% }"
done
for prof in $MEILI_PROFILES; do
    f="$REPO_ROOT/meilisearch/profiles/$prof.env"
    missing=""
    for k in MEILI_MAX_INDEXING_MEMORY MEILI_MAX_INDEXING_THREADS MEILI_HTTP_PAYLOAD_SIZE_LIMIT MEILI_MEMORY_LIMIT; do
        grep -q "^$k=" "$f" || missing+="$k "
    done
    check "$prof: chaves presentes" "" "${missing% }"
done

printf '\nfetch_profile lê os arquivos do repositório\n'
PROFILES_DIR="$REPO_ROOT"; PG_PROFILE="dedicada-32gb"; REDIS_PROFILE="cache-2gb"; MEILI_PROFILE="busca-4gb"
check "postgres: valor do perfil escolhido" "10GB" "$(fetch_profile postgres | grep '^PG_SHARED_BUFFERS=' | cut -d= -f2)"
check "redis: valor do perfil escolhido" "2gb" "$(fetch_profile redis | grep '^REDIS_MAXMEMORY=' | cut -d= -f2)"
check "meilisearch: valor do perfil escolhido" "2GiB" "$(fetch_profile meilisearch | grep '^MEILI_MAX_INDEXING_MEMORY=' | cut -d= -f2)"

printf '\nCaminhos e volumes\n'
WORKDIR="/opt/brasildatahub"
check "diretório do serviço" "/opt/brasildatahub/services/postgres" "$(service_dir postgres)"
check "volume declarado (pg)" "pg_data" "$(service_volume_key postgres)"
check "volume declarado (redis)" "redis_data" "$(service_volume_key redis)"
check "volume declarado (meili)" "meili_data" "$(service_volume_key meilisearch)"
check "porta interna do pg" "5432" "$(service_internal_port postgres)"
DATA_DIR="/mnt/nvme"; POSTGRES_DATA_DIR=""; REDIS_DATA_DIR=""; MEILI_DATA_DIR=""
check "data dir derivado de --data-dir" "/mnt/nvme/postgres" "$(service_data_dir postgres)"
POSTGRES_DATA_DIR="/srv/pg"
check "data dir com override por serviço" "/srv/pg" "$(service_data_dir postgres)"

printf '\nOs volumes e labels declarados existem nos composes\n'
for svc in postgres redis meilisearch; do
    key="$(service_volume_key "$svc")"
    if grep -qE "^  ${key}:" "$REPO_ROOT/$svc/docker-compose.yml"; then
        pass "$svc declara o volume $key"
    else
        fail "$svc NÃO declara o volume $key"
    fi
    if grep -q "org.brasildatahub.service: $svc" "$REPO_ROOT/$svc/docker-compose.yml"; then
        pass "$svc tem a label"
    else
        fail "$svc sem a label org.brasildatahub.service"
    fi
done

printf '\nAjuda\n'
usage >/dev/null 2>&1
check "usage() não falha" "0" "$?"
check "usage() cita o modo bind" "ok" "$(usage | grep -q -- '--volumes MODE' && echo ok)"
check "usage() cita os perfis em arquivos" "ok" "$(usage | grep -q 'postgres/profiles/' && echo ok)"

printf '\n  %d passaram, %d falharam\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
