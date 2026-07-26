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
# Alvos:
#   - Ubuntu/Debian com systemd (servidor): instala Docker, ajusta timezone e
#     firewall, instala mensagem de login. Requer root.
#   - macOS (estação de trabalho ou Mac mini como servidor): usa o Docker já
#     instalado (Docker Desktop, OrbStack ou Colima), não mexe em firewall nem
#     em arquivos de login. Funciona com ou sem sudo.
# =============================================================================
set -euo pipefail

case "$(uname -s)" in
    Linux)  OS_FAMILY="linux" ;;
    Darwin) OS_FAMILY="macos" ;;
    *)      printf 'Sistema não suportado: %s (use Linux Debian/Ubuntu ou macOS)\n' "$(uname -s)" >&2; exit 1 ;;
esac

SCRIPT_VERSION="1.0.0"

# --- defaults ----------------------------------------------------------------
REPO_SLUG="BrasilDataHub/infra"
REF="main"
WORKDIR="/opt/brasildatahub"
TIMEZONE="America/Sao_Paulo"
SERVICES_INPUT="postgres,redis,meilisearch"
POSTGRES_DB="dados"
PG_PROFILE="auto"
REDIS_PROFILE="cache-512mb"
MEILI_PROFILE="busca-1gb"
PROFILES_DIR=""
ALLOW_OVERSIZED="false"
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

# Destinos que variam com a plataforma e com haver ou não privilégio de root.
# Definidos em preflight().
CONF_DIR=""
BIN_DIR=""

# `date -Is` é GNU; o BSD date do macOS não aceita.
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

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
    [[ -n "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]] && printf '%s %s\n' "$(now_iso)" "$line" >> "$LOG_FILE"
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
        "$(hostname)" "$SCRIPT_VERSION" "$status" "${message//\"/\\\"}" "$(now_iso)")
    # Webhook nunca derruba o provisionamento.
    curl -fsS -m 5 -X POST -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

trap 'notify "failed" "abortado na linha $LINENO"' ERR

# --- ajuda -------------------------------------------------------------------
usage() {
    cat <<'HELP'
infra-setup.sh — provisiona uma máquina para os serviços de dados da BrasilDataHub.

USAGE:
    curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/infra/main/infra-setup.sh \
      | sudo bash -s -- [OPTIONS]

    # ou, para revisar antes de executar (recomendado):
    curl -fsSL .../infra-setup.sh -o infra-setup.sh && less infra-setup.sh
    sudo bash infra-setup.sh [OPTIONS]

PLATAFORMAS:
    Ubuntu/Debian  instala Docker, ajusta timezone, configura ufw e a mensagem
                   de login. Requer root.
    macOS          usa o Docker já instalado (Docker Desktop/OrbStack/Colima);
                   não mexe em firewall nem em arquivos de login, e roda sem
                   sudo (configuração em ~/.config, bdh em ~/.local/bin).
                   Ignorados no macOS: --docker-version, --docker-data-root,
                   --skip-system-update, --allow-from.

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
      --redis-profile PERFIL cache-256mb | cache-512mb | cache-1gb | cache-2gb
                             (default: cache-512mb)
      --meili-profile PERFIL busca-512mb | busca-1gb | busca-4gb | busca-16gb
                             (default: busca-1gb)
      --profiles-dir PATH    Lê os perfis de uma cópia local do repositório em
                             vez de baixá-los (ex.: um clone ou fork)
      --allow-oversized-profile
                             Aceita um perfil de Postgres maior que a memória
                             disponível (por default isso é recusado, porque o
                             banco não subiria)

    Cada perfil é um arquivo .env versionado no repositório
    (postgres/profiles/, redis/profiles/, meilisearch/profiles/). O script baixa
    o arquivo e acrescenta senhas e rede — nenhum valor de tuning vive aqui.

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
        --redis-profile) REDIS_PROFILE="$2"; shift 2 ;;
        --meili-profile|--meilisearch-profile) MEILI_PROFILE="$2"; shift 2 ;;
        --profiles-dir) PROFILES_DIR="$2"; shift 2 ;;
        --allow-oversized-profile) ALLOW_OVERSIZED="true"; shift ;;
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

# Nome REAL do volume no Docker (o que aparece em `docker volume ls`).
service_volume_name() {
    case "$1" in
        postgres) printf '%s' "${PG_VOLUME:-bdh_pg_data}" ;;
        redis) printf '%s' "${REDIS_VOLUME:-bdh_redis_data}" ;;
        meilisearch) printf '%s' "${MEILI_VOLUME:-bdh_meili_data}" ;;
    esac
}

# Chave do volume dentro do compose — é o que o override do modo bind ajusta.
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

# Porta DENTRO do container. É ela que as regras da chain DOCKER-USER veem: o
# DNAT da porta publicada acontece antes do filtro (ver configure_firewall).
service_internal_port() {
    case "$1" in
        postgres) printf '5432' ;;
        redis) printf '6379' ;;
        meilisearch) printf '7700' ;;
    esac
}

# Perfil do Postgres a partir da RAM total (ou do valor em GiB passado como
# argumento, usado pelos testes). Margem generosa porque a RAM reportada é
# sempre menor que a nominal do plano.
# shellcheck disable=SC2120  # o argumento é opcional: em produção lê /proc/meminfo
# Memória disponível ao Docker, em GiB. Em Linux nativo é a RAM do host; no
# macOS o daemon roda numa VM que costuma receber metade dela — dimensionar pelo
# host geraria limites maiores do que a VM tem.
available_mem_gb() {
    local bytes
    bytes="$(docker info -f '{{.MemTotal}}' 2>/dev/null || true)"
    case "$bytes" in ''|*[!0-9]*) bytes="" ;; esac
    if [[ -z "$bytes" ]]; then
        if [[ -r /proc/meminfo ]]; then
            bytes=$(awk '/MemTotal/ {printf "%d", $2 * 1024}' /proc/meminfo)
        else
            bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        fi
    fi
    printf '%d' $(( bytes / 1024 / 1024 / 1024 ))
}

# 'dedicada-16gb' -> 16. É o orçamento de RAM que o perfil pressupõe.
profile_budget_gb() {
    local n="${1#dedicada-}"
    printf '%s' "${n%gb}"
}

detect_pg_profile() {
    local ram_gb="${1:-}"
    [[ -z "$ram_gb" ]] && ram_gb="$(available_mem_gb)"
    if   (( ram_gb >= 120 )); then printf 'dedicada-128gb'
    elif (( ram_gb >= 56 ));  then printf 'dedicada-64gb'
    elif (( ram_gb >= 28 ));  then printf 'dedicada-32gb'
    elif (( ram_gb >= 14 ));  then printf 'dedicada-16gb'
    else                            printf 'dedicada-8gb'
    fi
}

# Perfis válidos por serviço. Os VALORES não vivem aqui: cada perfil é um
# arquivo .env no repositório (postgres/profiles/, redis/profiles/,
# meilisearch/profiles/), baixado no momento do provisionamento. É o mesmo
# arquivo que a documentação manda copiar num deploy manual.
PG_PROFILES="dedicada-8gb dedicada-16gb dedicada-32gb dedicada-64gb dedicada-128gb"
REDIS_PROFILES="cache-256mb cache-512mb cache-1gb cache-2gb"
MEILI_PROFILES="busca-512mb busca-1gb busca-4gb busca-16gb"

profile_valid() {
    local wanted="$1" list="$2" p
    for p in $list; do [[ "$p" == "$wanted" ]] && return 0; done
    return 1
}

# Perfil escolhido para cada serviço (usado ao montar o .env).
service_profile() {
    case "$1" in
        postgres) printf '%s' "$PG_PROFILE" ;;
        redis) printf '%s' "$REDIS_PROFILE" ;;
        meilisearch) printf '%s' "$MEILI_PROFILE" ;;
    esac
}

# Baixa o .env do perfil do repositório (ou copia de --profiles-dir, útil para
# fork/teste sem rede).
fetch_profile() {
    local svc="$1" prof; prof="$(service_profile "$svc")"
    if [[ -n "$PROFILES_DIR" ]]; then
        local src="$PROFILES_DIR/$svc/profiles/$prof.env"
        [[ -f "$src" ]] || die "perfil não encontrado: $src"
        cat "$src"
        return 0
    fi
    curl -fsSL "${RAW_BASE}/${svc}/profiles/${prof}.env" \
        || die "falha ao baixar ${RAW_BASE}/${svc}/profiles/${prof}.env"
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
        profile_valid "$PG_PROFILE" "$PG_PROFILES" \
            || die "perfil inválido: $PG_PROFILE (use: auto $PG_PROFILES)"

        # Um perfil maior do que a memória disponível não sobe: o Postgres falha
        # com "could not map anonymous shared memory" e fica em restart loop.
        # Melhor falhar aqui, com a razão explícita.
        local mem_gb budget
        mem_gb="$(available_mem_gb)"
        budget="$(profile_budget_gb "$PG_PROFILE")"
        if (( budget > mem_gb + 1 )) && [[ "$ALLOW_OVERSIZED" != "true" ]]; then
            die "perfil $PG_PROFILE pressupõe ${budget} GB, mas o Docker tem ${mem_gb} GB.
       O Postgres não subiria (shared_buffers maior que a memória disponível).
       Use --pg-profile $(detect_pg_profile "$mem_gb"), aumente a máquina (ou a
       memória da VM do Docker, no macOS), ou passe --allow-oversized-profile
       se souber que a memória vai crescer antes do primeiro uso."
        fi
        if (( budget > mem_gb + 1 )); then
            warn "perfil $PG_PROFILE acima da memória disponível (${mem_gb} GB) — seguindo por --allow-oversized-profile"
        fi
    fi
    if service_selected redis; then
        profile_valid "$REDIS_PROFILE" "$REDIS_PROFILES" \
            || die "perfil de Redis inválido: $REDIS_PROFILE (use: $REDIS_PROFILES)"
    fi
    if service_selected meilisearch; then
        profile_valid "$MEILI_PROFILE" "$MEILI_PROFILES" \
            || die "perfil de Meilisearch inválido: $MEILI_PROFILE (use: $MEILI_PROFILES)"
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
    if service_selected postgres; then info "perfil PG ...... $PG_PROFILE"; fi
    if service_selected redis; then info "perfil Redis ... $REDIS_PROFILE"; fi
    if service_selected meilisearch; then info "perfil Meili ... $MEILI_PROFILE"; fi
    info "volumes ........ $VOLUMES_MODE"
    info "publicação ..... ${BIND_IP} (firewall: ${ALLOW_FROM:-qualquer origem})"
    info "workdir ........ $WORKDIR"
}

preflight() {
    section "Pré-checagens"

    if [[ "$OS_FAMILY" == "linux" ]]; then
        [[ $EUID -eq 0 ]] || die "execute como root (sudo)"
        [[ -f /etc/os-release ]] || die "não foi possível identificar a distribuição"
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}${ID_LIKE:-}" in
            *debian*|*ubuntu*) ok "distribuição suportada: ${PRETTY_NAME:-$ID}" ;;
            *) die "no Linux, só Ubuntu/Debian são suportados (encontrado: ${PRETTY_NAME:-$ID})" ;;
        esac
        command -v systemctl >/dev/null || die "systemd é necessário"
        CONF_DIR="/etc/brasildatahub"
        BIN_DIR="/usr/local/bin"
    else
        ok "macOS $(sw_vers -productVersion 2>/dev/null || true)"
        # Sem root: mantém tudo em caminhos do usuário em vez de falhar.
        if [[ $EUID -eq 0 ]]; then
            CONF_DIR="/etc/brasildatahub"
            BIN_DIR="/usr/local/bin"
        else
            CONF_DIR="$HOME/.config/brasildatahub"
            BIN_DIR="$HOME/.local/bin"
            info "sem sudo: configuração em $CONF_DIR e comando bdh em $BIN_DIR"
        fi
        [[ -n "$DOCKER_DATA_ROOT" ]] && die "--docker-data-root não se aplica ao macOS (o Docker roda numa VM)"
        [[ "$ENABLE_FIREWALL" == "true" ]] && info "firewall não é configurado no macOS (ver aviso no fim)"
    fi

    # Se o workdir não existe, o diretório-pai precisa ser gravável.
    local parent; parent="$(dirname "$WORKDIR")"
    if [[ ! -d "$WORKDIR" && ! -w "$parent" ]]; then
        die "sem permissão para criar $WORKDIR — rode com sudo ou escolha outro --workdir"
    fi

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

    if [[ "$OS_FAMILY" == "macos" ]]; then
        # No macOS o script não atualiza o sistema nem instala pacotes: quem
        # cuida disso é o próprio usuário (App Store/brew). Só confere as
        # ferramentas que ele usa.
        local missing=""
        local tool
        for tool in curl openssl; do
            command -v "$tool" >/dev/null || missing+="$tool "
        done
        [[ -n "$missing" ]] && die "faltam ferramentas básicas: ${missing% } (instale com brew)"
        if [[ $EUID -eq 0 ]]; then
            if run systemsetup -settimezone "$TIMEZONE" >/dev/null 2>&1; then
                ok "timezone: $TIMEZONE"
            else
                warn "não foi possível ajustar o timezone (ajuste em Configurações do Sistema)"
            fi
        else
            info "timezone não alterado (precisa de sudo)"
        fi
        ok "ferramentas básicas presentes"
        return 0
    fi

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
        [[ "$OS_FAMILY" == "linux" ]] && run systemctl enable --now docker
        if ! docker info >/dev/null 2>&1; then
            die "o Docker está instalado mas não responde — inicie-o e rode de novo"
        fi
        return 0
    fi

    if [[ "$OS_FAMILY" == "macos" ]]; then
        # Instalar Docker Desktop por script exigiria interação gráfica; melhor
        # falhar com instruções do que deixar meio instalado.
        die "Docker não encontrado. Instale um destes e rode de novo:
         brew install --cask docker      (Docker Desktop)
         brew install orbstack           (OrbStack)
         brew install colima docker docker-compose && colima start"
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

    if [[ "$OS_FAMILY" == "macos" ]]; then
        # Os volumes vivem no disco virtual da VM do Docker; não há data-root
        # para apontar para outro dispositivo.
        info "no macOS os volumes ficam no disco da VM do Docker — nada a ajustar"
        info "espaço da VM: $(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo '?')"
        return 0
    fi

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
    local s dir env_file

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
        [[ "$DRY_RUN" == "true" ]] && { _log "    ${C_DIM}[dry-run] escreveria $env_file a partir de $s/profiles/$(service_profile "$s").env${C_RESET}"; continue; }

        # O .env é o arquivo do perfil (baixado do repositório, íntegro) mais o
        # que só o deploy sabe: senhas e rede. Mesma origem que a documentação
        # manda copiar num deploy manual.
        {
            fetch_profile "$s"
            printf '\n# --- deploy (gerado por infra-setup.sh em %s) ---\n' "$(now_iso)"
            case "$s" in
            postgres)
                printf 'POSTGRES_DB=%s\n' "$POSTGRES_DB"
                printf 'POSTGRES_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
                printf 'DADOS_READ_PASSWORD=%s\n' "$DADOS_READ_PASSWORD"
                printf 'BIND_IP=%s\nPOSTGRES_PORT=%s\n' "$BIND_IP" "$POSTGRES_PORT"
                ;;
            redis)
                printf 'REDIS_PASSWORD=%s\n' "$REDIS_PASSWORD"
                printf 'BIND_IP=%s\nREDIS_PORT=%s\n' "$BIND_IP" "$REDIS_PORT"
                ;;
            meilisearch)
                printf 'MEILI_MASTER_KEY=%s\n' "$MEILI_MASTER_KEY"
                printf 'BIND_IP=%s\nMEILI_PORT=%s\n' "$BIND_IP" "$MEILI_PORT"
                ;;
            esac
        } > "$env_file"
        chmod 600 "$env_file"
        ok "$s: .env gerado do perfil $(service_profile "$s")"
    done

    if [[ "$DRY_RUN" != "true" ]]; then
        {
            printf '# Credenciais dos serviços de dados — BrasilDataHub\n'
            printf '# Gerado por infra-setup.sh em %s. NÃO versione este arquivo.\n\n' "$(now_iso)"
            if service_selected postgres; then
                printf 'POSTGRES_DB=%s\nPOSTGRES_USER=postgres\nPOSTGRES_PASSWORD=%s\nDADOS_READ_PASSWORD=%s\nPOSTGRES_PORT=%s\n\n' \
                    "$POSTGRES_DB" "$POSTGRES_PASSWORD" "$DADOS_READ_PASSWORD" "$POSTGRES_PORT"
            fi
            if service_selected redis; then
                printf 'REDIS_PASSWORD=%s\nREDIS_PORT=%s\n\n' "$REDIS_PASSWORD" "$REDIS_PORT"
            fi
            if service_selected meilisearch; then
                printf 'MEILI_MASTER_KEY=%s\nMEILI_PORT=%s\n' "$MEILI_MASTER_KEY" "$MEILI_PORT"
            fi
        } > "$WORKDIR/secrets/credentials.env"
        chmod 600 "$WORKDIR/secrets/credentials.env"
        ok "credenciais em $WORKDIR/secrets/credentials.env (chmod 600)"

        {
            printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
            printf 'REF=%s\n' "$REF"
            printf 'INSTALLED_AT=%s\n' "$(now_iso)"
            printf 'SERVICES=%s\n' "$(IFS=,; printf '%s' "${SERVICES[*]}")"
            printf 'VOLUMES_MODE=%s\n' "$VOLUMES_MODE"
            # Cada bloco num `if`: uma condição falsa como última expressão do
            # grupo faria o `set -e` abortar o script (era o caso quando o
            # Meilisearch não estava entre os serviços escolhidos).
            if service_selected postgres; then printf 'PG_PROFILE=%s\n' "$PG_PROFILE"; fi
            if service_selected redis; then printf 'REDIS_PROFILE=%s\n' "$REDIS_PROFILE"; fi
            if service_selected meilisearch; then printf 'MEILI_PROFILE=%s\n' "$MEILI_PROFILE"; fi
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

    # O initdb só roda na primeira subida em volume vazio. Se aquela subida
    # falhou no meio (perfil grande demais, por exemplo), o cluster existe mas o
    # database, as extensões e a role dados_read não — e nada mais vai criá-los.
    if service_selected postgres; then
        local cid
        cid="$(docker ps -q --filter "label=org.brasildatahub.service=postgres" | head -1)"
        if [[ -n "$cid" ]]; then
            if docker exec "$cid" psql -U postgres -tAc \
                 "SELECT 1 FROM pg_database WHERE datname = '$POSTGRES_DB'" 2>/dev/null | grep -q 1; then
                local exts
                exts="$(docker exec "$cid" psql -U postgres -d "$POSTGRES_DB" -tAc \
                    "SELECT count(*) FROM pg_extension" 2>/dev/null || echo 0)"
                ok "database '$POSTGRES_DB' pronto ($exts extensões)"
            else
                warn "o database '$POSTGRES_DB' NÃO existe no volume $(service_volume_name postgres)."
                warn "isso indica um initdb interrompido numa subida anterior: o cluster foi"
                warn "criado, mas database, extensões e role dados_read não. Como o entrypoint"
                warn "não repete o initdb num volume já inicializado, escolha um caminho:"
                warn "  a) descartar os dados e refazer: docker compose down && docker volume rm $(service_volume_name postgres)"
                warn "  b) criar à mão o database, as extensões e a role (postgres/initdb/)"
            fi
        fi
    fi
    notify "progress" "serviços no ar"
}

configure_firewall() {
    section "Firewall"

    if [[ "$OS_FAMILY" == "macos" ]]; then
        warn "no macOS o script não configura firewall."
        if [[ -n "$ALLOW_FROM" ]]; then
            warn "--allow-from NÃO foi aplicado: use o firewall do macOS/roteador,"
            warn "ou publique numa interface específica com --bind-ip."
        fi
        info "as portas publicadas seguem as regras do firewall do sistema"
        return 0
    fi

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
    local -a cidrs=()
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

    # ------------------------------------------------------------------
    # As regras acima NÃO bastam para portas publicadas pelo Docker.
    # Pacote para container entra por FORWARD -> DOCKER-USER -> DOCKER, e o ufw
    # filtra apenas INPUT: `ufw allow from <CIDR> to any port 5432` não impede
    # ninguém de conectar. Verificado em Debian 12 + Docker 29.
    # A restrição real vive na chain DOCKER-USER, persistida em
    # /etc/ufw/after.rules (que o ufw reaplica no reload e no boot).
    # ------------------------------------------------------------------
    local rules_file=/etc/ufw/after.rules
    local begin='# BEGIN BrasilDataHub (infra-setup.sh) — restrição das portas publicadas pelo Docker'
    local end='# END BrasilDataHub'

    if [[ "$DRY_RUN" == "true" ]]; then
        _log "    ${C_DIM}[dry-run] ajustaria a chain DOCKER-USER em $rules_file${C_RESET}"
        return 0
    fi

    # Remove o bloco de uma execução anterior (idempotência).
    if grep -qF "$begin" "$rules_file" 2>/dev/null; then
        sed -i "/$(printf '%s' "$begin" | sed 's/[][\.*^$/]/\\&/g')/,/$(printf '%s' "$end" | sed 's/[][\.*^$/]/\\&/g')/d" "$rules_file"
    fi

    # Tirar o bloco do arquivo não basta: `ufw reload` apenas reaplica o que
    # está nele, e as regras já inseridas continuam na chain. O script gerencia
    # a DOCKER-USER integralmente, então limpa antes de reaplicar.
    iptables -F DOCKER-USER 2>/dev/null || true

    if [[ -z "$ALLOW_FROM" ]]; then
        run ufw reload
        warn "portas publicadas acessíveis de qualquer origem (sem --allow-from)"
        return 0
    fi

    IFS=',' read -r -a cidrs <<< "$ALLOW_FROM"
    {
        printf '%s\n' "$begin"
        printf '*filter\n:DOCKER-USER - [0:0]\n'
        printf -- '-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN\n'
        printf -- '-A DOCKER-USER -s 172.16.0.0/12 -j RETURN\n'   # entre containers
        printf -- '-A DOCKER-USER -s 127.0.0.0/8 -j RETURN\n'     # do próprio host
        for s in "${SERVICES[@]}"; do
            port="$(service_internal_port "$s")"
            for cidr in "${cidrs[@]}"; do
                printf -- '-A DOCKER-USER -p tcp --dport %s -s %s -j RETURN\n' "$port" "$cidr"
            done
            printf -- '-A DOCKER-USER -p tcp --dport %s -j DROP\n' "$port"
        done
        printf -- '-A DOCKER-USER -j RETURN\nCOMMIT\n'
        printf '%s\n' "$end"
    } >> "$rules_file"

    run ufw reload
    ok "chain DOCKER-USER restringe as portas dos containers a ${ALLOW_FROM}"
}

install_cli_and_motd() {
    section "Comando bdh e mensagem de login"
    if [[ "$DRY_RUN" == "true" ]]; then
        _log "    ${C_DIM}[dry-run] instalaria ${BIN_DIR}/bdh e a mensagem de login${C_RESET}"
        return 0
    fi

    mkdir -p "$BIN_DIR"
    cat > "$BIN_DIR/bdh" <<'BDH'
#!/usr/bin/env bash
# bdh — atalhos de operação dos serviços de dados da BrasilDataHub.
# Instalado por infra-setup.sh. Os caminhos vêm de setup.conf (em /etc ou ~/.config).
set -euo pipefail

if [[ -z "${BDH_ROOT:-}" ]]; then
    BDH_ROOT="/opt/brasildatahub"
    for _conf in /etc/brasildatahub/setup.conf "$HOME/.config/brasildatahub/setup.conf"; do
        [[ -f "$_conf" ]] && . "$_conf" && break
    done
fi
LABEL="org.brasildatahub.service"

# macOS não tem `timeout`; sem ele, roda direto.
_t() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }

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
    rows="$(_t 3 docker ps --filter "label=$LABEL" \
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
    _t 3 docker volume ls --filter name=bdh_ --format '  {{.Name}}' 2>/dev/null || true
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
    chmod 755 "$BIN_DIR/bdh"
    ok "$BIN_DIR/bdh instalado"
    case ":$PATH:" in *":$BIN_DIR:"*) ;; *) warn "$BIN_DIR não está no PATH — adicione-o ao seu shell" ;; esac

    [[ "$INSTALL_MOTD" != "true" ]] && { warn "mensagem de login não instalada (--no-motd)"; return 0; }

    # As variáveis abaixo devem ser resolvidas no login, não agora — daí as
    # aspas simples envolvendo todo o corpo.
    # shellcheck disable=SC2016
    local motd_body='#!/usr/bin/env bash
# Mensagem de login — serviços de dados da BrasilDataHub (infra-setup.sh).
if [[ -z "${BDH_ROOT:-}" ]]; then
    BDH_ROOT="/opt/brasildatahub"
    for _conf in /etc/brasildatahub/setup.conf "$HOME/.config/brasildatahub/setup.conf"; do
        [[ -f "$_conf" ]] && . "$_conf" && break
    done
fi
printf "\n\033[1mBrasilDataHub — servidor de dados\033[0m\n"
printf "  configuração ... %s/services/<serviço>/\n" "$BDH_ROOT"
printf "  credenciais .... %s/secrets/credentials.env\n" "$BDH_ROOT"
printf "  comandos ....... bdh status | bdh logs <serviço> | bdh verify\n\n"
if command -v bdh >/dev/null 2>&1; then
    bdh status --brief 2>/dev/null || true
fi
printf "\n"'

    if [[ "$OS_FAMILY" == "macos" ]]; then
        # macOS não tem update-motd.d, e editar o dotfile do usuário sem pedir
        # seria invasivo: instala o script e mostra a linha a adicionar.
        printf '%s\n' "$motd_body" > "$WORKDIR/login-message.sh"
        chmod 755 "$WORKDIR/login-message.sh"
        ok "mensagem de login em $WORKDIR/login-message.sh"
        info "para exibi-la a cada shell, acrescente ao ~/.zprofile:"
        info "  [ -x $WORKDIR/login-message.sh ] && $WORKDIR/login-message.sh"
        return 0
    fi

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
    if [[ "$OS_FAMILY" == "macos" ]]; then
        _log ""
        warn "firewall não configurado (macOS): as portas seguem as regras do sistema."
        warn "para restringir, publique numa interface com BIND_IP no .env, ou use"
        warn "o firewall do roteador/rede."
    elif [[ -z "$ALLOW_FROM" && "$ENABLE_FIREWALL" == "true" ]]; then
        _log ""
        warn "as portas dos serviços estão abertas para QUALQUER origem."
        warn "para restringir depois, rode de novo com --allow-from <CIDR> (o script"
        warn "ajusta ufw E a chain DOCKER-USER, que é a que vale para containers),"
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
