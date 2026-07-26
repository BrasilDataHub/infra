#!/usr/bin/env bash
# Testes de infra-setup.sh — carregam o script como biblioteca
# (BDH_SETUP_LIB_ONLY=1) e exercitam a lógica que decide o que vai para o
# servidor. O teste mais importante é o último: garante que os blocos de env
# embutidos no script não divergem de postgres/docs/perfis.md.
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

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=infra-setup.sh
BDH_SETUP_LIB_ONLY=1 . "$REPO_ROOT/infra-setup.sh"
# O script carregado ativa `set -e` e um trap ERR; nos testes queremos avaliar
# falhas em vez de abortar no primeiro comando que retorna != 0.
set +e
trap - ERR

printf '\nDetecção de perfil pela RAM\n'
check "8 GB  → dedicada-8gb"    "dedicada-8gb"    "$(detect_pg_profile 8)"
check "15 GB → dedicada-16gb"   "dedicada-16gb"   "$(detect_pg_profile 15)"
check "31 GB → dedicada-32gb"   "dedicada-32gb"   "$(detect_pg_profile 31)"
check "62 GB → dedicada-64gb"   "dedicada-64gb"   "$(detect_pg_profile 62)"
check "125 GB → dedicada-128gb" "dedicada-128gb"  "$(detect_pg_profile 125)"
check "2 GB → menor perfil"     "dedicada-8gb"    "$(detect_pg_profile 2)"
check "13 GB não sobe de perfil" "dedicada-8gb"   "$(detect_pg_profile 13)"

printf '\nRecursos do container por perfil\n'
check "8gb"   "7G 1073741824"   "$(profile_resources dedicada-8gb)"
check "16gb"  "14G 2147483648"  "$(profile_resources dedicada-16gb)"
check "32gb"  "28G 4294967296"  "$(profile_resources dedicada-32gb)"
check "64gb"  "56G 4294967296"  "$(profile_resources dedicada-64gb)"
check "128gb" "120G 8589934592" "$(profile_resources dedicada-128gb)"
profile_resources perfil-inexistente >/dev/null 2>&1
check "perfil inválido falha" "1" "$?"

printf '\nCaminhos e volumes\n'
WORKDIR="/opt/brasildatahub"
check "diretório do serviço" "/opt/brasildatahub/services/postgres" "$(service_dir postgres)"
check "volume declarado (pg)" "pg_data" "$(service_volume_key postgres)"
check "volume declarado (redis)" "redis_data" "$(service_volume_key redis)"
check "volume declarado (meili)" "meili_data" "$(service_volume_key meilisearch)"
DATA_DIR="/mnt/nvme"; POSTGRES_DATA_DIR=""; REDIS_DATA_DIR=""; MEILI_DATA_DIR=""
check "data dir derivado de --data-dir" "/mnt/nvme/postgres" "$(service_data_dir postgres)"
POSTGRES_DATA_DIR="/srv/pg"
check "data dir com override por serviço" "/srv/pg" "$(service_data_dir postgres)"

printf '\nOs volumes declarados existem nos composes\n'
for svc in postgres redis meilisearch; do
    key="$(service_volume_key "$svc")"
    if grep -qE "^  ${key}:" "$REPO_ROOT/$svc/docker-compose.yml"; then
        printf '  ✓ %s declara o volume %s\n' "$svc" "$key"; PASS=$((PASS + 1))
    else
        printf '  ✗ %s NÃO declara o volume %s\n' "$svc" "$key"; FAIL=$((FAIL + 1))
    fi
done

printf '\nA label consumida pelo bdh/MOTD está nos composes\n'
for svc in postgres redis meilisearch; do
    if grep -q "org.brasildatahub.service: $svc" "$REPO_ROOT/$svc/docker-compose.yml"; then
        printf '  ✓ %s tem a label\n' "$svc"; PASS=$((PASS + 1))
    else
        printf '  ✗ %s sem a label org.brasildatahub.service\n' "$svc"; FAIL=$((FAIL + 1))
    fi
done

printf '\nBlocos de env: formato e cobertura pela imagem\n'
known_envs="$(grep -ohE '\$\{PG_[A-Z0-9_]+' "$REPO_ROOT/postgres/generate-config.sh" \
    "$REPO_ROOT/postgres/shm-guard.sh" | sed 's/^\${//' | sort -u)"
for profile in dedicada-8gb dedicada-16gb dedicada-32gb dedicada-64gb dedicada-128gb; do
    bad_format="$(profile_env_block "$profile" | grep -vE '^PG_[A-Z0-9_]+=[^ ]+$' || true)"
    check "$profile: todas as linhas são KEY=VALUE" "" "$bad_format"
    unknown=""
    while IFS='=' read -r key _; do
        grep -qx "$key" <<< "$known_envs" || unknown+="$key "
    done < <(profile_env_block "$profile")
    check "$profile: nenhuma env desconhecida pela imagem" "" "${unknown% }"
done

printf '\nBlocos de env batem com postgres/docs/perfis.md\n'
for profile in dedicada-8gb dedicada-16gb dedicada-32gb dedicada-64gb dedicada-128gb; do
    from_doc="$(awk -v p="# ===== perfil $profile =====" '
        $0 == p {flag = 1; next}
        flag && /^```$/ {exit}
        flag && /^PG_/ {print}
    ' "$REPO_ROOT/postgres/docs/perfis.md")"
    from_script="$(profile_env_block "$profile")"
    if [[ "$from_doc" == "$from_script" ]]; then
        printf '  ✓ %s idêntico ao guia\n' "$profile"; PASS=$((PASS + 1))
    else
        printf '  ✗ %s DIVERGE do guia:\n' "$profile"
        diff <(printf '%s\n' "$from_doc") <(printf '%s\n' "$from_script") | sed 's/^/      /'
        FAIL=$((FAIL + 1))
    fi
done

printf '\nAjuda\n'
usage >/dev/null 2>&1
check "usage() não falha" "0" "$?"
check "usage() cita o modo bind" "ok" "$(usage | grep -q -- '--volumes MODE' && echo ok)"

printf '\n  %d passaram, %d falharam\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
