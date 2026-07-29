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

printf '\nDetecção de perfil dos vizinhos pela RAM\n'
check "8 GB  → cache-256mb"   "cache-256mb"  "$(detect_redis_profile 8)"
check "13 GB → cache-256mb"   "cache-256mb"  "$(detect_redis_profile 13)"
check "14 GB → cache-512mb"   "cache-512mb"  "$(detect_redis_profile 14)"
check "27 GB → cache-512mb"   "cache-512mb"  "$(detect_redis_profile 27)"
check "28 GB → cache-1gb"     "cache-1gb"    "$(detect_redis_profile 28)"
check "56 GB → cache-2gb"     "cache-2gb"    "$(detect_redis_profile 56)"
check "128 GB → cache-2gb"    "cache-2gb"    "$(detect_redis_profile 128)"

check "8 GB  → busca-512mb"   "busca-512mb"  "$(detect_meili_profile 8)"
check "14 GB → busca-1gb"     "busca-1gb"    "$(detect_meili_profile 14)"
check "28 GB → busca-4gb"     "busca-4gb"    "$(detect_meili_profile 28)"
check "56 GB → busca-16gb"    "busca-16gb"   "$(detect_meili_profile 56)"

# Métricas NÃO escalam com a RAM: a cardinalidade segue o número de alvos, não o
# tamanho do host. Este teste é o que impede alguém de "consertar" isso depois.
METRICS_CONTAINERS="false"
check "métricas: 16 GB → metricas-512mb"  "metricas-512mb" "$(detect_metrics_profile)"
check "métricas: 128 GB → metricas-512mb" "metricas-512mb" "$(detect_metrics_profile)"
METRICS_CONTAINERS="true"
check "métricas com cAdvisor → metricas-2gb" "metricas-2gb" "$(detect_metrics_profile)"
METRICS_CONTAINERS="false"

printf '\nOrçamento dos vizinhos (perfil → GB, arredondado para cima)\n'
check "cache-256mb → 1"     "1"  "$(neighbor_budget_gb cache-256mb)"
check "cache-512mb → 1"     "1"  "$(neighbor_budget_gb cache-512mb)"
check "cache-1gb → 2"       "2"  "$(neighbor_budget_gb cache-1gb)"
check "cache-2gb → 3"       "3"  "$(neighbor_budget_gb cache-2gb)"
check "busca-512mb → 1"     "1"  "$(neighbor_budget_gb busca-512mb)"
check "busca-1gb → 1"       "1"  "$(neighbor_budget_gb busca-1gb)"
check "busca-4gb → 4"       "4"  "$(neighbor_budget_gb busca-4gb)"
check "busca-16gb → 16"     "16" "$(neighbor_budget_gb busca-16gb)"
check "metricas-512mb → 2"  "2"  "$(neighbor_budget_gb metricas-512mb)"
check "metricas-2gb → 4"    "4"  "$(neighbor_budget_gb metricas-2gb)"
check "metricas-8gb → 10"   "10" "$(neighbor_budget_gb metricas-8gb)"
check "perfil desconhecido → 0" "0" "$(neighbor_budget_gb inexistente)"

# metrics_budget_gb delega para neighbor_budget_gb — sem esta checagem, as duas
# tabelas de números poderiam divergir em silêncio.
METRICS_PROFILE="metricas-512mb"; METRICS_CONTAINERS="false"
check "metrics_budget_gb = neighbor_budget_gb" "2" "$(metrics_budget_gb)"
METRICS_CONTAINERS="true"
check "metrics_budget_gb soma o cAdvisor" "3" "$(metrics_budget_gb)"
METRICS_CONTAINERS="false"

printf '\nDimensionamento coordenado cabe na máquina\n'
# O teste que protege a decisão de projeto: para cada tamanho de host, a soma do
# conjunto que o `auto` escolhe precisa caber. É o que impede uma faixa futura de
# reintroduzir o superdimensionamento que existia quando o Postgres era
# detectado pela RAM total, ignorando os vizinhos.
for ram in 16 32 64 128; do
    r="$(detect_redis_profile "$ram")"
    m="$(detect_meili_profile "$ram")"
    viz=$(( $(neighbor_budget_gb "$r") + $(neighbor_budget_gb "$m") \
            + $(neighbor_budget_gb metricas-512mb) ))
    pg="$(detect_pg_profile $(( ram - viz )))"
    total=$(( $(profile_budget_gb "$pg") + viz ))
    if (( total <= ram )); then
        pass "${ram} GB: $pg + $r + $m + métricas = ${total} GB"
    else
        fail "${ram} GB: conjunto soma ${total} GB e NÃO cabe ($pg + $r + $m)"
    fi
done

# Postgres sozinho continua recebendo a máquina inteira — o comportamento de
# antes do dimensionamento coordenado.
check "sem vizinhos, 32 GB → dedicada-32gb"   "dedicada-32gb"  "$(detect_pg_profile 32)"
check "sem vizinhos, 128 GB → dedicada-128gb" "dedicada-128gb" "$(detect_pg_profile 128)"

printf '\nOrçamento do perfil (nome → GB)\n'
check "dedicada-8gb → 8"     "8"   "$(profile_budget_gb dedicada-8gb)"
check "dedicada-16gb → 16"   "16"  "$(profile_budget_gb dedicada-16gb)"
check "dedicada-128gb → 128" "128" "$(profile_budget_gb dedicada-128gb)"

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
    # `(...)?$` e não `(...|)$`: a alternativa vazia é rejeitada por alguns greps
    # (o ugrep, comum no macOS via brew, sai com rc=2) — e aí `bad` ficava vazio
    # e o teste passava sem verificar nada. Semântica idêntica, portável.
    bad="$(grep -vE '^([A-Z][A-Z0-9_]*=[^[:space:]]+|#.*)?$' "$f" || true)"
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
# A 8ª coluna entrou com `compartilhada-14gb`; a ordem das colunas da tabela
# tem de seguir a de PG_PROFILES, e é isso que este bloco afirma.
doc_limits="$(awk -F'|' '/^\| Limite de memória/ {for (i=2;i<=NF;i++) gsub(/ /,"",$i); print $3, $4, $5, $6, $7, $8}' \
    "$REPO_ROOT/postgres/docs/perfis.md" | head -1)"
doc_shm="$(awk -F'|' '/^\| em bytes/ {for (i=2;i<=NF;i++) gsub(/ /,"",$i); print $3, $4, $5, $6, $7, $8}' \
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

printf '\nObservabilidade: perfis\n'
profile_valid metricas-512mb "$METRICS_PROFILES"; check "perfil de métricas válido" "0" "$?"
profile_valid metricas-999gb "$METRICS_PROFILES"; check "perfil de métricas inválido" "1" "$?"
check "service_profile monitoring" "metricas-512mb" "$(METRICS_PROFILE=metricas-512mb; service_profile monitoring)"

for prof in $METRICS_PROFILES; do
    f="$REPO_ROOT/monitoring/profiles/$prof.env"
    if [[ -f "$f" ]]; then pass "monitoring/profiles/$prof.env"; else fail "FALTA monitoring/profiles/$prof.env"; fi
done

for f in "$REPO_ROOT"/monitoring/profiles/*.env; do
    # `(...)?$` e não `(...|)$`: a alternativa vazia é rejeitada por alguns greps
    # (o ugrep, comum no macOS via brew, sai com rc=2) — e aí `bad` ficava vazio
    # e o teste passava sem verificar nada. Semântica idêntica, portável.
    bad="$(grep -vE '^([A-Z][A-Z0-9_]*=[^[:space:]]+|#.*)?$' "$f" || true)"
    check "monitoring/$(basename "$f"): nenhuma linha malformada" "" "$bad"
    # Retenção por tempo SEM retenção por tamanho é o furo clássico: um pico de
    # cardinalidade enche o disco que o Prometheus divide com o Postgres.
    faltando=""
    for chave in PROM_RETENTION_TIME PROM_RETENTION_SIZE PROM_MEMORY_LIMIT GRAFANA_MEMORY_LIMIT; do
        grep -qE "^${chave}=" "$f" || faltando+="$chave "
    done
    check "monitoring/$(basename "$f"): chaves obrigatórias" "" "${faltando% }"
done

printf '\nObservabilidade: guardas dos overlays de métricas\n'
for svc in postgres redis meilisearch; do
    f="$REPO_ROOT/$svc/docker-compose.metrics.yml"
    if [[ ! -f "$f" ]]; then fail "FALTA $svc/docker-compose.metrics.yml"; continue; fi

    # O exporter NUNCA pode publicar porta: /metrics não tem autenticação e o do
    # Postgres entrega pg_settings_* inteiro. Ele é alcançado só pela rede
    # bdh_metrics. É o tipo de linha que alguém acrescenta "para debugar".
    if grep -qE '^\s+ports:' "$f"; then
        fail "$svc/docker-compose.metrics.yml declara ports: (exporter não pode publicar porta)"
    else
        pass "$svc: overlay não publica porta"
    fi

    # Label PRÓPRIA: infra-setup.sh e `bdh verify` filtram containers por
    # `label=org.brasildatahub.service=<svc> | head -1`. Com a label colidindo, o
    # `bdh verify postgres` inspecionaria o exporter.
    if grep -qE "org\.brasildatahub\.service: $svc\$" "$f"; then
        fail "$svc/docker-compose.metrics.yml usa a label do serviço base"
    else
        pass "$svc: overlay usa label própria"
    fi

    # Sem `external: true`: com ele, um `docker network prune` faria o `up` do
    # próprio serviço de DADOS falhar por rede inexistente. Os comentários do
    # arquivo explicam justamente isso e citam o termo, daí ignorá-los.
    if grep -vE '^\s*#' "$f" | grep -q 'external: true'; then
        fail "$svc/docker-compose.metrics.yml declara a rede como external"
    elif grep -qE '^\s+bdh_metrics:' "$f"; then
        pass "$svc: rede bdh_metrics sem external"
    else
        fail "$svc/docker-compose.metrics.yml não declara a rede bdh_metrics"
    fi
done

# A senha do exporter do Postgres vive em .env.metrics, e não no .env: qualquer
# variável a mais no .env muda o hash do serviço e o Compose RECRIA o banco.
if grep -q 'PG_METRICS_PASSWORD' "$REPO_ROOT/postgres/docker-compose.metrics.yml"; then
    fail "overlay do Postgres interpola PG_METRICS_PASSWORD do .env (recriaria o banco)"
else
    pass "overlay do Postgres lê a senha de .env.metrics, não do .env"
fi

printf '\nFirewall: nunca esvaziar sem repovoar\n'
# O defeito que este bloco trava: a versão anterior de `configure_firewall`
# fazia `iptables -F DOCKER-USER` ANTES de checar ALLOW_FROM. Numa execução sem
# a flag — o caso de `--metrics-only` sem repetir as flags da instalação — o
# firewall dos containers era apagado e não reconstruído, e as três portas de
# dados voltavam a aceitar conexão de qualquer origem. Em silêncio: `ufw status`
# segue `active`, porque a DOCKER-USER não aparece ali.
trecho_fw="$(awk '/^configure_firewall\(\)/,/^}/' "$REPO_ROOT/infra-setup.sh")"
linha_flush="$(printf '%s\n' "$trecho_fw" | grep -n 'iptables -F DOCKER-USER' | head -1 | cut -d: -f1)"
linha_guarda="$(printf '%s\n' "$trecho_fw" | grep -n 'if \[\[ -z "\$ALLOW_FROM" \]\]' | tail -1 | cut -d: -f1)"
if [[ -n "$linha_flush" && -n "$linha_guarda" && "$linha_guarda" -lt "$linha_flush" ]]; then
    pass "o flush da DOCKER-USER só acontece DEPOIS da guarda de ALLOW_FROM"
else
    fail "iptables -F DOCKER-USER roda antes da guarda — o firewall regride em silêncio"
fi
if printf '%s\n' "$trecho_fw" | grep -q 'PRESERVADA'; then
    pass "sem --allow-from, a chain existente é preservada e o aviso diz isso"
else
    fail "sem --allow-from não há aviso de que a chain foi preservada"
fi

printf '\nObservabilidade: coleta remota\n'
# A regra "exporter não publica porta" (verificada acima) vale para o caso em
# que Prometheus e serviço dividem host. Esta operação é a exceção: Prometheus
# no bdh-apps, dados no bdh-data, sem rede privada. A exceção vive em arquivos
# SEPARADOS, e o que se afirma aqui é que ela continua exigindo uma decisão.
for svc in postgres redis; do
    f="$REPO_ROOT/$svc/docker-compose.metrics-remote.yml"
    if [[ ! -f "$f" ]]; then fail "FALTA $svc/docker-compose.metrics-remote.yml"; continue; fi
    if grep -q 'METRICS_BIND_IP:?' "$f"; then
        pass "$svc/metrics-remote exige METRICS_BIND_IP explícito (sem default)"
    else
        fail "$svc/metrics-remote tem default para METRICS_BIND_IP — 0.0.0.0 acidental publica o exporter"
    fi
done
if grep -q 'METRICS_BIND_IP:?' "$REPO_ROOT/monitoring/docker-compose.remote.yml"; then
    pass "monitoring/remote exige METRICS_BIND_IP explícito"
else
    fail "monitoring/remote tem default para METRICS_BIND_IP"
fi

printf '\nObservabilidade: compose do monitoring\n'
mon="$REPO_ROOT/monitoring/docker-compose.yml"
# Nenhum dos três tem autenticação: publicar o Prometheus em 0.0.0.0 expõe
# /api/v1/admin/tsdb/*, e publicar o Alertmanager entrega a API de silences —
# com a qual se cala qualquer alerta desta stack.
check "Grafana/Prometheus/Alertmanager em loopback por default" "3" \
    "$(grep -cE '\$\{MONITORING_BIND_IP:-127\.0\.0\.1\}' "$mon")"
if grep -q 'BIND_IP:-0.0.0.0' "$mon"; then
    fail "monitoring usa BIND_IP dos serviços de dados (default 0.0.0.0)"
else
    pass "monitoring usa MONITORING_BIND_IP, separada de BIND_IP"
fi
# Só o Prometheus leva o nome curto: o wait de healthcheck faz `head -1` sobre
# os containers com esta label.
check "label 'monitoring' aparece uma única vez" "1" \
    "$(grep -cE 'org\.brasildatahub\.service: monitoring$' "$mon")"

printf '\nAjuda\n'
check "usage() cita a recusa de perfil grande demais" "ok" "$(usage | grep -q -- '--allow-oversized-profile' && echo ok)"
check "usage() cita --metrics" "ok" "$(usage | grep -q -- '--metrics ' && echo ok)"
check "usage() cita --metrics-only" "ok" "$(usage | grep -q -- '--metrics-only' && echo ok)"
check "usage() cita auto no Redis" "ok" "$(usage | grep -q 'auto | cache-256mb' && echo ok)"
check "usage() cita auto no Meili" "ok" "$(usage | grep -q 'auto | busca-512mb' && echo ok)"
check "usage() cita auto nas métricas" "ok" "$(usage | grep -q 'auto | metricas-512mb' && echo ok)"
check "usage() explica o dimensionamento coordenado" "ok" "$(usage | grep -q 'COORDENADO' && echo ok)"
usage >/dev/null 2>&1
check "usage() não falha" "0" "$?"
check "usage() cita o modo bind" "ok" "$(usage | grep -q -- '--volumes MODE' && echo ok)"
check "usage() cita os perfis em arquivos" "ok" "$(usage | grep -q 'postgres/profiles/' && echo ok)"

printf '\n  %d passaram, %d falharam\n\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
