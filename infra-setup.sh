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

# --- flags explicitamente informadas -----------------------------------------
# A LACUNA RAIZ que este bloco fecha: o script GRAVA o .setup-state e não o
# RELÊ — só relia VOLUMES_MODE. A consequência é que uma segunda execução (por
# exemplo `--metrics-only`, que o README indica para ligar observabilidade)
# roda o main() inteiro com os DEFAULTS DE FÁBRICA: POSTGRES_DB volta para
# "dados", BIND_IP para 0.0.0.0, ALLOW_FROM para vazio. O .env muda, o Postgres
# é RECRIADO, a DSN do exporter aponta para um database que não existe e o
# firewall é esvaziado.
#
# A correção precisa distinguir "o usuário pediu" de "é o default", e não há
# como fazer isso olhando só o valor: `--bind-ip 0.0.0.0` e a ausência da flag
# produzem a mesma string. Daí este registro, alimentado pelo parser.
#
# Lista separada por espaço, e não array associativo: `declare -A` é bash 4+, e
# o bash de fábrica do macOS é 3.2 — onde os testes deste repositório rodam.
FLAGS_EXPLICITAS=""
_explicita()    { FLAGS_EXPLICITAS="${FLAGS_EXPLICITAS} $1"; }
foi_explicita() { case " $FLAGS_EXPLICITAS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- defaults ----------------------------------------------------------------
REPO_SLUG="BrasilDataHub/infra"
REF="main"
WORKDIR="/opt/brasildatahub"
TIMEZONE="America/Sao_Paulo"
SERVICES_INPUT="postgres,redis,meilisearch"
POSTGRES_DB="dados"
# Todos em 'auto': o dimensionamento é coordenado em validate_and_prompt() —
# vizinhos primeiro, Postgres com a memória que sobra.
PG_PROFILE="auto"
REDIS_PROFILE="auto"
MEILI_PROFILE="auto"
# Um perfil só, e não `auto`: o dimensionamento do OpenSearch não é uma função
# da RAM do host — é a conta de 03 §3.1, que reserva 7,5 GiB de page cache para
# o mmap do Lucene. Detectar por RAM produziria um heap grande e page cache
# insuficiente, que é o pior dos dois mundos.
OPENSEARCH_PROFILE="compartilhada-8gb"
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
# O OpenSearch entra no catálogo com porta própria. Ele NÃO tem autenticação
# (o plugin de segurança está desligado — ver infra/opensearch/README.md), então
# a barreira é inteiramente o firewall: publicar esta porta sem --allow-from
# entrega o índice inteiro.
OPENSEARCH_PORT="9200"
# O PgBouncer roda no host da APLICAÇÃO e por default em loopback: ele fica no
# mesmo host de quem o consome, e publicá-lo fora daria um caminho até o banco
# com a autenticação do pooler no meio.
PGBOUNCER_PORT="6432"
ALLOW_FROM=""
ENABLE_FIREWALL="true"
# 262144 é o mínimo que o bootstrap check do OpenSearch exige.
VM_MAX_MAP_COUNT="262144"

# --- observabilidade (opt-in por --metrics) ----------------------------------
# Fora do default de propósito: incluir monitoração no --auto mudaria o
# comportamento de todo provisionamento existente e somaria ~1,5 GB de RAM ao
# orçamento que detect_pg_profile() não sabe descontar.
METRICS_ENABLED="false"
METRICS_ONLY="false"             # --metrics-only: acrescenta métricas SEM recriar os serviços
UPDATE_MODE="false"              # --update / --add-service: herda o estado e reaplica
SOMENTE_MONITORING="false"       # --services monitoring: host só de observabilidade
ADD_SERVICE=""                   # serviço a acrescentar sem tocar nos demais
MONITORING_ENABLED="true"        # --no-monitoring: só exporters, Prometheus alhures
METRICS_PROFILE="auto"
METRICS_CONTAINERS="false"       # --metrics-containers liga o cAdvisor
METRICS_NETWORK="bdh_metrics"
MONITORING_BIND_IP="127.0.0.1"   # NUNCA reusar BIND_IP: o default dele é 0.0.0.0
PROMETHEUS_PORT="9090"
GRAFANA_PORT="3000"
GRAFANA_ADMIN_PASSWORD=""
PG_METRICS_PASSWORD=""
MEILI_METRICS_KEY=""
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
                             | dedicada-64gb | dedicada-128gb   (default: auto)
      --redis-profile PERFIL auto | cache-256mb | cache-512mb | cache-1gb
                             | cache-2gb                        (default: auto)
      --meili-profile PERFIL auto | busca-512mb | busca-1gb | busca-4gb
                             | busca-16gb                       (default: auto)
      --profiles-dir PATH    Lê os perfis de uma cópia local do repositório em
                             vez de baixá-los (ex.: um clone ou fork)
      --allow-oversized-profile
                             Aceita um perfil de Postgres maior que a memória
                             disponível (por default isso é recusado, porque o
                             banco não subiria)

    Cada perfil é um arquivo .env versionado no repositório
    (postgres/profiles/, redis/profiles/, meilisearch/profiles/). O script baixa
    o arquivo e acrescenta senhas e rede — nenhum valor de tuning vive aqui.

    Com 'auto' (o default de todos), o dimensionamento é COORDENADO: Redis,
    Meilisearch e métricas são escolhidos pela RAM da máquina, e o Postgres fica
    com o que sobra — a fórmula de reserva de postgres/docs/perfis.md. Com
    --services postgres, ele recebe a máquina inteira.

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

OPTIONS (observabilidade — desligada por default):
      --metrics              Sobe a stack de métricas: exporters junto de cada
                             serviço + Prometheus, Grafana e node exporter
      --metrics-only         Acrescenta observabilidade a uma instalação que já
                             existe SEM recriar os containers de dados (implica
                             --force, mas não --force-recreate). É este o modo
                             para ligar métricas num banco em produção.
      --no-monitoring        Só os exporters (Prometheus vive em outra máquina)
      --metrics-profile PERFIL
                             auto | metricas-512mb | metricas-2gb | metricas-8gb
                             (default: auto). 'auto' NÃO escala com a RAM: a
                             cardinalidade segue o número de alvos, não o
                             tamanho do host. Dá metricas-512mb, ou metricas-2gb
                             com --metrics-containers.
      --metrics-containers   Inclui o cAdvisor (memória usada vs limite por
                             container; custa 200-400 MB de RAM)
      --metrics-bind-ip IP   Interface do Grafana e do Prometheus
                             (default: 127.0.0.1 — use um túnel SSH)
      --prometheus-port N    (default: 9090)
      --grafana-port N       (default: 3000)
      --grafana-password SENHA  (se omitida, é gerada)

    Grafana e Prometheus ficam em 127.0.0.1 de propósito, ao contrário dos
    serviços de dados: o Prometheus não tem autenticação nenhuma. Acesse com
    ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 usuario@host

OPTIONS (rede e firewall):
      --bind-ip IP           Interface de publicação (default: 0.0.0.0 — todas)
      --postgres-port N      (default: 5432)
      --redis-port N         (default: 6379)
      --meilisearch-port N   (default: 7700)
      --allow-from CIDR[,CIDR]  Restringe o firewall a estas origens
                             (default: sem restrição — qualquer origem)
      --no-firewall          Não configura o ufw

OPTIONS (atualização de uma instalação existente — herda o .setup-state):
      --update               Reaplica a configuração sem repetir as flags da
                             instalação original. Flag explícita sobrescreve;
                             ausência HERDA. É o que substitui o contorno de
                             "repetir --postgres-db, --bind-ip e --allow-from de
                             cor" — cujo esquecimento recriava o banco, reexpunha
                             as portas e esvaziava o firewall.
      --add-service NOME     Acrescenta um serviço (opensearch, pgbouncer, ...)
                             sem tocar nos que já existem. Implica --update.

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
        --services) SERVICES_INPUT="$2"; _explicita SERVICES_INPUT; shift 2 ;;
        --postgres-db) POSTGRES_DB="$2"; _explicita POSTGRES_DB; shift 2 ;;
        --pg-profile) PG_PROFILE="$2"; _explicita PG_PROFILE; shift 2 ;;
        --redis-profile) REDIS_PROFILE="$2"; _explicita REDIS_PROFILE; shift 2 ;;
        --meili-profile|--meilisearch-profile) MEILI_PROFILE="$2"; _explicita MEILI_PROFILE; shift 2 ;;
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
        --bind-ip) BIND_IP="$2"; _explicita BIND_IP; shift 2 ;;
        --postgres-port) POSTGRES_PORT="$2"; _explicita POSTGRES_PORT; shift 2 ;;
        --redis-port) REDIS_PORT="$2"; _explicita REDIS_PORT; shift 2 ;;
        --meilisearch-port) MEILI_PORT="$2"; _explicita MEILI_PORT; shift 2 ;;
        --allow-from) ALLOW_FROM="$2"; _explicita ALLOW_FROM; shift 2 ;;
        --enable-firewall) ENABLE_FIREWALL="true"
# 262144 é o mínimo que o bootstrap check do OpenSearch exige.
VM_MAX_MAP_COUNT="262144"; shift ;;
        --no-firewall) ENABLE_FIREWALL="false"; shift ;;
        # Reaplica a configuração de uma instalação existente, herdando tudo o
        # que não for passado explicitamente. É o modo que transforma
        # "reinstalar repetindo todas as flags de cor" em "atualizar".
        --update) UPDATE_MODE="true"; FORCE="true"; shift ;;
        # Acrescenta um serviço SEM tocar nos outros: os composes dos existentes
        # não são reescritos, e credentials.env recebe merge em vez de ser
        # truncado aos serviços desta execução.
        --add-service) ADD_SERVICE="$2"; UPDATE_MODE="true"; FORCE="true"; shift 2 ;;
        --metrics) METRICS_ENABLED="true"; shift ;;
        # Acrescenta observabilidade a uma instalação existente sem recriar os
        # containers de dados: implica --force (para reconfigurar) mas suprime o
        # --force-recreate, que num banco de centenas de GB significa downtime e
        # page cache frio só para ligar um gráfico.
        --metrics-only) METRICS_ENABLED="true"; METRICS_ONLY="true"; FORCE="true"; shift ;;
        --no-monitoring) MONITORING_ENABLED="false"; shift ;;
        --metrics-profile) METRICS_PROFILE="$2"; METRICS_ENABLED="true"; _explicita METRICS_PROFILE; shift 2 ;;
        --metrics-containers) METRICS_CONTAINERS="true"; METRICS_ENABLED="true"; shift ;;
        --metrics-bind-ip) MONITORING_BIND_IP="$2"; shift 2 ;;
        --prometheus-port) PROMETHEUS_PORT="$2"; shift 2 ;;
        --grafana-port) GRAFANA_PORT="$2"; shift 2 ;;
        --grafana-password) GRAFANA_ADMIN_PASSWORD="$2"; shift 2 ;;
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
        opensearch)  printf '%s' "${OPENSEARCH_DATA_DIR:-$DATA_DIR/opensearch}" ;;
    esac
}

# Nome REAL do volume no Docker (o que aparece em `docker volume ls`).
service_volume_name() {
    case "$1" in
        postgres) printf '%s' "${PG_VOLUME:-bdh_pg_data}" ;;
        redis) printf '%s' "${REDIS_VOLUME:-bdh_redis_data}" ;;
        meilisearch) printf '%s' "${MEILI_VOLUME:-bdh_meili_data}" ;;
        opensearch) printf '%s' "${OS_VOLUME:-bdh_os_data}" ;;
    esac
}

# Chave do volume dentro do compose — é o que o override do modo bind ajusta.
service_volume_key() {
    case "$1" in
        postgres) printf 'pg_data' ;;
        redis) printf 'redis_data' ;;
        meilisearch) printf 'meili_data' ;;
        opensearch) printf 'os_data' ;;
    esac
}

service_port() {
    case "$1" in
        postgres) printf '%s' "$POSTGRES_PORT" ;;
        redis) printf '%s' "$REDIS_PORT" ;;
        meilisearch) printf '%s' "$MEILI_PORT" ;;
        opensearch) printf '%s' "$OPENSEARCH_PORT" ;;
        pgbouncer) printf '%s' "$PGBOUNCER_PORT" ;;
    esac
}

# Porta DENTRO do container. É ela que as regras da chain DOCKER-USER veem: o
# DNAT da porta publicada acontece antes do filtro (ver configure_firewall).
service_internal_port() {
    case "$1" in
        postgres) printf '5432' ;;
        redis) printf '6379' ;;
        meilisearch) printf '7700' ;;
        opensearch) printf '9200' ;;
        pgbouncer) printf '6432' ;;
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

# O Postgres é detectado pela memória que SOBRA depois dos vizinhos, não pela RAM
# total — é a fórmula de retrofit de docs/perfis.md aplicada automaticamente.
# Quem passa o argumento é validate_and_prompt(); sem argumento, assume a máquina
# inteira (Postgres sozinho).
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

# Redis e Meilisearch escalam pela RAM TOTAL do host: o porte da máquina é o
# melhor indicador disponível do volume de cache/fila e do tamanho do índice.
# As faixas são as mesmas do Postgres para que os conjuntos resultantes batam
# com a tabela "Combinações prováveis" de docs/perfis.md.
# shellcheck disable=SC2120  # o argumento é opcional: em produção lê a RAM real
detect_redis_profile() {
    local ram_gb="${1:-}"
    [[ -z "$ram_gb" ]] && ram_gb="$(available_mem_gb)"
    if   (( ram_gb >= 56 )); then printf 'cache-2gb'
    elif (( ram_gb >= 28 )); then printf 'cache-1gb'
    elif (( ram_gb >= 14 )); then printf 'cache-512mb'
    else                          printf 'cache-256mb'
    fi
}

# shellcheck disable=SC2120  # idem
detect_meili_profile() {
    local ram_gb="${1:-}"
    [[ -z "$ram_gb" ]] && ram_gb="$(available_mem_gb)"
    if   (( ram_gb >= 56 )); then printf 'busca-16gb'
    elif (( ram_gb >= 28 )); then printf 'busca-4gb'
    elif (( ram_gb >= 14 )); then printf 'busca-1gb'
    else                          printf 'busca-512mb'
    fi
}

# Métricas NÃO escalam com a RAM, e isso é deliberado: a cardinalidade do
# Prometheus depende do NÚMERO DE ALVOS, não do tamanho do host. Um host com os
# três serviços gera ~3 mil séries tanto em 16 quanto em 128 GB (medido: 3.470).
# Escalar por RAM desperdiçaria memória que o Postgres usaria como page cache.
#
# metricas-8gb nunca é automático: é para 5–15 hosts, um cenário multi-host que
# este script não conhece.
detect_metrics_profile() {
    if [[ "$METRICS_CONTAINERS" == "true" ]]; then
        printf 'metricas-2gb'      # o cAdvisor sozinho dobra o volume de séries
    else
        printf 'metricas-512mb'
    fi
}

# Perfis válidos por serviço. Os VALORES não vivem aqui: cada perfil é um
# arquivo .env no repositório (postgres/profiles/, redis/profiles/,
# meilisearch/profiles/), baixado no momento do provisionamento. É o mesmo
# arquivo que a documentação manda copiar num deploy manual.
# `compartilhada-14gb` é o perfil do host que divide CPU e page cache com o
# motor de busca. O nome é parte da correção: o perfil em uso até 07/2026
# chamava-se `dedicada-16gb` num host que nunca foi dedicado, e é o nome
# errado que faz alguém somar os limites e concluir que cabe.
PG_PROFILES="dedicada-8gb dedicada-16gb dedicada-32gb dedicada-64gb dedicada-128gb compartilhada-14gb"
# cache-768mb e fila-256mb são o PAR do desenho de duas instâncias
# (redis/docker-compose.par.yml): separar cache de fila+sessões é o que
# permite `allkeys-lru` num lado sem arriscar despejar job no outro.
REDIS_PROFILES="cache-256mb cache-512mb cache-768mb cache-1gb cache-2gb fila-256mb"
MEILI_PROFILES="busca-512mb busca-1gb busca-4gb busca-16gb"
OPENSEARCH_PROFILES="compartilhada-8gb"
METRICS_PROFILES="metricas-512mb metricas-2gb metricas-8gb"

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
        # monitoring NÃO entra no array SERVICES (ver create_layout), mas usa o
        # mesmo fetch_profile para baixar monitoring/profiles/<perfil>.env.
        monitoring) printf '%s' "$METRICS_PROFILE" ;;
        opensearch) printf '%s' "$OPENSEARCH_PROFILE" ;;
        # O PgBouncer não tem perfil: ele é dimensionado por `default_pool_size`
        # e `max_client_conn`, que são decisão da APLICAÇÃO, não do host. Ver
        # pgbouncer/generate-config.sh.
    esac
}

# Orçamento de RAM de um perfil de VIZINHO, em GB — o que entra na fórmula de
# reserva de docs/perfis.md. São os limites de container dos arquivos .env
# arredondados PARA CIMA: melhor sobrar page cache para o Postgres do que
# descobrir o erro como OOM-kill.
#
# Fonte dos números: <serviço>/profiles/*.env (REDIS_MEMORY_LIMIT,
# MEILI_MEMORY_LIMIT, e a soma dos limites de monitoring/profiles/*.env).
neighbor_budget_gb() {
    case "$1" in
        # Redis — REDIS_MEMORY_LIMIT: 512M / 1G / 2G / 3G
        cache-256mb)    printf '1' ;;
        cache-512mb)    printf '1' ;;
        cache-1gb)      printf '2' ;;
        cache-2gb)      printf '3' ;;
        # Meilisearch — MEILI_MEMORY_LIMIT (valor de PICO de indexação)
        busca-512mb)    printf '1' ;;
        busca-1gb)      printf '1' ;;
        busca-4gb)      printf '4' ;;
        busca-16gb)     printf '16' ;;
        # OpenSearch — OS_MEMORY_LIMIT. SEM esta linha, o `auto` do Postgres não
        # desconta o heap da JVM do orçamento do host e SUPERDIMENSIONA o banco:
        # num host de 31 GiB, ele escolheria `dedicada-32gb` (shared_buffers de
        # 10 GiB) ignorando que 8 GiB já são do motor de busca. O erro aparece
        # como OOM-kill, semanas depois.
        compartilhada-8gb) printf '8' ;;
        # Observabilidade — Prometheus + Grafana + node exporter + exporters.
        # O cAdvisor entra à parte, em metrics_budget_gb().
        metricas-512mb) printf '2' ;;
        metricas-2gb)   printf '4' ;;
        metricas-8gb)   printf '10' ;;
        *)              printf '0' ;;
    esac
}

# Orçamento da stack de observabilidade. Delega a neighbor_budget_gb para não
# manter duas tabelas de números que precisariam ser atualizadas juntas.
metrics_budget_gb() {
    local base
    base="$(neighbor_budget_gb "$METRICS_PROFILE")"
    [[ "$base" == "0" ]] && base=2      # perfil desconhecido: assume o menor
    [[ "$METRICS_CONTAINERS" == "true" ]] && base=$((base + 1))
    printf '%d' "$base"
}

# A chave de métricas do Meilisearch é lida pelo PROCESSO do Prometheus, que na
# imagem oficial roda como `nobody` (65534) — não como root. Um `chmod 600` com
# dono root deixa o arquivo ilegível para ele, e o sintoma é silencioso: o
# container sobe saudável e só o job do Meilisearch fica `down` para sempre, com
# "permission denied" enterrado no /api/v1/targets.
#
# `chown` + `600` mantém o segredo fora do alcance dos outros usuários do host,
# que é o ponto do 600. No macOS não há uid 65534 e o script roda sem root: lá o
# bind mount não propaga dono, então o chown é dispensável.
PROMETHEUS_UID=65534
protect_metrics_key() {
    local f="$1"
    [[ -e "$f" ]] || return 0
    [[ "$OS_FAMILY" == "linux" ]] && chown "$PROMETHEUS_UID:$PROMETHEUS_UID" "$f"
    chmod 600 "$f"
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
            postgres|redis|meilisearch|opensearch|pgbouncer) ;;
            # `monitoring` em --services provisiona um host SÓ de
            # observabilidade — o desenho que este roadmap adota (Prometheus no
            # bdh-apps, dados no bdh-data). Ele não entra no array SERVICES
            # (ver logo abaixo): tem layout próprio, não tem volume de dados de
            # serviço e o gerador de override de bind assumiria um.
            monitoring)
                METRICS_ENABLED="true"
                MONITORING_ENABLED="true"
                SOMENTE_MONITORING="true"
                ;;
            *) die "serviço desconhecido: '$s' (use postgres, redis, meilisearch, opensearch, pgbouncer ou monitoring)" ;;
        esac
    done
    # `monitoring` sai do array: ele é provisionado por setup_metrics(), não
    # pelo laço de serviços de dados.
    if [[ "$SOMENTE_MONITORING" == "true" ]]; then
        local restantes=()
        for s in "${SERVICES[@]}"; do
            [[ "$s" == "monitoring" ]] || restantes+=("$s")
        done
        SERVICES=("${restantes[@]+"${restantes[@]}"}")
    fi

    # Um host só de observabilidade é legítimo e tem ZERO serviços de dados —
    # a checagem original o rejeitaria.
    if [[ ${#SERVICES[@]} -eq 0 && "$SOMENTE_MONITORING" != "true" ]]; then
        die "nenhum serviço selecionado"
    fi

    # --- dimensionamento coordenado ------------------------------------------
    # Os VIZINHOS são resolvidos primeiro e o Postgres fica com a memória que
    # sobra — a fórmula de reserva de postgres/docs/perfis.md aplicada
    # automaticamente. Antes o Postgres era dimensionado pela RAM total e
    # ignorava os vizinhos: numa VPS de 32 GB o --auto entregava dedicada-32gb
    # (limite 28G) + Redis 1G + Meili 1G, sem margem para o SO.
    local mem_gb neighbors_gb=0
    mem_gb="$(available_mem_gb)"

    if [[ "$METRICS_ENABLED" == "true" ]]; then
        [[ "$METRICS_PROFILE" == "auto" ]] && METRICS_PROFILE="$(detect_metrics_profile)"
        profile_valid "$METRICS_PROFILE" "$METRICS_PROFILES" \
            || die "perfil de métricas inválido: $METRICS_PROFILE (use: auto $METRICS_PROFILES)"
        if [[ "$MONITORING_ENABLED" == "true" ]]; then
            neighbors_gb=$(( neighbors_gb + $(metrics_budget_gb) ))
        else
            # --no-monitoring: só os exporters ficam neste host (~200 MB).
            neighbors_gb=$(( neighbors_gb + 1 ))
        fi
    fi

    if service_selected redis; then
        REDIS_PROFILE="$(ask "Perfil do Redis (auto dimensiona pela RAM)" "$REDIS_PROFILE")"
        # shellcheck disable=SC2119  # sem argumento = detectar pela RAM do host
        [[ "$REDIS_PROFILE" == "auto" ]] && REDIS_PROFILE="$(detect_redis_profile)"
        profile_valid "$REDIS_PROFILE" "$REDIS_PROFILES" \
            || die "perfil de Redis inválido: $REDIS_PROFILE (use: auto $REDIS_PROFILES)"
        neighbors_gb=$(( neighbors_gb + $(neighbor_budget_gb "$REDIS_PROFILE") ))
    fi

    if service_selected meilisearch; then
        MEILI_PROFILE="$(ask "Perfil do Meilisearch (auto dimensiona pela RAM)" "$MEILI_PROFILE")"
        # shellcheck disable=SC2119  # sem argumento = detectar pela RAM do host
        [[ "$MEILI_PROFILE" == "auto" ]] && MEILI_PROFILE="$(detect_meili_profile)"
        profile_valid "$MEILI_PROFILE" "$MEILI_PROFILES" \
            || die "perfil de Meilisearch inválido: $MEILI_PROFILE (use: auto $MEILI_PROFILES)"
        neighbors_gb=$(( neighbors_gb + $(neighbor_budget_gb "$MEILI_PROFILE") ))
    fi

    if service_selected postgres; then
        PG_PROFILE="$(ask "Perfil do Postgres (auto usa a RAM livre após os vizinhos)" "$PG_PROFILE")"
        if [[ "$PG_PROFILE" == "auto" ]]; then
            # Sem vizinhos (--services postgres) isto é a máquina inteira, e o
            # comportamento fica idêntico ao de antes.
            local livre=$(( mem_gb - neighbors_gb ))
            (( livre < 1 )) && livre=1
            PG_PROFILE="$(detect_pg_profile "$livre")"
        fi
        profile_valid "$PG_PROFILE" "$PG_PROFILES" \
            || die "perfil inválido: $PG_PROFILE (use: auto $PG_PROFILES)"

        # Um perfil maior do que a memória disponível não sobe: o Postgres falha
        # com "could not map anonymous shared memory" e fica em restart loop.
        # Melhor falhar aqui, com a razão explícita.
        local budget
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

        # A soma total ainda pode não caber: dedicada-8gb é o piso do catálogo,
        # então numa máquina pequena com todos os serviços não há perfil menor
        # para escolher.
        if (( budget + neighbors_gb > mem_gb )); then
            warn "orçamento apertado: $PG_PROFILE (~${budget} GB) + vizinhos (~${neighbors_gb} GB)"
            warn "passam dos ${mem_gb} GB disponíveis ao Docker."
            if [[ "$PG_PROFILE" == "dedicada-8gb" ]]; then
                warn "Este já é o menor perfil de Postgres. As saídas são reduzir os"
                warn "serviços deste host (--services, --no-monitoring) ou uma máquina maior."
            else
                warn "Reduza os serviços deste host ou aumente a máquina."
            fi
            warn "Ver a fórmula de coexistência em postgres/docs/perfis.md."
        fi
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

    if [[ "$METRICS_ENABLED" == "true" ]]; then
        # O perfil de métricas já foi resolvido e validado no bloco de
        # dimensionamento acima, junto com os demais vizinhos.

        # No macOS o node exporter e o cAdvisor leem o /proc da VM do Docker, não
        # do Mac — e o kernel da VM nem traz CONFIG_PSI. Ver monitoring/README.md.
        if [[ "$OS_FAMILY" == "macos" ]]; then
            info "macOS: node exporter e cAdvisor ficam desligados (medem a VM, não o host)"
        fi
    fi

    info "serviços ....... ${SERVICES[*]}"
    if service_selected postgres; then info "perfil PG ...... $PG_PROFILE"; fi
    if service_selected redis; then info "perfil Redis ... $REDIS_PROFILE"; fi
    if service_selected meilisearch; then info "perfil Meili ... $MEILI_PROFILE"; fi
    if [[ "$METRICS_ENABLED" == "true" ]]; then info "perfil métricas  $METRICS_PROFILE"; fi
    # O orçamento aparece explícito para que a decisão do 'auto' fique auditável
    # no log de provisionamento, e não só no comportamento.
    if service_selected postgres; then
        local pg_gb; pg_gb="$(profile_budget_gb "$PG_PROFILE")"
        info "memória ........ ${mem_gb} GB no Docker | Postgres ${pg_gb} + vizinhos ${neighbors_gb} = $(( pg_gb + neighbors_gb )) GB"
    fi
    info "volumes ........ $VOLUMES_MODE"
    info "publicação ..... ${BIND_IP} (firewall: ${ALLOW_FROM:-qualquer origem})"
    info "workdir ........ $WORKDIR"
}

# =============================================================================
# Estado da instalação
# =============================================================================
# Lê o `.setup-state` e preenche o que NÃO foi passado por flag.
#
# A regra é uma só, e é ela que torna o modo de atualização seguro:
#
#     flag explícita SOBRESCREVE · ausência HERDA do estado
#
# Sem isso, ligar observabilidade num host que já tem Postgres significava
# rodar o main() com os defaults de fábrica: POSTGRES_DB voltando para "dados"
# (o `.env` muda → o BANCO é recriado, e a DSN do exporter aponta para um
# database inexistente), BIND_IP para 0.0.0.0 (recriado E reexposto) e
# ALLOW_FROM para vazio (a chain DOCKER-USER esvaziada). Está documentado como
# risco imediato em 05 §5.1, e o contorno era repetir TODAS as flags da
# instalação original de cor.
load_state() {
    local arquivo="$WORKDIR/.setup-state"
    [[ -f "$arquivo" ]] || return 0

    local chave valor herdados=()

    while IFS='=' read -r chave valor; do
        [[ -z "$chave" || "$chave" == \#* ]] && continue

        case "$chave" in
            SERVICES)         foi_explicita SERVICES_INPUT  || { SERVICES_INPUT="$valor";  herdados+=("serviços=$valor"); } ;;
            POSTGRES_DB)      foi_explicita POSTGRES_DB     || { POSTGRES_DB="$valor";     herdados+=("postgres-db=$valor"); } ;;
            BIND_IP)          foi_explicita BIND_IP         || { BIND_IP="$valor";         herdados+=("bind-ip=$valor"); } ;;
            ALLOW_FROM)       foi_explicita ALLOW_FROM      || { ALLOW_FROM="$valor";      herdados+=("allow-from=$valor"); } ;;
            POSTGRES_PORT)    foi_explicita POSTGRES_PORT   || POSTGRES_PORT="$valor" ;;
            REDIS_PORT)       foi_explicita REDIS_PORT      || REDIS_PORT="$valor" ;;
            MEILI_PORT)       foi_explicita MEILI_PORT      || MEILI_PORT="$valor" ;;
            PG_PROFILE)       foi_explicita PG_PROFILE      || PG_PROFILE="$valor" ;;
            REDIS_PROFILE)    foi_explicita REDIS_PROFILE   || REDIS_PROFILE="$valor" ;;
            MEILI_PROFILE)    foi_explicita MEILI_PROFILE   || MEILI_PROFILE="$valor" ;;
            METRICS_PROFILE)  foi_explicita METRICS_PROFILE || METRICS_PROFILE="$valor" ;;
            # `METRICS_ENABLED` só é herdado quando LIGADO: desligar observabilidade
            # é uma decisão que precisa ser tomada, nunca herdada de um estado antigo.
            METRICS_ENABLED)  [[ "$valor" == "true" ]] && METRICS_ENABLED="true" ;;
            MONITORING_ENABLED) [[ "$METRICS_ENABLED" == "true" ]] && MONITORING_ENABLED="$valor" ;;
        esac
    done < "$arquivo"

    # `--add-service` acrescenta ao conjunto herdado em vez de substituí-lo. É a
    # diferença entre "agora este host tem também OpenSearch" e "agora este host
    # tem SÓ OpenSearch" — e a segunda leitura removeria os outros serviços do
    # conjunto gerenciado, com `--remove-orphans` levando os containers junto.
    if [[ -n "$ADD_SERVICE" ]]; then
        case ",$SERVICES_INPUT," in
            *",$ADD_SERVICE,"*) info "$ADD_SERVICE já está instalado" ;;
            *) SERVICES_INPUT="${SERVICES_INPUT},${ADD_SERVICE}" ;;
        esac
    fi

    if (( ${#herdados[@]} )); then
        ok "estado herdado de .setup-state: ${herdados[*]}"
    fi
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

    # ANTES de qualquer validação: as pré-checagens e o dimensionamento
    # coordenado precisam enxergar os valores herdados, não os defaults.
    load_state

    if [[ -f "$WORKDIR/.setup-state" && "$FORCE" != "true" ]]; then
        die "instalação existente em $WORKDIR — use --update para reaplicar a configuração herdando o estado, ou -f para refazer do zero (volumes preservados)"
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

# =============================================================================
# Parâmetros de kernel
# =============================================================================
# O `infra-setup.sh` não tinha etapa de sysctl até este roadmap (05 §5.2, item
# 5), e o OpenSearch não sobe sem uma: com `vm.max_map_count` no default do
# Debian (65530), o container morre no bootstrap check com uma mensagem que fala
# de `vm.max_map_count` e NÃO de OpenSearch — e quem lê procura o problema no
# lugar errado.
#
# A persistência em /etc/sysctl.d/ é a metade que costuma faltar: sem ela, o
# valor volta no próximo boot e o motor de busca não sobe junto com o host, o
# que transforma um reboot de rotina em incidente.
configure_sysctl() {
    [[ "$OS_FAMILY" == "linux" ]] || return 0

    # Só quando há serviço que precisa. Escrever sysctl num host que não roda
    # OpenSearch é mexer em configuração de kernel sem motivo.
    service_selected opensearch || return 0

    section "Parâmetros de kernel"

    local arquivo=/etc/sysctl.d/99-brasildatahub.conf
    local atual
    atual="$(sysctl -n vm.max_map_count 2>/dev/null || printf '0')"

    if [[ "$DRY_RUN" == "true" ]]; then
        _log "    ${C_DIM}[dry-run] vm.max_map_count: ${atual} → ${VM_MAX_MAP_COUNT} e ${arquivo}${C_RESET}"
        return 0
    fi

    if [[ "$atual" -lt "$VM_MAX_MAP_COUNT" ]]; then
        run sysctl -w "vm.max_map_count=${VM_MAX_MAP_COUNT}"
        ok "vm.max_map_count: ${atual} → ${VM_MAX_MAP_COUNT}"
    else
        ok "vm.max_map_count já em ${atual}"
    fi

    # Reescrever o arquivo inteiro, e não acrescentar: uma execução repetida
    # deixaria a mesma linha duas vezes, e a última venceria em silêncio.
    {
        printf '# GERADO por infra-setup.sh — não editar à mão.\n'
        printf '# O OpenSearch usa mmap para os segmentos do Lucene; o default do\n'
        printf '# Debian (65530) o faz morrer no bootstrap check.\n'
        printf 'vm.max_map_count=%s\n' "$VM_MAX_MAP_COUNT"
    } > "$arquivo"
    ok "persistido em ${arquivo}"
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

    # --- observabilidade ------------------------------------------------------
    # Os overlays de métricas ficam NO diretório do serviço que observam, e são
    # carregados com um -f extra (ver start_services). O compose de produção de
    # cada serviço não é tocado.
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        for s in "${SERVICES[@]}"; do
            dir="$(service_dir "$s")"
            if [[ "$DRY_RUN" != "true" ]]; then
                curl -fsSL "${RAW_BASE}/${s}/docker-compose.metrics.yml" \
                    -o "$dir/docker-compose.metrics.yml" \
                    || die "falha ao baixar ${RAW_BASE}/${s}/docker-compose.metrics.yml"
            fi
            ok "$s: overlay de métricas"
        done

        # O 03-role-metrics.sh vem para o host porque num cluster JÁ inicializado
        # o initdb não roda de novo — e a imagem em uso pode ser anterior a este
        # arquivo. O setup o alimenta por stdin (ver ensure_metrics_role).
        if service_selected postgres && [[ "$DRY_RUN" != "true" ]]; then
            curl -fsSL "${RAW_BASE}/postgres/initdb/03-role-metrics.sh" \
                -o "$(service_dir postgres)/03-role-metrics.sh" \
                || die "falha ao baixar 03-role-metrics.sh"
        fi
        if service_selected meilisearch && [[ "$DRY_RUN" != "true" ]]; then
            curl -fsSL "${RAW_BASE}/meilisearch/metrics-key.sh" \
                -o "$(service_dir meilisearch)/metrics-key.sh" \
                || die "falha ao baixar metrics-key.sh"
        fi

        # `monitoring` fica FORA do array SERVICES de propósito: ele tem DOIS
        # volumes, e o laço do modo bind abaixo (que chama service_volume_key)
        # geraria um override com YAML quebrado. Por isso é tratado à parte aqui.
        if [[ "$MONITORING_ENABLED" == "true" ]]; then
            dir="$(service_dir monitoring)"
            run mkdir -p "$dir/targets" "$dir/secrets"
            if [[ "$DRY_RUN" != "true" ]]; then
                curl -fsSL "${RAW_BASE}/monitoring/docker-compose.yml" \
                    -o "$dir/docker-compose.yml" \
                    || die "falha ao baixar ${RAW_BASE}/monitoring/docker-compose.yml"
                grep -q 'ghcr.io/brasildatahub' "$dir/docker-compose.yml" \
                    || die "conteúdo inesperado em $dir/docker-compose.yml (ref '$REF' existe?)"
                # O Prometheus recusa a config INTEIRA se o credentials_file do
                # job do Meilisearch não existir. Sem este arquivo, um host sem
                # Meilisearch ficaria sem monitoração nenhuma.
                touch "$dir/secrets/meili-metrics.key"
                protect_metrics_key "$dir/secrets/meili-metrics.key"
            fi
            ok "monitoring: compose em $dir"
        fi
    fi

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
    # Credenciais próprias da monitoração, de menor privilégio: a senha do
    # metrics_read não é a do postgres, e a chave do Meili não é a master key.
    [[ -z "$PG_METRICS_PASSWORD" ]] && PG_METRICS_PASSWORD="$(gen_secret)"
    [[ -z "$GRAFANA_ADMIN_PASSWORD" ]] && GRAFANA_ADMIN_PASSWORD="$(gen_secret)"

    # O perfil de métricas é baixado uma vez e reusado: os limites dos exporters
    # vivem nele, e vão para o .env de cada serviço. Fonte única, como nos demais
    # perfis do repositório.
    local profile_metrics=""
    if [[ "$METRICS_ENABLED" == "true" && "$DRY_RUN" != "true" ]]; then
        profile_metrics="$WORKDIR/services/.metrics-profile.env"
        fetch_profile monitoring > "$profile_metrics"
    fi

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

        # A senha do exporter do Postgres vai num arquivo SEPARADO, e isso é
        # deliberado: `env_file` faz parte da definição do serviço, então
        # acrescentar qualquer variável ao .env mudaria o hash de configuração e
        # o Compose RECRIARIA o container do banco. Medido, não suposto.
        # Só o postgres precisa disso — o redis_exporter reusa a REDIS_PASSWORD
        # que já está no .env, sem acrescentar nada.
        if [[ "$METRICS_ENABLED" == "true" && "$s" == "postgres" ]]; then
            {
                printf '# Credencial do postgres_exporter — gerado por infra-setup.sh em %s.\n' "$(now_iso)"
                printf '# Separado do .env de propósito: acrescentar variáveis ao .env do\n'
                printf '# serviço faria o Compose recriar o container do banco.\n'
                printf 'DATA_SOURCE_PASS=%s\n' "$PG_METRICS_PASSWORD"
            } > "$dir/.env.metrics"
            chmod 600 "$dir/.env.metrics"
            ok "postgres: credencial do exporter em .env.metrics"
        fi
    done

    if [[ "$METRICS_ENABLED" == "true" && "$MONITORING_ENABLED" == "true" && "$DRY_RUN" != "true" ]]; then
        # COMPOSE_PROFILES é do Compose e NÃO é "perfil" no sentido deste
        # repositório: define quais coletores existem, não o dimensionamento.
        # node/cadvisor só em Linux — no macOS mediriam a VM do Docker, e o
        # kernel dela nem traz CONFIG_PSI (ver monitoring/README.md).
        local compose_profiles=""
        if [[ "$OS_FAMILY" == "linux" ]]; then
            compose_profiles="node"
            [[ "$METRICS_CONTAINERS" == "true" ]] && compose_profiles="node,containers"
        fi

        dir="$(service_dir monitoring)"
        {
            cat "$profile_metrics"
            printf '\n# --- deploy (gerado por infra-setup.sh em %s) ---\n' "$(now_iso)"
            printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD"
            printf 'MON_HOSTNAME=%s\n' "$(hostname)"
            printf 'MONITORING_BIND_IP=%s\n' "$MONITORING_BIND_IP"
            printf 'PROMETHEUS_PORT=%s\nGRAFANA_PORT=%s\n' "$PROMETHEUS_PORT" "$GRAFANA_PORT"
            printf 'METRICS_NETWORK=%s\n' "$METRICS_NETWORK"
            printf 'GRAFANA_ROOT_URL=http://localhost:%s\n' "$GRAFANA_PORT"
            printf 'COMPOSE_PROFILES=%s\n' "$compose_profiles"
        } > "$dir/.env"
        chmod 600 "$dir/.env"
        ok "monitoring: .env gerado do perfil $METRICS_PROFILE"
    fi

    # O perfil de métricas já foi distribuído para os .env; não precisa ficar no
    # disco (e não deve, para não virar uma segunda fonte de verdade).
    [[ -n "$profile_metrics" && -f "$profile_metrics" ]] && rm -f "$profile_metrics"

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
            if [[ "$METRICS_ENABLED" == "true" ]]; then
                printf '\n# --- observabilidade ---\n'
                # Credenciais de MENOR privilégio, não cópias das de cima:
                # metrics_read só lê estatísticas (pg_monitor), e a chave do
                # Meilisearch só serve para /metrics.
                printf 'PG_METRICS_PASSWORD=%s\n' "$PG_METRICS_PASSWORD"
                if [[ "$MONITORING_ENABLED" == "true" ]]; then
                    printf 'GRAFANA_ADMIN_PASSWORD=%s\nGRAFANA_PORT=%s\nPROMETHEUS_PORT=%s\n' \
                        "$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_PORT" "$PROMETHEUS_PORT"
                fi
            fi
        } > "$WORKDIR/secrets/credentials.env.novo"

        # MERGE, e não sobrescrita. O arquivo era reescrito com as credenciais
        # apenas dos serviços DESTA execução: um `--add-service opensearch` num
        # host que já tinha Postgres e Redis truncava as senhas dos dois, e o
        # operador só descobria ao precisar delas — quando `bdh creds --show`
        # devolvesse metade do que devolvia antes.
        #
        # A chave da linha nova vence a antiga; o que não foi regerado sobrevive.
        if [[ -f "$WORKDIR/secrets/credentials.env" ]]; then
            local chaves_novas
            chaves_novas="$(grep -oE '^[A-Z][A-Z0-9_]*=' "$WORKDIR/secrets/credentials.env.novo" || true)"
            {
                cat "$WORKDIR/secrets/credentials.env.novo"
                printf '\n# --- preservadas de execuções anteriores ---\n'
                while IFS= read -r linha; do
                    case "$linha" in
                        ''|'#'*) continue ;;
                    esac
                    local chave="${linha%%=*}="
                    case "$chaves_novas" in
                        *"$chave"*) continue ;;
                    esac
                    printf '%s\n' "$linha"
                done < "$WORKDIR/secrets/credentials.env"
            } > "$WORKDIR/secrets/credentials.env.merge"
            mv "$WORKDIR/secrets/credentials.env.merge" "$WORKDIR/secrets/credentials.env"
            rm -f "$WORKDIR/secrets/credentials.env.novo"
        else
            mv "$WORKDIR/secrets/credentials.env.novo" "$WORKDIR/secrets/credentials.env"
        fi

        chmod 600 "$WORKDIR/secrets/credentials.env"
        ok "credenciais em $WORKDIR/secrets/credentials.env (chmod 600)"

        {
            printf 'SCRIPT_VERSION=%s\n' "$SCRIPT_VERSION"
            printf 'REF=%s\n' "$REF"
            printf 'INSTALLED_AT=%s\n' "$(now_iso)"
            printf 'SERVICES=%s\n' "$(IFS=,; printf '%s' "${SERVICES[*]}")"
            printf 'VOLUMES_MODE=%s\n' "$VOLUMES_MODE"
            # As cinco chaves abaixo são o que faltava, e a ausência delas era o
            # defeito: sem POSTGRES_DB, BIND_IP e ALLOW_FROM no estado, a segunda
            # execução recriava o banco, reexpunha as portas e esvaziava o
            # firewall — em silêncio, porque cada valor sozinho parece plausível.
            printf 'WORKDIR=%s\n' "$WORKDIR"
            printf 'POSTGRES_DB=%s\n' "$POSTGRES_DB"
            printf 'BIND_IP=%s\n' "$BIND_IP"
            printf 'ALLOW_FROM=%s\n' "$ALLOW_FROM"
            printf 'POSTGRES_PORT=%s\n' "$POSTGRES_PORT"
            printf 'REDIS_PORT=%s\n' "$REDIS_PORT"
            printf 'MEILI_PORT=%s\n' "$MEILI_PORT"
            # Cada bloco num `if`: uma condição falsa como última expressão do
            # grupo faria o `set -e` abortar o script (era o caso quando o
            # Meilisearch não estava entre os serviços escolhidos).
            if service_selected postgres; then printf 'PG_PROFILE=%s\n' "$PG_PROFILE"; fi
            if service_selected redis; then printf 'REDIS_PROFILE=%s\n' "$REDIS_PROFILE"; fi
            if service_selected meilisearch; then printf 'MEILI_PROFILE=%s\n' "$MEILI_PROFILE"; fi
            printf 'METRICS_ENABLED=%s\n' "$METRICS_ENABLED"
            if [[ "$METRICS_ENABLED" == "true" ]]; then
                printf 'METRICS_PROFILE=%s\n' "$METRICS_PROFILE"
                printf 'MONITORING_ENABLED=%s\n' "$MONITORING_ENABLED"
            fi
        } > "$WORKDIR/.setup-state"
    fi
}

start_services() {
    section "Subindo os serviços"
    local s dir compose_args
    for s in "${SERVICES[@]}"; do
        dir="$(service_dir "$s")"
        compose_args=(--project-directory "$dir" -f "$dir/docker-compose.yml")
        # Ordem: base → metrics → override. O override do modo bind é o último a
        # falar sobre volumes, exatamente como antes de existir o overlay.
        [[ -f "$dir/docker-compose.metrics.yml" ]] && compose_args+=(-f "$dir/docker-compose.metrics.yml")
        [[ -f "$dir/docker-compose.override.yml" ]] && compose_args+=(-f "$dir/docker-compose.override.yml")
        # --metrics-only acrescenta o exporter sem --force-recreate: o Compose
        # compara a definição desejada com a atual e recria apenas o que mudou,
        # ou seja, só o container novo. O banco não é tocado.
        if [[ "$FORCE" == "true" && "$METRICS_ONLY" != "true" ]]; then
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

setup_metrics() {
    [[ "$METRICS_ENABLED" != "true" ]] && return 0
    section "Observabilidade"

    if [[ "$DRY_RUN" == "true" ]]; then
        _log "    ${C_DIM}[dry-run] criaria a role de métricas, a chave do Meilisearch e subiria o monitoring${C_RESET}"
        return 0
    fi

    # Esta etapa é a primeira do script que depende do ESTADO DOS DADOS, e não
    # só da máquina. Por isso nada aqui usa `die`: uma falha aqui não pode
    # derrubar um provisionamento que já subiu os bancos com sucesso.

    # --- role de leitura de estatísticas do Postgres --------------------------
    if service_selected postgres; then
        local cid role_script
        cid="$(docker ps -q --filter "label=org.brasildatahub.service=postgres" | head -1)"
        role_script="$(service_dir postgres)/03-role-metrics.sh"
        if [[ -z "$cid" ]]; then
            warn "postgres não está em execução — role de métricas não criada"
        elif docker exec -i \
                -e POSTGRES_DB="$POSTGRES_DB" \
                -e PG_METRICS_PASSWORD="$PG_METRICS_PASSWORD" \
                "$cid" bash -s < "$role_script" >/dev/null 2>&1; then
            ok "role metrics_read pronta (pg_monitor, sem acesso a dados)"
        else
            warn "não foi possível criar a role metrics_read. O postgres-exporter"
            warn "vai ficar em erro de autenticação até isto ser resolvido. À mão:"
            warn "  docker exec -i -e POSTGRES_DB=$POSTGRES_DB -e PG_METRICS_PASSWORD=... \\"
            warn "      \$(docker ps -q --filter label=org.brasildatahub.service=postgres) \\"
            warn "      bash -s < $role_script"
        fi
    fi

    # --- chave escopada do Meilisearch ---------------------------------------
    if service_selected meilisearch; then
        local key_script
        key_script="$(service_dir meilisearch)/metrics-key.sh"
        MEILI_METRICS_KEY="$(MEILI_MASTER_KEY="$MEILI_MASTER_KEY" \
            bash "$key_script" "http://127.0.0.1:${MEILI_PORT}" 2>/dev/null || true)"
        if [[ -n "$MEILI_METRICS_KEY" ]]; then
            ok "chave de métricas do Meilisearch pronta (ação metrics.get apenas)"
        else
            warn "não foi possível criar a chave de métricas do Meilisearch."
            warn "O job vai ficar em 401. À mão, com a master key:"
            warn "  MEILI_MASTER_KEY=... bash $key_script http://127.0.0.1:${MEILI_PORT}"
        fi
    fi

    [[ "$MONITORING_ENABLED" != "true" ]] && {
        info "--no-monitoring: exporters no ar, Prometheus deve ser apontado de fora"
        info "  os exporters escutam na rede Docker '${METRICS_NETWORK}', sem porta publicada"
        return 0
    }

    # --- alvos e segredo do Prometheus ---------------------------------------
    local mdir; mdir="$(service_dir monitoring)"
    run mkdir -p "$mdir/targets" "$mdir/secrets"

    # Os alvos são nomes de SERVIÇO Compose: na rede compartilhada o Docker
    # registra o nome do serviço como alias, então o endereço não depende do
    # nome do projeto. Um arquivo por serviço instalado — serviço ausente não
    # deixa arquivo, o glob do prometheus.yml não casa nada, e o job fica sem
    # alvo em vez de ficar `up == 0` para sempre.
    service_selected postgres \
        && printf '[{"targets":["postgres-exporter:9187"]}]\n' > "$mdir/targets/postgres.json"
    service_selected redis \
        && printf '[{"targets":["redis-exporter:9121"]}]\n' > "$mdir/targets/redis.json"
    if service_selected meilisearch && [[ -n "$MEILI_METRICS_KEY" ]]; then
        printf '[{"targets":["meilisearch:7700"]}]\n' > "$mdir/targets/meilisearch.json"
        printf '%s' "$MEILI_METRICS_KEY" > "$mdir/secrets/meili-metrics.key"
    fi
    if [[ "$OS_FAMILY" == "linux" ]]; then
        printf '[{"targets":["node-exporter:9100"]}]\n' > "$mdir/targets/node.json"
        [[ "$METRICS_CONTAINERS" == "true" ]] \
            && printf '[{"targets":["cadvisor:8080"]}]\n' > "$mdir/targets/cadvisor.json"
    fi
    protect_metrics_key "$mdir/secrets/meili-metrics.key"
    ok "alvos escritos em $mdir/targets/"

    # --- sobe a stack ---------------------------------------------------------
    # O `if !` é o que mantém a promessa do comentário no topo desta função: sob
    # `set -e`, um `run docker compose` solto aborta o SCRIPT INTEIRO quando o
    # pull falha (registry fora do ar, imagem não publicada), e o provisionamento
    # morre antes de `configure_firewall` — deixando os bancos publicados em
    # 0.0.0.0 com o ufw ainda inativo. Aconteceu em 2026-07-27.
    local compose_args=(--project-directory "$mdir" -f "$mdir/docker-compose.yml")
    local up_args=(up -d)
    [[ "$FORCE" == "true" ]] && up_args+=(--force-recreate)
    if ! run docker compose -p monitoring "${compose_args[@]}" "${up_args[@]}"; then
        warn "monitoring não subiu — o provisionamento segue sem observabilidade."
        warn "Veja 'bdh logs monitoring' e depois rode: bash infra-setup.sh --metrics-only"
        notify "progress" "observabilidade falhou; provisionamento continua"
        return 0
    fi
    ok "monitoring no ar"

    local waited=0 health
    while (( waited < 60 )); do
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            "$(docker ps -q --filter "label=org.brasildatahub.service=monitoring" | head -1)" 2>/dev/null || echo starting)"
        [[ "$health" == "healthy" || "$health" == "none" ]] && break
        sleep 5; waited=$((waited + 5))
    done
    if [[ "$health" == "healthy" ]]; then
        ok "Prometheus saudável"
    else
        warn "Prometheus ainda não saudável — veja 'bdh logs monitoring'"
    fi

    notify "progress" "observabilidade no ar"
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

    # Grafana e Prometheus só entram no firewall quando NÃO estão em loopback:
    # com -p 127.0.0.1:3000:3000 o Docker cria a regra de DNAT apenas para
    # destino loopback, e nada externo casa. É o único caso nesta infraestrutura
    # em que a armadilha do DOCKER-USER não morde — por isso o default.
    if [[ "$METRICS_ENABLED" == "true" && "$MONITORING_ENABLED" == "true" \
          && "$MONITORING_BIND_IP" != "127.0.0.1" ]]; then
        local mport
        for mport in "$GRAFANA_PORT" "$PROMETHEUS_PORT"; do
            if [[ -n "$ALLOW_FROM" ]]; then
                IFS=',' read -r -a cidrs <<< "$ALLOW_FROM"
                for cidr in "${cidrs[@]}"; do
                    run ufw allow from "$cidr" to any port "$mport" proto tcp
                done
            else
                run ufw allow "${mport}/tcp"
                warn "monitoração: porta $mport aberta para QUALQUER origem"
                warn "  o Prometheus NÃO TEM AUTENTICAÇÃO — prefira --metrics-bind-ip 127.0.0.1"
            fi
        done
    fi

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

    # A ORDEM AQUI JÁ FOI UM DEFEITO. A versão anterior esvaziava a chain e só
    # depois checava `ALLOW_FROM`: numa execução sem a flag — que é o caso de
    # `--metrics-only` sem repetir todas as flags da instalação original — o
    # firewall dos containers era APAGADO e não reconstruído. As três portas de
    # dados voltavam a aceitar conexão de qualquer origem, em silêncio, e o
    # `ufw status` continuava mostrando `active`, porque a DOCKER-USER não
    # aparece ali.
    #
    # Regra: nunca esvaziar sem repovoar. Sem `ALLOW_FROM`, a chain existente é
    # deixada exatamente como está.
    if [[ -z "$ALLOW_FROM" ]]; then
        run ufw reload
        if iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j DROP'; then
            warn "sem --allow-from: a chain DOCKER-USER existente foi PRESERVADA."
            warn "para alterá-la, repita --allow-from com a lista completa de origens."
        else
            warn "portas publicadas acessíveis de qualquer origem (sem --allow-from)"
            warn "as três portas de dados aceitam conexão da internet inteira."
        fi
        return 0
    fi

    # RECONSTRUÇÃO A PARTIR DO ESTADO. Com `ALLOW_FROM` herdado do
    # `.setup-state` (load_state) e a chain vazia — o cenário que uma execução
    # anterior sem a flag produzia —, chegar aqui é o que a repovoa. Antes, o
    # firewall só voltava se alguém repetisse a flag de cor.
    if ! iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j DROP'; then
        info "chain DOCKER-USER vazia: reconstruindo a partir de ALLOW_FROM=${ALLOW_FROM}"
    fi

    # Daqui para baixo há `ALLOW_FROM`, então esvaziar é seguro: a chain é
    # reconstruída logo abaixo, no mesmo bloco. `ufw reload` sozinho não
    # bastaria — ele reaplica o arquivo, e as regras já inseridas continuariam
    # na chain.
    iptables -F DOCKER-USER 2>/dev/null || true

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
  bdh pull [serviço]       puxa a imagem nova da MESMA tag e recria só o que mudou
  bdh metrics              estado dos alvos do Prometheus
  bdh creds [--show]       caminho (ou conteúdo) das credenciais
  bdh path <serviço>       diretório do serviço

Serviços: postgres, redis, meilisearch, opensearch, pgbouncer, monitoring
USAGE
}

svc_dir() { printf '%s/services/%s' "$BDH_ROOT" "$1"; }

compose() {
    local svc="$1"; shift
    local dir; dir="$(svc_dir "$svc")"
    [[ -d "$dir" ]] || { echo "serviço '$svc' não provisionado em $dir" >&2; exit 1; }
    local args=(--project-directory "$dir" -f "$dir/docker-compose.yml")
    # Mesma ordem do infra-setup.sh: base → metrics → override.
    [[ -f "$dir/docker-compose.metrics.yml" ]] && args+=(-f "$dir/docker-compose.metrics.yml")
    [[ -f "$dir/docker-compose.override.yml" ]] && args+=(-f "$dir/docker-compose.override.yml")
    docker compose -p "$svc" "${args[@]}" "$@"
}

cmd_metrics() {
    local dir; dir="$(svc_dir monitoring)"
    [[ -d "$dir" ]] || { echo "monitoração não provisionada (rode com --metrics)" >&2; exit 1; }

    local porta
    porta="$(grep -h '^PROMETHEUS_PORT=' "$dir/.env" 2>/dev/null | cut -d= -f2-)"
    porta="${porta:-9090}"

    echo "== alvos do Prometheus"
    # Sem jq no host: python3 está em qualquer Debian/Ubuntu e no macOS.
    if ! _t 5 curl -fsS "http://127.0.0.1:${porta}/api/v1/targets" 2>/dev/null | python3 -c '
import json, sys
alvos = json.load(sys.stdin)["data"]["activeTargets"]
if not alvos:
    print("  nenhum alvo configurado — veja os arquivos em targets/")
for t in sorted(alvos, key=lambda x: x["labels"]["job"]):
    erro = t.get("lastError", "")
    print("  %-14s %-34s %s%s" % (t["labels"]["job"], t["scrapeUrl"], t["health"],
                                  "  " + erro[:60] if erro else ""))
' 2>/dev/null; then
        echo "  Prometheus não respondeu em 127.0.0.1:${porta}"
        echo "  (ele publica só em loopback por default — rode isto no próprio host)"
        exit 1
    fi

    echo
    echo "== alertas disparando"
    _t 5 curl -fsS "http://127.0.0.1:${porta}/api/v1/alerts" 2>/dev/null | python3 -c '
import json, sys
a = [x for x in json.load(sys.stdin)["data"]["alerts"] if x["state"] == "firing"]
print("  nenhum") if not a else [
    print("  %-34s %s" % (x["labels"]["alertname"], x["annotations"].get("summary", "")))
    for x in a]
' 2>/dev/null || echo "  (não foi possível consultar)"

    echo
    echo "== séries ativas (vigie a cardinalidade: o TSDB divide o disco com o banco)"
    _t 5 curl -fsS --get "http://127.0.0.1:${porta}/api/v1/query" \
        --data-urlencode 'query=count by (job) ({__name__=~".+"})' 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)["data"]["result"]
total = 0
for x in sorted(r, key=lambda y: -int(y["value"][1])):
    total += int(x["value"][1])
    print("  %-14s %7s" % (x["metric"].get("job", "?"), x["value"][1]))
print("  %-14s %7d" % ("TOTAL", total))
' 2>/dev/null || echo "  (não foi possível consultar)"
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

cmd_pull() {
    # Atualizar a imagem de um serviço era o único caminho não coberto: as tags
    # nos composes são fixas (`:17`, `:7`), então `docker compose pull` traz a
    # versão nova daquela tag maior — e sem um comando, isso virava
    # `docker compose -f ... -f ... pull` digitado à mão, com os overlays certos
    # e na ordem certa.
    local alvos svc
    if [[ -n "$1" ]]; then
        alvos="$1"
    else
        alvos="$(docker ps --format '{{.Label "org.brasildatahub.service"}}' \
                 | grep -vE '^$|exporter|cadvisor|monitoring-' | sort -u)"
    fi

    for svc in $alvos; do
        [[ -d "$(svc_dir "$svc")" ]] || { echo "  ! $svc não está instalado aqui" >&2; continue; }
        echo "==> $svc"
        compose "$svc" pull
        # `up -d` sem `--force-recreate`: o Compose recria SÓ o que mudou. Num
        # banco de centenas de GB, um recreate desnecessário é downtime e page
        # cache frio.
        compose "$svc" up -d
    done
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
        # Comparação, e não só exibição. Este é o gate de D-1 do runbook mensal:
        # em 25/07 foram perdidas 6h43 de ETL porque o mount havia voltado aos
        # 64 MB de default e ninguém CONFERIU o número — ele estava na tela.
        # `bdh verify` agora sai != 0 quando diverge, para poder ser usado num
        # `set -e` ou num checklist automatizado.
        local shm_esperado shm_real
        shm_esperado="$(grep -h '^PG_SHM_BYTES=' "$(svc_dir postgres)/.env" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
        shm_real="$(docker exec "$cid" stat -f -c '%s * %b' /dev/shm 2>/dev/null | tr -d ' ')"
        if [[ -n "$shm_esperado" && -n "$shm_real" ]]; then
            shm_real="$(( ${shm_real%%\**} * ${shm_real##*\*} ))"
            if [[ "$shm_real" -lt "$shm_esperado" ]]; then
                echo "   ✗ /dev/shm tem $shm_real bytes; o perfil pede $shm_esperado."
                echo "     Um redeploy devolveu o mount ao default. NÃO inicie a carga mensal."
                VERIFY_FALHOU=1
            else
                echo "   ✓ /dev/shm confere com PG_SHM_BYTES ($shm_esperado bytes)"
            fi
        else
            echo "   ! não foi possível comparar /dev/shm com PG_SHM_BYTES"
        fi
        echo "== shm-guard"
        docker logs "$cid" 2>&1 | grep shm-guard | tail -2 || echo "(sem linhas do shm-guard)"
        echo "== entradas inválidas no postgresql.conf (deve vir vazio)"
        local db; db="$(grep -h '^POSTGRES_DB=' "$(svc_dir postgres)/.env" | cut -d= -f2-)"
        docker exec "$cid" psql -U postgres -d "${db:-postgres}" -c \
            "SELECT sourceline, name, error FROM pg_file_settings WHERE NOT applied OR error IS NOT NULL;"
    fi
    return "${VERIFY_FALHOU:-0}"
}

case "${1:-status}" in
    status) shift || true; cmd_status "${1:-}" ;;
    logs) svc="${2:?serviço}"; shift 2; compose "$svc" logs "$@" ;;
    up) compose "${2:?serviço}" up -d ;;
    down) compose "${2:?serviço}" down ;;      # sem -v: nunca apaga volume
    restart) compose "${2:?serviço}" restart ;;
    verify) cmd_verify "${2:-postgres}" ;;
    pull) cmd_pull "${2:-}" ;;
    metrics) cmd_metrics ;;
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
    if [[ "$METRICS_ENABLED" == "true" && "$MONITORING_ENABLED" == "true" ]]; then
        _log ""
        _log "    ${C_BOLD}observabilidade${C_RESET}"
        if [[ "$MONITORING_BIND_IP" == "127.0.0.1" ]]; then
            info "  Grafana e Prometheus escutam só em loopback (o Prometheus não tem"
            info "  autenticação). Para acessar da sua máquina:"
            info "    ssh -L ${GRAFANA_PORT}:127.0.0.1:${GRAFANA_PORT} -L ${PROMETHEUS_PORT}:127.0.0.1:${PROMETHEUS_PORT} $(whoami)@$(hostname)"
            info "    e abra http://127.0.0.1:${GRAFANA_PORT}  (usuário admin)"
        else
            info "  Grafana ....... http://${MONITORING_BIND_IP}:${GRAFANA_PORT}  (usuário admin)"
            info "  Prometheus .... http://${MONITORING_BIND_IP}:${PROMETHEUS_PORT}"
        fi
        info "  senha do admin em secrets/credentials.env ('bdh creds --show')"
        info "  perfil de métricas: $METRICS_PROFILE"
    fi
    _log ""
    _log "    ${C_BOLD}operação${C_RESET}"
    info "  bdh status | bdh logs <serviço> | bdh verify [serviço]"
    [[ "$METRICS_ENABLED" == "true" ]] && info "  bdh metrics — estado dos alvos e alertas"
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
    configure_sysctl
    install_docker
    configure_docker_data_root
    create_layout
    write_env_files
    start_services
    setup_metrics
    configure_firewall
    install_cli_and_motd
    summary
}

# BDH_SETUP_LIB_ONLY=1 carrega as funções sem provisionar nada — é como
# test/infra-setup.test.sh exercita a lógica de perfis e caminhos.
if [[ -z "${BDH_SETUP_LIB_ONLY:-}" ]]; then
    main
fi
