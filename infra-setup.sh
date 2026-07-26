#!/usr/bin/env bash
# =============================================================================
# infra-setup.sh — provisiona um VPS para rodar os serviços de dados da
# BrasilDataHub (PostgreSQL, Redis, Meilisearch) com Docker Compose.
#
#   curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/infra/main/infra-setup.sh \
#     | sudo bash -s -- --auto
#
# É OPCIONAL: o fluxo de deploy documentado (postgres/docs/deploy.md) continua
# valendo, e este script só automatiza o caminho comum. Os composes NÃO são
# embutidos aqui — são baixados do próprio repositório, que segue sendo a única
# fonte de verdade.
#
# Alvo: Ubuntu/Debian com systemd. Requer root.
# =============================================================================
set -euo pipefail

SCRIPT_VERSION="1.0.0"

# --- defaults ----------------------------------------------------------------
REPO_SLUG="BrasilDataHub/infra"
REF="main"
WORKDIR="/opt/brasildatahub"
CONF_DIR="/etc/brasildatahub"
TIMEZONE="America/Sao_Paulo"
SERVICES_INPUT="postgres,redis,meilisearch"
POSTGRES_DB="dados"
PG_PROFILE="auto"
VOLUMES_MODE="named"
DATA_DIR="/data"
POSTGRES_DATA_DIR=""
REDIS_DATA_DIR=""
MEILI_DATA_DIR=""
POSTGRES_PASSWORD=""
DADOS_READ_PASSWORD=""
REDIS_PASSWORD=""
MEILI_MASTER_KEY=""
BIND_IP="0.0.0.0"
POSTGRES_PORT="5432"
REDIS_PORT="6379"
MEILI_PORT="7700"
ALLOW_FROM=""
ENABLE_FIREWALL="true"
DOCKER_VERSION=""            # vazio = última do repositório oficial
DOCKER_DATA_ROOT=""
SKIP_SYSTEM_UPDATE="false"
INSTALL_MOTD="true"
AUTO="false"
DRY_RUN="false"
FORCE="false"
WEBHOOK_URL=""

LOG_FILE=""
declare -a SERVICES=()

# --- saída -------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

_log() {
    local line="$1"
    printf '%s\n' "$line"
    [[ -n "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]] && printf '%s %s\n' "$(date -Is)" "$line" >> "$LOG_FILE"
    return 0
}
section() { _log ""; _log "${C_BOLD}${C_BLUE}==> $*${C_RESET}"; }
info()    { _log "    $*"; }
ok()      { _log "    ${C_GREEN}✓${C_RESET} $*"; }
warn()    { _log "    ${C_YELLOW}!${C_RESET} $*"; }
die()     { _log "    ${C_RED}✗ $*${C_RESET}"; notify "error" "$*"; exit 1; }

# Executa (ou apenas mostra, em --dry-run) um comando.
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        _log "    ${C_DIM}[dry-run] $*${C_RESET}"
        return 0
    fi
    "$@"
}

# --- webhook -----------------------------------------------------------------
notify() {
    local status="$1" message="$2"
    [[ -z "$WEBHOOK_URL" ]] && return 0
    [[ "$DRY_RUN" == "true" ]] && return 0
    local payload
    payload=$(printf '{"host":"%s","script":"infra-setup","version":"%s","status":"%s","message":"%s","timestamp":"%s"}' \
        "$(hostname)" "$SCRIPT_VERSION" "$status" "${message//\"/\\\"}" "$(date -Is)")
    # Webhook nunca derruba o provisionamento.
    curl -fsS -m 5 -X POST -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

trap 'notify "failed" "abortado na linha $LINENO"' ERR

# --- ajuda -------------------------------------------------------------------
usage() {
    cat <<'HELP'
infra-setup.sh — provisiona um VPS para os serviços de dados da BrasilDataHub.

USAGE:
    curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/infra/main/infra-setup.sh \
      | sudo bash -s -- [OPTIONS]

    # ou, para revisar antes de executar (recomendado):
    curl -fsSL .../infra-setup.sh -o infra-setup.sh && less infra-setup.sh
    sudo bash infra-setup.sh [OPTIONS]

OPTIONS (geral):
  -h, --help                 Exibe esta ajuda
      --workdir PATH         Raiz da instalação (default: /opt/brasildatahub)
      --timezone TZ          Timezone do sistema (default: America/Sao_Paulo)
      --skip-system-update   Não roda apt update/upgrade
      --auto                 Não-interativo: defaults + senhas geradas
      --dry-run              Mostra o que faria, sem alterar o sistema
  -f, --force                Refaz .env/composes e recria containers
                             (NUNCA remove volumes nem apaga dados)
      --ref REF              Branch/tag do repo de onde baixar os composes (default: main)
      --docker-version VER   Versão do Docker a instalar (ex.: 27.3.1; default: mais recente)
      --docker-data-root PATH  Move o data-root do Docker para PATH
      --no-motd              Não instala a mensagem de login

OPTIONS (serviços):
      --services LIST        postgres,redis,meilisearch (default: todos)
      --postgres-db NOME     Database inicial do Postgres (default: dados)
      --pg-profile PERFIL    auto | dedicada-8gb | dedicada-16gb | dedicada-32gb
                             | dedicada-64gb | dedicada-128gb   (default: auto, pela RAM)

OPTIONS (volumes):
      --volumes MODE         named | bind (default: named)
      --data-dir PATH        Raiz dos dados no modo bind (default: /data);
                             cria PATH/{postgres,redis,meilisearch}
      --postgres-data-dir PATH     Diretório do Postgres (implica --volumes bind)
      --redis-data-dir PATH        Diretório do Redis (implica --volumes bind)
      --meilisearch-data-dir PATH  Diretório do Meilisearch (implica --volumes bind)

OPTIONS (credenciais — se omitidas, são geradas com 32 bytes aleatórios):
      --postgres-password SENHA
      --dados-read-password SENHA   Senha da role de leitura dados_read
      --redis-password SENHA
      --meilisearch-key CHAVE       (mínimo 16 bytes)

OPTIONS (rede e firewall):
      --bind-ip IP           Interface de publicação (default: 0.0.0.0 — todas)
      --postgres-port N      (default: 5432)
      --redis-port N         (default: 6379)
      --meilisearch-port N   (default: 7700)
      --allow-from CIDR[,CIDR]  Restringe o firewall a estas origens
                             (default: sem restrição — qualquer origem)
      --no-firewall          Não configura o ufw

OPTIONS (webhook):
      --webhook-url URL      Notifica progresso e erros (POST JSON)

DEPOIS DE RODAR:
    /opt/brasildatahub/secrets/credentials.env   todas as credenciais (chmod 600)
    bdh status                                   estado dos serviços
    bdh --help                                   demais comandos

Documentação: https://github.com/BrasilDataHub/infra
HELP
}

# --- parse -------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --workdir) WORKDIR="$2"; shift 2 ;;
        --timezone) TIMEZONE="$2"; shift 2 ;;
        --skip-system-update) SKIP_SYSTEM_UPDATE="true"; shift ;;
        --auto|--non-interactive) AUTO="true"; shift ;;
        --dry-run) DRY_RUN="true"; shift ;;
        -f|--force) FORCE="true"; shift ;;
        --ref) REF="$2"; shift 2 ;;
        --docker-version) DOCKER_VERSION="$2"; shift 2 ;;
        --docker-data-root) DOCKER_DATA_ROOT="$2"; shift 2 ;;
        --no-motd) INSTALL_MOTD="false"; shift ;;
        --services) SERVICES_INPUT="$2"; shift 2 ;;
        --postgres-db) POSTGRES_DB="$2"; shift 2 ;;
        --pg-profile) PG_PROFILE="$2"; shift 2 ;;
        --volumes) VOLUMES_MODE="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; VOLUMES_MODE="bind"; shift 2 ;;
        --postgres-data-dir) POSTGRES_DATA_DIR="$2"; VOLUMES_MODE="bind"; shift 2 ;;
        --redis-data-dir) REDIS_DATA_DIR="$2"; VOLUMES_MODE="bind"; shift 2 ;;
        --meilisearch-data-dir) MEILI_DATA_DIR="$2"; VOLUMES_MODE="bind"; shift 2 ;;
        --postgres-password) POSTGRES_PASSWORD="$2"; shift 2 ;;
        --dados-read-password) DADOS_READ_PASSWORD="$2"; shift 2 ;;
        --redis-password) REDIS_PASSWORD="$2"; shift 2 ;;
        --meilisearch-key) MEILI_MASTER_KEY="$2"; shift 2 ;;
        --bind-ip) BIND_IP="$2"; shift 2 ;;
        --postgres-port) POSTGRES_PORT="$2"; shift 2 ;;
        --redis-port) REDIS_PORT="$2"; shift 2 ;;
        --meilisearch-port) MEILI_PORT="$2"; shift 2 ;;
        --allow-from) ALLOW_FROM="$2"; shift 2 ;;
        --enable-firewall) ENABLE_FIREWALL="true"; shift ;;
        --no-firewall) ENABLE_FIREWALL="false"; shift ;;
        --webhook-url) WEBHOOK_URL="$2"; shift 2 ;;
        *) printf 'Opção desconhecida: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

# Origem dos composes. BDH_RAW_BASE existe para forks e para os testes de
# integração; o normal é usar o repositório oficial.
RAW_BASE="${BDH_RAW_BASE:-https://raw.githubusercontent.com/${REPO_SLUG}/${REF}}"

# =============================================================================
# helpers
# =============================================================================
gen_secret() { openssl rand -base64 36 | tr -d '\n/+=' | cut -c1-32; }

# Pergunta algo ao usuário. Lê de /dev/tty porque o stdin costuma ser o pipe do
# curl — sem isso, `curl | bash` responderia tudo em branco.
ask() {
    local prompt="$1" default="$2" answer=""
    if [[ "$AUTO" == "true" || ! -r /dev/tty ]]; then
        printf '%s' "$default"; return 0
    fi
    read -r -p "    ${prompt} [${default}]: " answer < /dev/tty || answer=""
    printf '%s' "${answer:-$default}"
}

service_selected() {
    local needle="$1" s
    for s in "${SERVICES[@]}"; do [[ "$s" == "$needle" ]] && return 0; done
    return 1
}

service_dir() { printf '%s/services/%s' "$WORKDIR" "$1"; }

# Diretório de dados de um serviço no modo bind.
service_data_dir() {
    case "$1" in
        postgres)    printf '%s' "${POSTGRES_DATA_DIR:-$DATA_DIR/postgres}" ;;
        redis)       printf '%s' "${REDIS_DATA_DIR:-$DATA_DIR/redis}" ;;
        meilisearch) printf '%s' "${MEILI_DATA_DIR:-$DATA_DIR/meilisearch}" ;;
    esac
}

# Nome do volume declarado no compose de cada serviço (ver docker-compose.yml).
service_volume_key() {
    case "$1" in
        postgres) printf 'pg_data' ;;
        redis) printf 'redis_data' ;;
        meilisearch) printf 'meili_data' ;;
    esac
}

service_port() {
    case "$1" in
        postgres) printf '%s' "$POSTGRES_PORT" ;;
        redis) printf '%s' "$REDIS_PORT" ;;
        meilisearch) printf '%s' "$MEILI_PORT" ;;
    esac
}

# Perfil do Postgres a partir da RAM total (ou do valor em GiB passado como
# argumento, usado pelos testes). Margem generosa porque a RAM reportada é
# sempre menor que a nominal do plano.
# shellcheck disable=SC2120  # o argumento é opcional: em produção lê /proc/meminfo
detect_pg_profile() {
    local ram_gb="${1:-}"
    [[ -z "$ram_gb" ]] && ram_gb=$(awk '/MemTotal/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo)
    if   (( ram_gb >= 120 )); then printf 'dedicada-128gb'
    elif (( ram_gb >= 56 ));  then printf 'dedicada-64gb'
    elif (( ram_gb >= 28 ));  then printf 'dedicada-32gb'
    elif (( ram_gb >= 14 ));  then printf 'dedicada-16gb'
    else                            printf 'dedicada-8gb'
    fi
}

# Recursos do container por perfil: limite de memória e /dev/shm em bytes.
# Fonte: postgres/docs/perfis.md#recursos-do-container
profile_resources() {
    case "$1" in
        dedicada-8gb)   printf '7G 1073741824' ;;
        dedicada-16gb)  printf '14G 2147483648' ;;
        dedicada-32gb)  printf '28G 4294967296' ;;
        dedicada-64gb)  printf '56G 4294967296' ;;
        dedicada-128gb) printf '120G 8589934592' ;;
        *) return 1 ;;
    esac
}

# Bloco de envs PG_* do perfil. Fonte: postgres/docs/perfis.md (mantenha em
# sincronia com o guia — ele é a referência, este é um espelho).
profile_env_block() {
    case "$1" in
    dedicada-8gb) cat <<'EOF'
PG_MAX_CONNECTIONS=100
PG_SHARED_BUFFERS=2GB
PG_EFFECTIVE_CACHE_SIZE=6GB
PG_WORK_MEM=16MB
PG_HASH_MEM_MULTIPLIER=2.0
PG_MAINTENANCE_WORK_MEM=512MB
PG_AUTOVACUUM_WORK_MEM=-1
PG_EFFECTIVE_IO_CONCURRENCY=200
PG_MAINTENANCE_IO_CONCURRENCY=200
PG_DEFAULT_STATISTICS_TARGET=100
PG_MAX_WORKER_PROCESSES=4
PG_MAX_PARALLEL_WORKERS=4
PG_MAX_PARALLEL_WORKERS_PER_GATHER=2
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=2
PG_PARALLEL_SETUP_COST=1000
PG_PARALLEL_TUPLE_COST=0.1
PG_MAX_WAL_SIZE=8GB
PG_MIN_WAL_SIZE=2GB
PG_WAL_BUFFERS=32MB
PG_AUTOVACUUM_MAX_WORKERS=3
PG_AUTOVACUUM_NAPTIME=30s
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.1
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.05
PG_AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR=0.1
PG_AUTOVACUUM_VACUUM_COST_LIMIT=1000
PG_STAT_STATEMENTS_MAX=5000
EOF
    ;;
    dedicada-16gb) cat <<'EOF'
PG_MAX_CONNECTIONS=100
PG_SHARED_BUFFERS=5GB
PG_EFFECTIVE_CACHE_SIZE=12GB
PG_WORK_MEM=32MB
PG_HASH_MEM_MULTIPLIER=2.0
PG_MAINTENANCE_WORK_MEM=1GB
PG_AUTOVACUUM_WORK_MEM=-1
PG_EFFECTIVE_IO_CONCURRENCY=200
PG_MAINTENANCE_IO_CONCURRENCY=200
PG_DEFAULT_STATISTICS_TARGET=100
PG_MAX_WORKER_PROCESSES=8
PG_MAX_PARALLEL_WORKERS=8
PG_MAX_PARALLEL_WORKERS_PER_GATHER=4
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=2
PG_PARALLEL_SETUP_COST=1000
PG_PARALLEL_TUPLE_COST=0.1
PG_MAX_WAL_SIZE=16GB
PG_MIN_WAL_SIZE=4GB
PG_WAL_BUFFERS=32MB
PG_AUTOVACUUM_MAX_WORKERS=4
PG_AUTOVACUUM_NAPTIME=30s
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.1
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.05
PG_AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR=0.1
PG_AUTOVACUUM_VACUUM_COST_LIMIT=2000
PG_STAT_STATEMENTS_MAX=5000
EOF
    ;;
    dedicada-32gb) cat <<'EOF'
PG_MAX_CONNECTIONS=150
PG_SHARED_BUFFERS=10GB
PG_EFFECTIVE_CACHE_SIZE=24GB
PG_WORK_MEM=48MB
PG_HASH_MEM_MULTIPLIER=2.0
PG_MAINTENANCE_WORK_MEM=2GB
PG_AUTOVACUUM_WORK_MEM=512MB
PG_EFFECTIVE_IO_CONCURRENCY=200
PG_MAINTENANCE_IO_CONCURRENCY=200
PG_DEFAULT_STATISTICS_TARGET=200
PG_MAX_WORKER_PROCESSES=8
PG_MAX_PARALLEL_WORKERS=8
PG_MAX_PARALLEL_WORKERS_PER_GATHER=4
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=4
PG_PARALLEL_SETUP_COST=500
PG_PARALLEL_TUPLE_COST=0.05
PG_MAX_WAL_SIZE=32GB
PG_MIN_WAL_SIZE=8GB
PG_WAL_BUFFERS=64MB
PG_AUTOVACUUM_MAX_WORKERS=4
PG_AUTOVACUUM_NAPTIME=15s
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.05
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.02
PG_AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR=0.1
PG_AUTOVACUUM_VACUUM_COST_LIMIT=4000
PG_STAT_STATEMENTS_MAX=10000
EOF
    ;;
    dedicada-64gb) cat <<'EOF'
PG_MAX_CONNECTIONS=200
PG_SHARED_BUFFERS=24GB
PG_EFFECTIVE_CACHE_SIZE=48GB
PG_WORK_MEM=64MB
PG_HASH_MEM_MULTIPLIER=3.0
PG_MAINTENANCE_WORK_MEM=4GB
PG_AUTOVACUUM_WORK_MEM=1GB
PG_EFFECTIVE_IO_CONCURRENCY=300
PG_MAINTENANCE_IO_CONCURRENCY=300
PG_DEFAULT_STATISTICS_TARGET=200
PG_MAX_WORKER_PROCESSES=16
PG_MAX_PARALLEL_WORKERS=16
PG_MAX_PARALLEL_WORKERS_PER_GATHER=4
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=4
PG_PARALLEL_SETUP_COST=500
PG_PARALLEL_TUPLE_COST=0.05
PG_MAX_WAL_SIZE=48GB
PG_MIN_WAL_SIZE=8GB
PG_WAL_BUFFERS=64MB
PG_AUTOVACUUM_MAX_WORKERS=6
PG_AUTOVACUUM_NAPTIME=15s
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.02
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.01
PG_AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR=0.05
PG_AUTOVACUUM_VACUUM_COST_LIMIT=6000
PG_STAT_STATEMENTS_MAX=10000
EOF
    ;;
    dedicada-128gb) cat <<'EOF'
PG_MAX_CONNECTIONS=300
PG_SHARED_BUFFERS=48GB
PG_EFFECTIVE_CACHE_SIZE=96GB
PG_WORK_MEM=96MB
PG_HASH_MEM_MULTIPLIER=3.0
PG_MAINTENANCE_WORK_MEM=8GB
PG_AUTOVACUUM_WORK_MEM=2GB
PG_EFFECTIVE_IO_CONCURRENCY=300
PG_MAINTENANCE_IO_CONCURRENCY=300
PG_DEFAULT_STATISTICS_TARGET=200
PG_MAX_WORKER_PROCESSES=24
PG_MAX_PARALLEL_WORKERS=24
PG_MAX_PARALLEL_WORKERS_PER_GATHER=6
PG_MAX_PARALLEL_MAINTENANCE_WORKERS=6
PG_PARALLEL_SETUP_COST=500
PG_PARALLEL_TUPLE_COST=0.05
PG_MAX_WAL_SIZE=64GB
PG_MIN_WAL_SIZE=16GB
PG_WAL_BUFFERS=64MB
PG_AUTOVACUUM_MAX_WORKERS=6
PG_AUTOVACUUM_NAPTIME=15s
PG_AUTOVACUUM_VACUUM_SCALE_FACTOR=0.02
PG_AUTOVACUUM_ANALYZE_SCALE_FACTOR=0.01
PG_AUTOVACUUM_VACUUM_INSERT_SCALE_FACTOR=0.05
PG_AUTOVACUUM_VACUUM_COST_LIMIT=8000
PG_STAT_STATEMENTS_MAX=10000
EOF
    ;;
    esac
}

# =============================================================================
# etapas
# =============================================================================

validate_and_prompt() {
    section "Configuração"

    [[ "$DRY_RUN" == "true" ]] && warn "modo --dry-run: nada será alterado"
    if [[ "$AUTO" != "true" && ! -r /dev/tty ]]; then
        warn "sem terminal interativo (execução por pipe) — assumindo --auto"
        AUTO="true"
    fi

    SERVICES_INPUT="$(ask "Serviços a provisionar (vírgula)" "$SERVICES_INPUT")"
    IFS=',' read -r -a SERVICES <<< "$SERVICES_INPUT"
    local s
    for s in "${SERVICES[@]}"; do
        case "$s" in
            postgres|redis|meilisearch) ;;
            *) die "serviço desconhecido: '$s' (use postgres, redis ou meilisearch)" ;;
        esac
    done
    [[ ${#SERVICES[@]} -eq 0 ]] && die "nenhum serviço selecionado"

    if service_selected postgres; then
        PG_PROFILE="$(ask "Perfil do Postgres (auto detecta pela RAM)" "$PG_PROFILE")"
        # shellcheck disable=SC2119  # sem argumento = detectar pela RAM do host
        [[ "$PG_PROFILE" == "auto" ]] && PG_PROFILE="$(detect_pg_profile)"
        profile_resources "$PG_PROFILE" >/dev/null || die "perfil inválido: $PG_PROFILE"
    fi

    VOLUMES_MODE="$(ask "Modo de volume (named|bind)" "$VOLUMES_MODE")"
    case "$VOLUMES_MODE" in
        named) ;;
        bind) DATA_DIR="$(ask "Raiz dos diretórios de dados" "$DATA_DIR")" ;;
        *) die "modo de volume inválido: $VOLUMES_MODE (use named ou bind)" ;;
    esac

    BIND_IP="$(ask "IP de publicação (0.0.0.0 = todas as interfaces)" "$BIND_IP")"
    ALLOW_FROM="$(ask "Restringir firewall a quais origens? (CIDRs, vazio = qualquer)" "$ALLOW_FROM")"

    local port
    for s in "${SERVICES[@]}"; do
        port="$(service_port "$s")"
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            die "porta inválida para $s: $port"
        fi
    done

    if service_selected meilisearch && [[ -n "$MEILI_MASTER_KEY" && ${#MEILI_MASTER_KEY} -lt 16 ]]; then
        die "--meilisearch-key precisa de no mínimo 16 bytes (MEILI_ENV=production)"
    fi

    info "serviços ....... ${SERVICES[*]}"
    service_selected postgres && info "perfil PG ...... $PG_PROFILE"
    info "volumes ........ $VOLUMES_MODE"
    info "publicação ..... ${BIND_IP} (firewall: ${ALLOW_FROM:-qualquer origem})"
    info "workdir ........ $WORKDIR"
}

preflight() {
    section "Pré-checagens"
    [[ $EUID -eq 0 ]] || die "execute como root (sudo)"
    [[ -f /etc/os-release ]] || die "não foi possível identificar a distribuição"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *debian*|*ubuntu*) ok "distribuição suportada: ${PRETTY_NAME:-$ID}" ;;
        *) die "só Ubuntu/Debian são suportados (encontrado: ${PRETTY_NAME:-$ID})" ;;
    esac
    command -v systemctl >/dev/null || die "systemd é necessário"

    if [[ -f "$WORKDIR/.setup-state" && "$FORCE" != "true" ]]; then
        die "instalação existente em $WORKDIR — use -f para refazer a configuração (volumes preservados)"
    fi
    if [[ -f "$WORKDIR/.setup-state" ]]; then
        local previous
        previous="$(awk -F= '/^VOLUMES_MODE=/ {print $2}' "$WORKDIR/.setup-state")"
        if [[ -n "$previous" && "$previous" != "$VOLUMES_MODE" ]]; then
            die "a instalação atual usa volumes '$previous' e você pediu '$VOLUMES_MODE'.
       Trocar de modo NÃO move dados — o serviço subiria vazio. Copie os dados
       antes (docker run --rm -v <origem>:/from -v <destino>:/to alpine cp -a /from/. /to/)
       e só então rode de novo."
        fi
    fi
    ok "pré-checagens concluídas"
    notify "started" "provisionamento iniciado (${SERVICES[*]})"
}

setup_system() {
    section "Sistema"
    run timedatectl set-timezone "$TIMEZONE" && ok "timezone: $TIMEZONE"

    export DEBIAN_FRONTEND=noninteractive
    if [[ "$SKIP_SYSTEM_UPDATE" == "true" ]]; then
        warn "atualização do sistema ignorada (--skip-system-update)"
        run apt-get update -qq
    else
        info "apt update && apt upgrade (pode demorar)"
        run apt-get update -qq
        run apt-get upgrade -y -qq
        ok "sistema atualizado"
    fi
    run apt-get install -y -qq ca-certificates curl gnupg openssl ufw
    # column: usado pelo `bdh status`. O pacote mudou de nome entre releases.
    run apt-get install -y -qq bsdextrautils || run apt-get install -y -qq bsdmainutils || true
    ok "pacotes base instalados"
    notify "progress" "sistema preparado"
}

install_docker() {
    section "Docker"
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
        ok "já instalado: $(docker --version | cut -d, -f1), $(docker compose version --short 2>/dev/null || echo plugin)"
        run systemctl enable --now docker
        return 0
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    local distro="${ID}" codename="${VERSION_CODENAME:-}"
    info "instalando do repositório oficial ($distro/$codename)"
    run install -m 0755 -d /etc/apt/keyrings
    if [[ "$DRY_RUN" != "true" ]]; then
        curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
            "$(dpkg --print-architecture)" "$distro" "$codename" > /etc/apt/sources.list.d/docker.list
    fi
    run apt-get update -qq

    local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
    if [[ -n "$DOCKER_VERSION" ]]; then
        local resolved
        resolved="$(apt-cache madison docker-ce 2>/dev/null | awk -v v="$DOCKER_VERSION" '$3 ~ v {print $3; exit}')"
        if [[ -n "$resolved" ]]; then
            info "fixando docker-ce=$resolved"
            pkgs=("docker-ce=$resolved" "docker-ce-cli=$resolved" containerd.io docker-buildx-plugin docker-compose-plugin)
        else
            warn "versão $DOCKER_VERSION não encontrada no repositório — instalando a mais recente"
        fi
    fi
    run apt-get install -y -qq "${pkgs[@]}"
    run systemctl enable --now docker
    ok "Docker instalado"
    notify "progress" "docker instalado"
}

configure_docker_data_root() {
    section "Armazenamento do Docker"
    local root
    root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"

    if [[ -n "$DOCKER_DATA_ROOT" ]]; then
        if [[ "$root" == "$DOCKER_DATA_ROOT" ]]; then
            ok "data-root já é $DOCKER_DATA_ROOT"
        else
            info "movendo data-root: $root → $DOCKER_DATA_ROOT"
            run mkdir -p "$DOCKER_DATA_ROOT"
            run systemctl stop docker
            if [[ "$DRY_RUN" != "true" ]]; then
                if [[ -f /etc/docker/daemon.json ]]; then
                    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak-$(date +%s)"
                fi
                mkdir -p /etc/docker
                printf '{\n  "data-root": "%s"\n}\n' "$DOCKER_DATA_ROOT" > /etc/docker/daemon.json
                rsync -aHAX --delete "$root/" "$DOCKER_DATA_ROOT/" 2>/dev/null || cp -a "$root/." "$DOCKER_DATA_ROOT/"
            fi
            run systemctl start docker
            ok "data-root em $DOCKER_DATA_ROOT (o anterior foi mantido em $root)"
        fi
        return 0
    fi

    # Sem a flag: apenas informa, porque é onde os volumes nomeados vivem.
    local device rota
    device="$(findmnt -no SOURCE --target "$root" 2>/dev/null || echo '?')"
    rota="$(lsblk -no ROTA "$device" 2>/dev/null | head -1 | tr -d ' ' || echo '?')"
    info "data-root: $root ($device, $(df -h --output=avail "$root" 2>/dev/null | tail -1 | tr -d ' ') livres)"
    if [[ "$rota" == "1" ]]; then
        warn "o disco do data-root parece ser rotacional (ROTA=1) — os perfis assumem NVMe."
        warn "use --docker-data-root /caminho/no/nvme, ou --volumes bind, ou mova o data-root à mão."
    else
        ok "disco não rotacional (ROTA=${rota:-?})"
    fi
}

create_layout() {
    section "Layout em $WORKDIR"
    local s dir
    run mkdir -p "$WORKDIR/services" "$WORKDIR/secrets" "$CONF_DIR"
    run chmod 750 "$WORKDIR" "$WORKDIR/secrets"
    LOG_FILE="$WORKDIR/setup.log"

    for s in "${SERVICES[@]}"; do
        dir="$(service_dir "$s")"
        run mkdir -p "$dir"
        if [[ "$DRY_RUN" != "true" ]]; then
            curl -fsSL "${RAW_BASE}/${s}/docker-compose.yml" -o "$dir/docker-compose.yml" \
                || die "falha ao baixar ${RAW_BASE}/${s}/docker-compose.yml"
            grep -q 'ghcr.io/brasildatahub' "$dir/docker-compose.yml" \
                || die "conteúdo inesperado em $dir/docker-compose.yml (ref '$REF' existe?)"
        else
            _log "    ${C_DIM}[dry-run] curl ${RAW_BASE}/${s}/docker-compose.yml${C_RESET}"
        fi
        ok "$s: compose em $dir"
    done

    if [[ "$VOLUMES_MODE" == "bind" ]]; then
        for s in "${SERVICES[@]}"; do
            dir="$(service_data_dir "$s")"
            run mkdir -p "$dir"
            # O driver local com o=bind NÃO cria o diretório: sem isto o mount falha.
            if [[ "$DRY_RUN" != "true" ]]; then
                cat > "$(service_dir "$s")/docker-compose.override.yml" <<EOF
# Gerado por infra-setup.sh — modo --volumes bind.
# Mantém o volume nomeado, mas com os dados neste diretório do host.
volumes:
  $(service_volume_key "$s"):
    driver: local
    driver_opts:
      type: none
      o: bind
      device: $dir
EOF
            fi
            ok "$s: dados em $dir (override gerado)"
        done
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        printf 'BDH_ROOT=%s\n' "$WORKDIR" > "$CONF_DIR/setup.conf"
    fi
}

write_env_files() {
    section "Credenciais e .env"
    local s dir env_file limit shm

    # Preserva senhas de uma instalação anterior (o volume já foi inicializado
    # com elas; trocar aqui não mudaria a senha do banco).
    local prev="$WORKDIR/secrets/credentials.env"
    if [[ -f "$prev" ]]; then
        # shellcheck disable=SC1090
        . "$prev"
        warn "credenciais existentes preservadas ($prev)"
    fi

    [[ -z "$POSTGRES_PASSWORD" ]] && POSTGRES_PASSWORD="$(gen_secret)"
    [[ -z "$DADOS_READ_PASSWORD" ]] && DADOS_READ_PASSWORD="$(gen_secret)"
    [[ -z "$REDIS_PASSWORD" ]] && REDIS_PASSWORD="$(gen_secret)"
    [[ -z "$MEILI_MASTER_KEY" ]] && MEILI_MASTER_KEY="$(gen_secret)"

    for s in "${SERVICES[@]}"; do
        dir="$(service_dir "$s")"
        env_file="$dir/.env"
        [[ "$DRY_RUN" == "true" ]] && { _log "    ${C_DIM}[dry-run] escreveria $env_file${C_RESET}"; continue; }

        case "$s" in
        postgres)
            read -r limit shm <<< "$(profile_resources "$PG_PROFILE")"
            {
                printf '# Gerado por infra-setup.sh (%s) — perfil %s\n' "$(date -Is)" "$PG_PROFILE"
                printf '# Referência dos parâmetros: postgres/docs/perfis.md\n\n'
                printf 'POSTGRES_DB=%s\n' "$POSTGRES_DB"
                printf 'POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
                printf 'DADOS_READ_PASSWORD=%s\n\n' "$DADOS_READ_PASSWORD"
                printf '# rede\nBIND_IP=%s\nPOSTGRES_PORT=%s\n\n' "$BIND_IP" "$POSTGRES_PORT"
                printf '# recursos do container (perfil %s)\n' "$PG_PROFILE"
                printf 'PG_MEMORY_LIMIT=%s\nPG_SHM_BYTES=%s\n\n' "$limit" "$shm"
                printf '# tuning do perfil\n'
                profile_env_block "$PG_PROFILE"
            } > "$env_file"
            ;;
        redis)
            {
                printf '# Gerado por infra-setup.sh (%s)\n' "$(date -Is)"
                printf '# Perfis de memória: redis/README.md\n\n'
                printf 'REDIS_PASSWORD=%s\n' "$REDIS_PASSWORD"
                printf 'REDIS_MAXMEMORY=%s\n' "512mb"
                printf 'REDIS_MEMORY_LIMIT=%s\n\n' "1G"
                printf '# rede\nBIND_IP=%s\nREDIS_PORT=%s\n' "$BIND_IP" "$REDIS_PORT"
            } > "$env_file"
            ;;
        meilisearch)
            {
                printf '# Gerado por infra-setup.sh (%s)\n' "$(date -Is)"
                printf '# Perfis de memória: meilisearch/README.md\n\n'
                printf 'MEILI_MASTER_KEY=%s\n' "$MEILI_MASTER_KEY"
                printf 'MEILI_MAX_INDEXING_MEMORY=%s\n' "1GiB"
                printf 'MEILI_MAX_INDEXING_THREADS=%s\n' "1"
                printf 'MEILI_MEMORY_LIMIT=%s\n\n' "1G"
                printf '# rede\nBIND_IP=%s\nMEILI_PORT=%s\n' "$BIND_IP" "$MEILI_PORT"
            } > "$env_file"
            ;;
        esac
        chmod 600 "$env_file"
        ok "$s: .env gerado"
    done

    if [[ "$DRY_RUN" != "true" ]]; then
        {
            printf '# Credenciais dos serviços de dados — BrasilDataHub\n'
            printf '# Gerado por infra-setup.sh em %s. NÃO versione este arquivo.\n\n' "$(date -Is)"
            if service_selected postgres; then
                printf 'POSTGRES_DB=%s\nPOSTGRES_USER=postgres\nPOSTGRES_PASSWORD=%s\nDADOS_READ_PASSWORD=%s\nPOSTGRES_PORT=%s\n\n' \
                    "$POSTGRES_DB" "$POSTGRES_PASSWORD" "$DADOS_READ_PASSWORD" "$POSTGRES_PORT"
            fi
            service_selected redis && printf 'REDIS_PASSWORD=%s\nREDIS_PORT=%s\n\n' "$REDIS_PASSWORD" "$REDIS_PORT"
            service_selected meilisearch && printf 'MEILI_MASTER_KEY=%s\nMEILI_PORT=%s\n' "$MEILI_MASTER_KEY" "$MEILI_PORT"
        } > "$WORKDIR/secrets/credentials.env"
        chmod 600 "$WORKDIR/secrets/credentials.env"
        ok "credenciais em $WORKDIR/secrets/credentials.env (chmod 600)"

        {
            printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
            printf 'REF=%s\n' "$REF"
            printf 'INSTALLED_AT=%s\n' "$(date -Is)"
            printf 'SERVICES=%s\n' "$(IFS=,; printf '%s' "${SERVICES[*]}")"
            printf 'VOLUMES_MODE=%s\n' "$VOLUMES_MODE"
            service_selected postgres && printf 'PG_PROFILE=%s\n' "$PG_PROFILE"
        } > "$WORKDIR/.setup-state"
    fi
}

start_services() {
    section "Subindo os serviços"
    local s dir compose_args
    for s in "${SERVICES[@]}"; do
        dir="$(service_dir "$s")"
        compose_args=(--project-directory "$dir" -f "$dir/docker-compose.yml")
        [[ -f "$dir/docker-compose.override.yml" ]] && compose_args+=(-f "$dir/docker-compose.override.yml")
        if [[ "$FORCE" == "true" ]]; then
            run docker compose -p "$s" "${compose_args[@]}" up -d --force-recreate
        else
            run docker compose -p "$s" "${compose_args[@]}" up -d
        fi
        ok "$s no ar"
    done

    [[ "$DRY_RUN" == "true" ]] && return 0

    info "aguardando healthchecks"
    local waited=0 pending
    while (( waited < 120 )); do
        pending=0
        for s in "${SERVICES[@]}"; do
            local health
            health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "$(docker ps -q --filter "label=org.brasildatahub.service=$s" | head -1)" 2>/dev/null || echo starting)"
            [[ "$health" == "healthy" || "$health" == "none" ]] || pending=$((pending + 1))
        done
        (( pending == 0 )) && break
        sleep 5; waited=$((waited + 5))
    done
    if (( pending == 0 )); then ok "todos os serviços saudáveis"; else warn "$pending serviço(s) ainda não saudáveis — veja 'bdh logs <serviço>'"; fi
    notify "progress" "serviços no ar"
}

configure_firewall() {
    section "Firewall"
    if [[ "$ENABLE_FIREWALL" != "true" ]]; then
        warn "ufw não configurado (--no-firewall)"
        return 0
    fi

    local ssh_port
    ssh_port="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
    ssh_port="${ssh_port:-22}"
    run ufw allow "${ssh_port}/tcp"          # SEMPRE antes do enable
    ok "SSH liberado (porta $ssh_port)"

    local s port cidr
    for s in "${SERVICES[@]}"; do
        port="$(service_port "$s")"
        if [[ -n "$ALLOW_FROM" ]]; then
            IFS=',' read -r -a cidrs <<< "$ALLOW_FROM"
            for cidr in "${cidrs[@]}"; do
                run ufw allow from "$cidr" to any port "$port" proto tcp
            done
            ok "$s: porta $port liberada para ${ALLOW_FROM}"
        else
            run ufw allow "${port}/tcp"
            warn "$s: porta $port aberta para QUALQUER origem"
        fi
    done

    run ufw --force enable
    ok "ufw ativo"
}

install_cli_and_motd() {
    section "Comando bdh e mensagem de login"
    if [[ "$DRY_RUN" == "true" ]]; then
        _log "    ${C_DIM}[dry-run] instalaria /usr/local/bin/bdh e o MOTD${C_RESET}"
        return 0
    fi

    cat > /usr/local/bin/bdh <<'BDH'
#!/usr/bin/env bash
# bdh — atalhos de operação dos serviços de dados da BrasilDataHub.
# Instalado por infra-setup.sh. Fonte da verdade dos caminhos: /etc/brasildatahub/setup.conf
set -euo pipefail

if [[ -z "${BDH_ROOT:-}" ]]; then
    BDH_ROOT="/opt/brasildatahub"
    [[ -f /etc/brasildatahub/setup.conf ]] && . /etc/brasildatahub/setup.conf
fi
LABEL="org.brasildatahub.service"

usage() {
    cat <<'USAGE'
bdh — serviços de dados da BrasilDataHub

  bdh status [--brief]     estado, portas e volumes
  bdh logs <serviço> [-f]  logs do serviço
  bdh up|down|restart <serviço>
  bdh verify [serviço]     verificação pós-deploy (/dev/shm, memória, conf)
  bdh creds [--show]       caminho (ou conteúdo) das credenciais
  bdh path <serviço>       diretório do serviço

Serviços: postgres, redis, meilisearch
USAGE
}

svc_dir() { printf '%s/services/%s' "$BDH_ROOT" "$1"; }

compose() {
    local svc="$1"; shift
    local dir; dir="$(svc_dir "$svc")"
    [[ -d "$dir" ]] || { echo "serviço '$svc' não provisionado em $dir" >&2; exit 1; }
    local args=(--project-directory "$dir" -f "$dir/docker-compose.yml")
    [[ -f "$dir/docker-compose.override.yml" ]] && args+=(-f "$dir/docker-compose.override.yml")
    docker compose -p "$svc" "${args[@]}" "$@"
}

cmd_status() {
    local brief="${1:-}"
    local rows
    rows="$(timeout 3 docker ps --filter "label=$LABEL" \
        --format '{{.Label "org.brasildatahub.service"}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true)"
    if [[ -z "$rows" ]]; then
        echo "nenhum serviço em execução (ou Docker indisponível)"
        return 0
    fi
    if [[ "$brief" == "--brief" ]]; then
        printf '%s\n' "$rows" | while IFS=$'\t' read -r svc state _ ports; do
            printf '  %-12s %-8s %s\n' "$svc" "$state" "${ports%%,*}"
        done
        return 0
    fi
    # Cabeçalho sem acentos de propósito: `column` escapa bytes não-ASCII quando
    # o locale não é UTF-8 (caso comum em sessões não interativas e no MOTD).
    # Sem column instalado, as colunas saem separadas por tab.
    { printf 'NOME\tESTADO\tSTATUS\tPORTAS\n'; printf '%s\n' "$rows"; } \
        | { column -t -s "$(printf '\t')" 2>/dev/null || cat; }
    echo
    echo "Diretórios:"
    local d
    for d in "$BDH_ROOT"/services/*/; do
        [[ -d "$d" ]] && printf '  %-12s %s\n' "$(basename "$d")" "$d"
    done
    echo
    echo "Volumes:"
    timeout 3 docker volume ls --filter name=bdh_ --format '  {{.Name}}' 2>/dev/null || true
}

cmd_verify() {
    local svc="${1:-postgres}" cid
    cid="$(docker ps -q --filter "label=$LABEL=$svc" | head -1)"
    [[ -n "$cid" ]] || { echo "$svc não está em execução" >&2; exit 1; }
    echo "== limite de memória (0 = sem limite)"
    docker inspect "$cid" --format 'Memory={{.HostConfig.Memory}}'
    echo "== volumes"
    docker inspect "$cid" --format '{{range .Mounts}}{{.Type}} {{.Name}} {{.Source}} -> {{.Destination}}{{println}}{{end}}'
    if [[ "$svc" == "postgres" ]]; then
        echo "== /dev/shm (64M indica perfil aplicado pela metade)"
        docker exec "$cid" df -h /dev/shm | tail -1
        echo "== shm-guard"
        docker logs "$cid" 2>&1 | grep shm-guard | tail -2 || echo "(sem linhas do shm-guard)"
        echo "== entradas inválidas no postgresql.conf (deve vir vazio)"
        local db; db="$(grep -h '^POSTGRES_DB=' "$(svc_dir postgres)/.env" | cut -d= -f2-)"
        docker exec "$cid" psql -U postgres -d "${db:-postgres}" -c \
            "SELECT sourceline, name, error FROM pg_file_settings WHERE NOT applied OR error IS NOT NULL;"
    fi
}

case "${1:-status}" in
    status) shift || true; cmd_status "${1:-}" ;;
    logs) svc="${2:?serviço}"; shift 2; compose "$svc" logs "$@" ;;
    up) compose "${2:?serviço}" up -d ;;
    down) compose "${2:?serviço}" down ;;      # sem -v: nunca apaga volume
    restart) compose "${2:?serviço}" restart ;;
    verify) cmd_verify "${2:-postgres}" ;;
    creds)
        if [[ "${2:-}" == "--show" ]]; then cat "$BDH_ROOT/secrets/credentials.env"
        else echo "$BDH_ROOT/secrets/credentials.env  (use 'bdh creds --show' para exibir)"; fi ;;
    path) svc_dir "${2:?serviço}"; echo ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
esac
BDH
    chmod 755 /usr/local/bin/bdh
    ok "/usr/local/bin/bdh instalado"

    [[ "$INSTALL_MOTD" != "true" ]] && { warn "mensagem de login não instalada (--no-motd)"; return 0; }

    # As variáveis abaixo devem ser resolvidas no login, não agora — daí as
    # aspas simples envolvendo todo o corpo.
    # shellcheck disable=SC2016
    local motd_body='#!/usr/bin/env bash
# Mensagem de login — serviços de dados da BrasilDataHub (infra-setup.sh).
if [[ -z "${BDH_ROOT:-}" ]]; then
    BDH_ROOT="/opt/brasildatahub"
    [[ -f /etc/brasildatahub/setup.conf ]] && . /etc/brasildatahub/setup.conf
fi
printf "\n\033[1mBrasilDataHub — servidor de dados\033[0m\n"
printf "  configuração ... %s/services/<serviço>/\n" "$BDH_ROOT"
printf "  credenciais .... %s/secrets/credentials.env\n" "$BDH_ROOT"
printf "  comandos ....... bdh status | bdh logs <serviço> | bdh verify\n\n"
if command -v bdh >/dev/null 2>&1; then
    bdh status --brief 2>/dev/null || true
fi
printf "\n"'

    if [[ -d /etc/update-motd.d ]]; then
        printf '%s\n' "$motd_body" > /etc/update-motd.d/99-brasildatahub
        chmod 755 /etc/update-motd.d/99-brasildatahub
        ok "MOTD em /etc/update-motd.d/99-brasildatahub"
    else
        # Debian sem update-motd: shell de login cobre o caso.
        printf '%s\n' "$motd_body" > /etc/profile.d/brasildatahub.sh
        chmod 755 /etc/profile.d/brasildatahub.sh
        ok "mensagem de login em /etc/profile.d/brasildatahub.sh"
    fi
}

summary() {
    section "Resumo"
    local s port
    _log "    ${C_BOLD}serviços${C_RESET}"
    for s in "${SERVICES[@]}"; do
        port="$(service_port "$s")"
        info "  $s → ${BIND_IP}:${port}   ($(service_dir "$s"))"
    done
    _log ""
    _log "    ${C_BOLD}credenciais${C_RESET}"
    info "  $WORKDIR/secrets/credentials.env   (chmod 600 — 'bdh creds --show')"
    _log ""
    _log "    ${C_BOLD}operação${C_RESET}"
    info "  bdh status | bdh logs <serviço> | bdh verify [serviço]"
    if service_selected postgres; then
        _log ""
        info "  perfil do Postgres: $PG_PROFILE — revise em postgres/docs/perfis.md"
    fi
    if [[ -z "$ALLOW_FROM" && "$ENABLE_FIREWALL" == "true" ]]; then
        _log ""
        warn "as portas dos serviços estão abertas para QUALQUER origem."
        warn "para restringir depois: ufw delete allow <porta>/tcp && ufw allow from <CIDR> to any port <porta> proto tcp"
        warn "ou defina BIND_IP no .env do serviço e recrie o container."
    fi
    _log ""
    notify "completed" "provisionamento concluído (${SERVICES[*]})"
}

# =============================================================================
main() {
    _log ""
    _log "${C_BOLD}infra-setup.sh v${SCRIPT_VERSION}${C_RESET} — serviços de dados da BrasilDataHub"
    validate_and_prompt
    preflight
    setup_system
    install_docker
    configure_docker_data_root
    create_layout
    write_env_files
    start_services
    configure_firewall
    install_cli_and_motd
    summary
}

# BDH_SETUP_LIB_ONLY=1 carrega as funções sem provisionar nada — é como
# test/infra-setup.test.sh exercita a lógica de perfis e caminhos.
if [[ -z "${BDH_SETUP_LIB_ONLY:-}" ]]; then
    main
fi
