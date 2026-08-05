#!/usr/bin/env bash
# =============================================================================
# setup.sh — provisiona VPS com Docker Compose (PostgreSQL, Redis, Meilisearch…).
#
#   curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh \
#     | sudo bash -s -- --auto
#
# Composes vêm do repositório (fonte de verdade). Deploy manual: postgres/docs/deploy.md.
# Linux+systemd (root): Docker, timezone, firewall, MOTD.
# macOS: usa Docker já instalado; sem firewall/MOTD; com ou sem sudo.
# =============================================================================
set -euo pipefail

case "$(uname -s)" in
    Linux)  OS_FAMILY="linux" ;;
    Darwin) OS_FAMILY="macos" ;;
    *)      printf 'Sistema não suportado: %s (use Linux Debian/Ubuntu ou macOS)\n' "$(uname -s)" >&2; exit 1 ;;
esac

SCRIPT_VERSION="1.0.0"

# --- flags explicitamente informadas -----------------------------------------
# Distingue "usuário pediu" de "default": `--bind-ip 0.0.0.0` e ausência da flag
# produzem a mesma string. Sem isto, reexecução herda defaults e recria/reexpõe.
# Lista (não `declare -A`): bash 3.2 do macOS não tem arrays associativos.
FLAGS_EXPLICITAS=""
_explicita()    { FLAGS_EXPLICITAS="${FLAGS_EXPLICITAS} $1"; }
foi_explicita() { case " $FLAGS_EXPLICITAS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- defaults ----------------------------------------------------------------
REPO_SLUG="BrasilDataHub/plataforma"
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
# `auto`: divide o host ou dedica. OpenSearch dimensiona pelo vizinho (page cache
# do Lucene), não pela RAM bruta.
OPENSEARCH_PROFILE="auto"
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
# Sem autenticação (plugin desligado): a barreira é o firewall / --allow-from.
OPENSEARCH_PORT="9200"
# Host da aplicação; default loopback — publicar fora abre caminho ao banco.
PGBOUNCER_PORT="6432"
PGBOUNCER_BIND_IP="127.0.0.1"
# Vazio = resolver em write_env_files (BIND_IP ou gateway da bridge).
# Projetos Compose distintos: o nome `postgres` não resolve daqui.
PGBOUNCER_DB_HOST=""
# Vazio = POSTGRES_PORT. Separado: pooler pode apontar a outro host/porta.
PGBOUNCER_DB_PORT=""
PGBOUNCER_DB_USER="postgres"
ALLOW_FROM=""
ENABLE_FIREWALL="true"
# 262144 é o mínimo que o bootstrap check do OpenSearch exige.
VM_MAX_MAP_COUNT="262144"

# --- observabilidade (opt-in por --metrics) ----------------------------------
# Opt-in: ~1,5 GB fora do orçamento de detect_pg_profile().
METRICS_ENABLED="false"
METRICS_ONLY="false"             # --metrics-only: acrescenta métricas SEM recriar os serviços
UPDATE_MODE="false"              # --update / --add-service: herda o estado e reaplica
SOMENTE_MONITORING="false"       # --services monitoring: host só de observabilidade
ADD_SERVICE=""                   # serviço a acrescentar sem tocar nos demais
MONITORING_ENABLED="true"        # --no-monitoring: só exporters, Prometheus alhures
METRICS_PROFILE="auto"
METRICS_CONTAINERS="false"       # --metrics-containers liga o cAdvisor
# --- coleta remota (Prometheus num host, serviços em outro) -------------------
# Overlays: docker-compose.metrics-remote.yml / monitoring/docker-compose.remote.yml.
METRICS_PUBLISH_IP=""            # --metrics-publish: interface onde os exporters escutam
METRICS_SCRAPE=""                # --metrics-scrape: alvos remotos (job=host:porta,...)
# --host-label: rótulo nas séries quando o hostname do SO não serve (ex.: Swarm).
# Vazio = hostname.
HOST_LABEL=""
METRICS_NETWORK="bdh_metrics"
MONITORING_BIND_IP="127.0.0.1"   # NUNCA reusar BIND_IP: o default dele é 0.0.0.0
# --- destino dos alertas ------------------------------------------------------
# Alertmanager recusa subir sem receiver; sem destino, fica de fora do up.
ALERT_SLACK_WEBHOOK=""
ALERT_SLACK_CHANNEL=""
ALERT_WEBHOOK_URL=""
ALERT_EMAIL_TO=""
ALERT_EMAIL_FROM=""
ALERT_SMTP_HOST=""
ALERT_SMTP_USER=""
ALERT_SMTP_PASSWORD=""
# URL humana do Alertmanager (`title_link`); hostname de container é recusado.
ALERT_EXTERNAL_URL="http://localhost:9093"
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
# Reaplicar config ≠ recriar container. Sem --force-recreate o Compose só
# recria o que mudou (perfil/imagem/overlay).
RECREATE="false"
WEBHOOK_URL=""

LOG_FILE=""
declare -a SERVICES=()

# Destinos que variam com a plataforma e com haver ou não privilégio de root.
# Definidos em preflight().
CONF_DIR=""
BIN_DIR=""

# `date -Is` é GNU; o BSD date do macOS não aceita.
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- rótulo de máquina dos alvos ---------------------------------------------
# `external_labels` não vão ao TSDB; o `host` útil está no arquivo de alvos.
# Hostname cru (sem normalizar): igual a `nodename` do node_exporter.
host_label() {
    local n="${1-}"
    # --host-label vence o hostname, e só para os alvos LOCAIS: o apelido de um
    # alvo remoto vem do próprio --metrics-scrape e é passado como argumento.
    [[ -z "$n" ]] && n="${HOST_LABEL:-}"
    [[ -z "$n" ]] && n="$(hostname 2>/dev/null || true)"
    # Valor de rótulo aceita qualquer UTF-8; o que não pode é quebrar o JSON.
    n="${n//[\"\\]/-}"; n="${n//[[:space:]]/-}"
    printf '%s' "${n:-desconhecido}"
}

# Endereço sem a porta — é o rótulo de fallback quando não há apelido.
endereco_sem_porta() {
    case "$1" in
        \[*\]:*) local a="${1%]:*}"; printf '%s' "${a#[}" ;;
        *:*)     printf '%s' "${1%:*}" ;;
        *)       printf '%s' "$1" ;;
    esac
}

# file_sd remoto: um objeto por alvo (rótulo `host` por máquina).
# Formato --metrics-scrape: job=endereço[@apelido], separados por vírgula.
alvos_remotos_json() {   # $1 = job   $2 = lista no formato de --metrics-scrape
    local job="$1" par destino apelido saida=""
    local -a pares=(); IFS=',' read -r -a pares <<< "$2"
    for par in "${pares[@]}"; do
        [[ "$par" == "$job="* ]] || continue
        destino="${par#*=}"; apelido=""
        case "$destino" in *@*) apelido="${destino##*@}"; destino="${destino%@*}" ;; esac
        [[ -z "$apelido" ]] && apelido="$(endereco_sem_porta "$destino")"
        saida="${saida}${saida:+,}$(printf '{"targets":["%s"],"labels":{"host":"%s"}}' \
                 "$destino" "$(host_label "$apelido")")"
    done
    [[ -z "$saida" ]] && return 1
    printf '[%s]' "$saida"
}

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
    payload=$(printf '{"host":"%s","script":"setup","version":"%s","status":"%s","message":"%s","timestamp":"%s"}' \
        "$(hostname)" "$SCRIPT_VERSION" "$status" "${message//\"/\\\"}" "$(now_iso)")
    # Webhook nunca derruba o provisionamento.
    curl -fsS -m 5 -X POST -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

trap 'notify "failed" "abortado na linha $LINENO"' ERR

# --- ajuda -------------------------------------------------------------------
usage() {
    cat <<'HELP'
setup.sh — provisiona uma máquina para os serviços de dados da BrasilDataHub.

USAGE:
    curl -fsSL https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh \
      | sudo bash -s -- [OPTIONS]

    # ou, para revisar antes de executar (recomendado):
    curl -fsSL .../setup.sh -o setup.sh && less setup.sh
    sudo bash setup.sh [OPTIONS]

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
                             | cache-2gb | cache-4gb            (default: auto)
                             cache-4gb só para instância DEDICADA a cache:
                             usa allkeys-lru, que descartaria job de fila.
                             O `auto` nunca o escolhe — é opção explícita.
      --meili-profile PERFIL auto | busca-512mb | busca-1gb | busca-4gb
                             | busca-16gb                       (default: auto)
      --opensearch-profile PERFIL
                             auto | compartilhada-8gb | dedicada-16gb
                             (default: auto). 'auto' NÃO olha a RAM: olha COM
                             QUEM o motor divide o host. Sozinho numa máquina de
                             14 GiB ou mais, `dedicada-16gb`; ao lado de
                             Postgres, Redis ou Meilisearch, `compartilhada-8gb`
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

    COLETA REMOTA — Prometheus num host, serviços em outro:
      --metrics-publish IP   No host OBSERVADO. Publica os exporters (e o node
                             exporter) NESTA interface — use a privada, nunca
                             0.0.0.0: /metrics não tem autenticação e entrega
                             pg_settings_* inteiro. Implica --metrics e
                             --no-monitoring.
      --metrics-scrape LISTA No host do PROMETHEUS. Alvos remotos, no formato
                             job=host:porta[@apelido] separados por vírgula. O
                             apelido é o NOME da máquina e vira o rótulo `host`
                             das séries — use o hostname dela (o próprio host
                             observado imprime a linha pronta ao rodar com
                             --metrics-publish). Sem apelido, o rótulo cai para
                             o endereço. IPv6 exige colchetes. Jobs aceitos:
                             postgres, redis, node, opensearch, meilisearch,
                             cadvisor. Ex.:
                               --metrics-scrape postgres=10.0.1.10:9187@bdh-data,\
                             node=10.0.1.10:9100@bdh-data,\
                             opensearch=10.0.1.11:9200@bdh-search
      --metrics-bind-ip IP   Interface do Grafana e do Prometheus
                             (default: 127.0.0.1 — use um túnel SSH)
      --host-label NOME      Nome desta máquina nas séries, quando o hostname do
                             SO não serve. O default é o `hostname`, e é o que
                             você quer na maioria dos casos. Use esta flag quando
                             renomear o host não for possível — num nó Docker
                             Swarm, por exemplo, o hostname está registrado no
                             cluster e trocá-lo num manager arrisca desassociar
                             o nó. Vale só para os alvos LOCAIS; o nome de um
                             alvo remoto vem do @apelido de --metrics-scrape.

    DESTINO DOS ALERTAS — o Alertmanager NÃO SOBE sem pelo menos um destes, e a
    recusa é deliberada: alerta que não notifica ninguém é o problema que o
    módulo existe para resolver. Sem nenhum, o script deixa o Alertmanager
    DESLIGADO (em vez de em restart loop) e avisa.
      --alert-slack-webhook URL    caminho mais curto
      --alert-slack-channel NOME   (default: #alertas)
      --alert-webhook-url URL      webhook genérico (n8n, Discord via proxy)
      --alert-email-to ENDEREÇO    exige --alert-email-from e --alert-smtp-host
      --alert-email-from ENDEREÇO
      --alert-smtp-host HOST:PORTA
      --alert-smtp-user USUÁRIO
      --alert-smtp-password SENHA
      --alert-external-url URL     URL pela qual VOCÊ alcança o Alertmanager
                             (default: http://localhost:9093). Vai no link das
                             notificações; destinos que validam a URL recusam
                             a notificação se ela apontar para o container.
      --prometheus-port N    (default: 9090)
      --grafana-port N       (default: 3000)
      --grafana-password SENHA  (se omitida, é gerada)

    Grafana e Prometheus ficam em 127.0.0.1 de propósito, ao contrário dos
    serviços de dados: o Prometheus não tem autenticação nenhuma. Acesse com
    ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 usuario@host

OPTIONS (PgBouncer — roda no host da APLICAÇÃO):
      --pgbouncer-db-host HOST  Postgres para onde o pooler aponta. Default:
                             o --bind-ip quando ele é uma interface de verdade,
                             senão o gateway da bridge do Docker. Num host que
                             NÃO roda o Postgres, é obrigatório (junto de
                             --postgres-password).
      --pgbouncer-db-port N  (default: o mesmo de --postgres-port)
      --pgbouncer-bind-ip IP Interface de publicação do pooler
                             (default: 127.0.0.1 — a aplicação é local)
      --pgbouncer-port N     (default: 6432)

OPTIONS (rede e firewall):
      --bind-ip IP           Interface de publicação (default: 0.0.0.0 — todas)
      --postgres-port N      (default: 5432)
      --redis-port N         (default: 6379)
      --meilisearch-port N   (default: 7700)
      --opensearch-port N    (default: 9200)
      --allow-from CIDR[,CIDR]  Restringe o firewall a estas origens
                             (default: sem restrição — qualquer origem)
      --no-firewall          Não configura o ufw

OPTIONS (atualização de uma instalação existente — herda o .setup-state):
      --update               Reaplica a configuração herdando o .setup-state.
                             Flag explícita sobrescreve; ausência HERDA.
      --add-service NOME     Acrescenta um serviço (opensearch, pgbouncer, ...)
                             sem tocar nos que já existem. Implica --update.

OPTIONS (webhook):
      --webhook-url URL      Notifica progresso e erros (POST JSON)

DEPOIS DE RODAR:
    /opt/brasildatahub/secrets/credentials.env   todas as credenciais (chmod 600)
    bdh status                                   estado dos serviços
    bdh --help                                   demais comandos

Documentação: https://github.com/BrasilDataHub/plataforma
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
        # O único modo que recria por decreto: "refaz do zero" inclui o
        # container, mesmo que a definição não tenha mudado.
        -f|--force) FORCE="true"; RECREATE="true"; shift ;;
        --ref) REF="$2"; shift 2 ;;
        --docker-version) DOCKER_VERSION="$2"; shift 2 ;;
        --docker-data-root) DOCKER_DATA_ROOT="$2"; shift 2 ;;
        --no-motd) INSTALL_MOTD="false"; shift ;;
        --services) SERVICES_INPUT="$2"; _explicita SERVICES_INPUT; shift 2 ;;
        --postgres-db) POSTGRES_DB="$2"; _explicita POSTGRES_DB; shift 2 ;;
        --pg-profile) PG_PROFILE="$2"; _explicita PG_PROFILE; shift 2 ;;
        --redis-profile) REDIS_PROFILE="$2"; _explicita REDIS_PROFILE; shift 2 ;;
        --meili-profile|--meilisearch-profile) MEILI_PROFILE="$2"; _explicita MEILI_PROFILE; shift 2 ;;
        --opensearch-profile) OPENSEARCH_PROFILE="$2"; _explicita OPENSEARCH_PROFILE; shift 2 ;;
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
        --opensearch-port) OPENSEARCH_PORT="$2"; _explicita OPENSEARCH_PORT; shift 2 ;;
        --pgbouncer-db-host) PGBOUNCER_DB_HOST="$2"; _explicita PGBOUNCER_DB_HOST; shift 2 ;;
        --pgbouncer-db-port) PGBOUNCER_DB_PORT="$2"; _explicita PGBOUNCER_DB_PORT; shift 2 ;;
        --pgbouncer-bind-ip) PGBOUNCER_BIND_IP="$2"; _explicita PGBOUNCER_BIND_IP; shift 2 ;;
        --pgbouncer-port) PGBOUNCER_PORT="$2"; _explicita PGBOUNCER_PORT; shift 2 ;;
        --allow-from) ALLOW_FROM="$2"; _explicita ALLOW_FROM; shift 2 ;;
        --enable-firewall) ENABLE_FIREWALL="true"; shift ;;
        --no-firewall) ENABLE_FIREWALL="false"; shift ;;
        # Reaplica config herdando o que não veio por flag (--update).
        --update) UPDATE_MODE="true"; FORCE="true"; shift ;;
        # Acrescenta serviço sem reescrever os existentes; merge em credentials.env.
        --add-service) ADD_SERVICE="$2"; UPDATE_MODE="true"; FORCE="true"; shift 2 ;;
        --metrics) METRICS_ENABLED="true"; shift ;;
        # Observabilidade sem recriar dados: --force, sem --force-recreate.
        --metrics-only) METRICS_ENABLED="true"; METRICS_ONLY="true"; FORCE="true"; shift ;;
        --no-monitoring) MONITORING_ENABLED="false"; shift ;;
        --metrics-profile) METRICS_PROFILE="$2"; METRICS_ENABLED="true"; _explicita METRICS_PROFILE; shift 2 ;;
        --metrics-containers) METRICS_CONTAINERS="true"; METRICS_ENABLED="true"; shift ;;
        # Host OBSERVADO de um desenho distribuído: publica os exporters numa
        # interface (a privada) e não sobe Prometheus nenhum.
        --metrics-publish) METRICS_PUBLISH_IP="$2"; METRICS_ENABLED="true"; MONITORING_ENABLED="false"
            _explicita METRICS_PUBLISH_IP; shift 2 ;;
        # Host do PROMETHEUS: de onde coletar o que está nas outras máquinas.
        --metrics-scrape) METRICS_SCRAPE="$2"; METRICS_ENABLED="true"; _explicita METRICS_SCRAPE; shift 2 ;;
        --host-label) HOST_LABEL="$2"; _explicita HOST_LABEL; shift 2 ;;
        # `_explicita` obrigatório: sem ele o estado herdado vence a flag nova.
        --metrics-bind-ip) MONITORING_BIND_IP="$2"; _explicita MONITORING_BIND_IP; shift 2 ;;
        --alert-slack-webhook) ALERT_SLACK_WEBHOOK="$2"; _explicita ALERT_SLACK_WEBHOOK; shift 2 ;;
        --alert-slack-channel) ALERT_SLACK_CHANNEL="$2"; _explicita ALERT_SLACK_CHANNEL; shift 2 ;;
        --alert-webhook-url) ALERT_WEBHOOK_URL="$2"; _explicita ALERT_WEBHOOK_URL; shift 2 ;;
        --alert-email-to) ALERT_EMAIL_TO="$2"; _explicita ALERT_EMAIL_TO; shift 2 ;;
        --alert-email-from) ALERT_EMAIL_FROM="$2"; _explicita ALERT_EMAIL_FROM; shift 2 ;;
        --alert-smtp-host) ALERT_SMTP_HOST="$2"; _explicita ALERT_SMTP_HOST; shift 2 ;;
        --alert-smtp-user) ALERT_SMTP_USER="$2"; _explicita ALERT_SMTP_USER; shift 2 ;;
        --alert-smtp-password) ALERT_SMTP_PASSWORD="$2"; _explicita ALERT_SMTP_PASSWORD; shift 2 ;;
        --alert-external-url) ALERT_EXTERNAL_URL="$2"; _explicita ALERT_EXTERNAL_URL; shift 2 ;;
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

# Interface real de publicação (PgBouncer tem bind próprio, default loopback).
service_bind_ip() {
    case "$1" in
        pgbouncer) printf '%s' "$PGBOUNCER_BIND_IP" ;;
        *) printf '%s' "$BIND_IP" ;;
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

# Memória visível ao Docker. No macOS o daemon é VM (costuma ser metade do host).
# Chamada antes de install_docker(): sem Docker, cai em /proc/meminfo.
available_mem_gb() {
    local bytes gb
    bytes="$(docker info -f '{{.MemTotal}}' 2>/dev/null || true)"
    case "$bytes" in ''|*[!0-9]*) bytes="" ;; esac
    if [[ -n "$bytes" ]]; then
        printf '%d' $(( bytes / 1024 / 1024 / 1024 ))
        return 0
    fi
    if [[ -r /proc/meminfo ]]; then
        # kB→GiB no awk (não `$2*1024`): mawk 32-bit satura em INT_MAX → 1 GiB.
        gb=$(awk '/^MemTotal:/ {printf "%d", $2 / 1048576; exit}' /proc/meminfo)
    else
        gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
    fi
    case "$gb" in ''|*[!0-9]*) gb=0 ;; esac
    printf '%d' "$gb"
}

# 'dedicada-16gb' -> 16. É o orçamento de RAM que o perfil pressupõe.
profile_budget_gb() {
    # Strip até o hífen (`${1#*-}`): não só o prefixo `dedicada-`.
    local n="${1#*-}"
    printf '%s' "${n%gb}"
}

# Detecta pela RAM que sobra após vizinhos (docs/perfis.md). Sem arg = máquina inteira.
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

# Redis/Meili: faixas pela RAM total (alinhadas a docs/perfis.md).
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

# Métricas não escalam com RAM (cardinalidade = nº de alvos). metricas-8gb é manual.
detect_metrics_profile() {
    if [[ "$METRICS_CONTAINERS" == "true" ]]; then
        printf 'metricas-2gb'      # o cAdvisor sozinho dobra o volume de séries
    else
        printf 'metricas-512mb'
    fi
}

# Perfis = arquivos .env no repositório. `compartilhada-14gb`: host dividido com busca.
PG_PROFILES="dedicada-8gb dedicada-16gb dedicada-32gb dedicada-64gb dedicada-128gb compartilhada-14gb"
# cache-768mb / fila-256mb: par cache×fila (redis/docker-compose.par.yml).
REDIS_PROFILES="cache-256mb cache-512mb cache-768mb cache-1gb cache-2gb cache-4gb fila-256mb"
MEILI_PROFILES="busca-512mb busca-1gb busca-4gb busca-16gb"
# `dev-4gb`: aceito por flag, nunca pelo `auto` (só desenvolvimento).
OPENSEARCH_PROFILES="compartilhada-8gb dedicada-16gb dev-4gb"

# OpenSearch: compartilhada se houver Postgres/Redis/Meili; senão dedicada (≥14 GiB).
# pgbouncer/monitoring não contam como vizinho. `dev-4gb` só por flag explícita.
# Arg de RAM opcional (testes); sem ele lê a máquina.
# shellcheck disable=SC2120  # o argumento é opcional
detect_opensearch_profile() {
    local s
    for s in "${SERVICES[@]+"${SERVICES[@]}"}"; do
        case "$s" in
            postgres|redis|meilisearch) printf 'compartilhada-8gb'; return 0 ;;
        esac
    done
    # dedicada-16gb só se RAM ≥ 14 GiB (limite 10 GiB).
    local mem="${1:-}"
    [[ -z "$mem" ]] && mem="$(available_mem_gb)"
    if (( mem >= 14 )); then
        printf 'dedicada-16gb'
    else
        printf 'compartilhada-8gb'
    fi
}
METRICS_PROFILES="metricas-512mb metricas-2gb metricas-8gb"

# Maior perfil cujo limite cabe na RAM — conselho acionável na mensagem de erro.
maior_perfil_que_cabe() {
    local mem="$1" p melhor="dedicada-8gb"
    for p in $PG_PROFILES; do
        case "$p" in compartilhada-*) continue ;; esac   # não é perfil de máquina dedicada
        (( $(profile_budget_gb "$p") * 87 / 100 <= mem )) && \
            (( $(profile_budget_gb "$p") > $(profile_budget_gb "$melhor") )) && melhor="$p"
    done
    printf '%s' "$melhor"
}

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
        # PgBouncer sem perfil: dimensionado por default_pool_size / max_client_conn.
    esac
}

# Quem tem overlay de exporter. OpenSearch expõe /_prometheus nativo; pgbouncer sem job.
# Ausência de overlay ≠ erro (não abortar create_layout).
SERVICES_COM_EXPORTER="postgres redis meilisearch"
tem_overlay_metrics() {
    case " $SERVICES_COM_EXPORTER " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Host do Postgres visto de outro projeto Compose (ex.: PgBouncer).
docker_bridge_gateway() {
    local ip=""
    ip="$(docker network inspect bridge -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
    fi
    printf '%s' "${ip:-172.17.0.1}"
}

# Orçamento do vizinho (GB), arredondado para cima. Fonte: profiles/*.env.
neighbor_budget_gb() {
    case "$1" in
        # Redis — REDIS_MEMORY_LIMIT: 512M / 1G / 2G / 3G
        cache-256mb)    printf '1' ;;
        cache-512mb)    printf '1' ;;
        cache-1gb)      printf '2' ;;
        cache-2gb)      printf '3' ;;
        # cache-4gb é instância DEDICADA a cache (allkeys-lru, sem AOF); o
        # limite de container do perfil é 5G.
        cache-4gb)      printf '5' ;;
        # Par cache/fila (redis/docker-compose.par.yml): entram no orçamento.
        cache-768mb)    printf '1' ;;
        fila-256mb)     printf '1' ;;
        # Meilisearch — MEILI_MEMORY_LIMIT (valor de PICO de indexação)
        busca-512mb)    printf '1' ;;
        busca-1gb)      printf '1' ;;
        busca-4gb)      printf '4' ;;
        busca-16gb)     printf '16' ;;
        # OpenSearch — OS_MEMORY_LIMIT: sem isto o `auto` do Postgres superdimensiona.
        compartilhada-8gb) printf '8' ;;
        # dedicada-*: raro na soma; linha evita orçamento 0 se fixado à mão.
        dedicada-16gb) printf '10' ;;
        # `dev-4gb` sempre divide o host — orçamento obrigatório.
        dev-4gb)       printf '4' ;;
        # Observabilidade — Prometheus + Grafana + node exporter + exporters.
        # O cAdvisor entra à parte, em metrics_budget_gb().
        metricas-512mb) printf '2' ;;
        metricas-2gb)   printf '4' ;;
        metricas-8gb)   printf '10' ;;
        *)              printf '0' ;;
    esac
}

# Orçamento de métricas via neighbor_budget_gb. Basta um destino de alerta.
tem_destino_de_alerta() {
    [[ -n "$ALERT_SLACK_WEBHOOK" || -n "$ALERT_WEBHOOK_URL" || -n "$ALERT_EMAIL_TO" ]]
}

# Destino de alerta (segredo) vive no .env do monitoring, não no .setup-state.
# Herdar no --update evita desligar o Alertmanager em silêncio.
herdar_destino_de_alerta() {
    local env_mon="$WORKDIR/services/monitoring/.env"
    [[ -f "$env_mon" ]] || return 0
    local linha chave valor
    while IFS= read -r linha; do
        chave="${linha%%=*}"; valor="${linha#*=}"
        case "$chave" in
            ALERTMANAGER_SLACK_WEBHOOK) foi_explicita ALERT_SLACK_WEBHOOK || ALERT_SLACK_WEBHOOK="$valor" ;;
            ALERTMANAGER_SLACK_CHANNEL) foi_explicita ALERT_SLACK_CHANNEL || ALERT_SLACK_CHANNEL="$valor" ;;
            ALERTMANAGER_WEBHOOK_URL)   foi_explicita ALERT_WEBHOOK_URL   || ALERT_WEBHOOK_URL="$valor" ;;
            ALERTMANAGER_EMAIL_TO)      foi_explicita ALERT_EMAIL_TO      || ALERT_EMAIL_TO="$valor" ;;
            ALERTMANAGER_EMAIL_FROM)    foi_explicita ALERT_EMAIL_FROM    || ALERT_EMAIL_FROM="$valor" ;;
            ALERTMANAGER_SMTP_HOST)     foi_explicita ALERT_SMTP_HOST     || ALERT_SMTP_HOST="$valor" ;;
            ALERTMANAGER_SMTP_USER)     foi_explicita ALERT_SMTP_USER     || ALERT_SMTP_USER="$valor" ;;
            ALERTMANAGER_SMTP_PASSWORD) foi_explicita ALERT_SMTP_PASSWORD || ALERT_SMTP_PASSWORD="$valor" ;;
            ALERTMANAGER_EXTERNAL_URL)  foi_explicita ALERT_EXTERNAL_URL  || ALERT_EXTERNAL_URL="$valor" ;;
        esac
    done < <(grep -E '^ALERTMANAGER_[A-Z_]+=' "$env_mon" 2>/dev/null || true)
}

metrics_budget_gb() {
    local base
    base="$(neighbor_budget_gb "$METRICS_PROFILE")"
    [[ "$base" == "0" ]] && base=2      # perfil desconhecido: assume o menor
    [[ "$METRICS_CONTAINERS" == "true" ]] && base=$((base + 1))
    printf '%d' "$base"
}

# Prometheus roda como nobody (65534): chown+600 para a chave do Meilisearch.
# No macOS (sem uid 65534 / sem root) o chown é dispensável.
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

    # Sem perfil (ex.: PgBouncer) não é erro — não pedir profiles/.env.
    [[ -z "$prof" ]] && return 0

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

    # load_state ANTES de montar SERVICES: --add-service e perfis herdados dependem disso.
    load_state

    # --update/--add-service: não-interativo (sem ask em SSH sem TTY).
    if [[ "$UPDATE_MODE" == "true" && "$AUTO" != "true" ]]; then
        AUTO="true"
    fi

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
            # --services monitoring: host só de observabilidade (fora do array SERVICES).
            monitoring)
                METRICS_ENABLED="true"
                MONITORING_ENABLED="true"
                SOMENTE_MONITORING="true"
                ;;
            *) die "serviço desconhecido: '$s' (use postgres, redis, meilisearch, opensearch, pgbouncer ou monitoring)" ;;
        esac
    done
    # `monitoring` sai do array SERVICES em validate_and_prompt: é provisionado
    # por setup_metrics(), não pelo laço de serviços de dados.
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
    # Vizinhos primeiro; Postgres fica com a memória que sobra (docs/perfis.md).
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

    # Incluir OpenSearch no orçamento dos vizinhos. Sem ask: um perfil (page cache Lucene).
    if service_selected opensearch; then
        [[ "$OPENSEARCH_PROFILE" == "auto" ]] && OPENSEARCH_PROFILE="$(detect_opensearch_profile)"
        profile_valid "$OPENSEARCH_PROFILE" "$OPENSEARCH_PROFILES" \
            || die "perfil de OpenSearch inválido: $OPENSEARCH_PROFILE (use: auto $OPENSEARCH_PROFILES)"
        neighbors_gb=$(( neighbors_gb + $(neighbor_budget_gb "$OPENSEARCH_PROFILE") ))
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

        # Recusar perfil cujo LIMITE de container > RAM disponível.
        # Comparar o limite (ex.: 28G), não o número do nome (32).
        local budget limite_gb
        budget="$(profile_budget_gb "$PG_PROFILE")"
        limite_gb=$(( budget * 87 / 100 ))
        if (( limite_gb > mem_gb )) && [[ "$ALLOW_OVERSIZED" != "true" ]]; then
            die "perfil $PG_PROFILE limita o container a ~${limite_gb} GB, mas o Docker tem ${mem_gb} GB.
       O Postgres não subiria (shared_buffers maior que a memória disponível).
       Use --pg-profile $(maior_perfil_que_cabe "$mem_gb"), aumente a máquina (ou a
       memória da VM do Docker, no macOS), ou passe --allow-oversized-profile
       se souber que a memória vai crescer antes do primeiro uso."
        fi
        if (( limite_gb > mem_gb )); then
            warn "perfil $PG_PROFILE acima da memória disponível (${mem_gb} GB) — seguindo por --allow-oversized-profile"
        fi

        # Aviso se a máquina comporta bem mais que o perfil (page cache ok,
        # mas effective_cache_size fica baixo). Limiar 25% acima do orçamento;
        # compara contra livre (RAM − vizinhos). Ver docs/perfis.md.
        local livre_final=$(( mem_gb - neighbors_gb ))
        if (( livre_final >= budget + budget / 4 )); then
            local cabe; cabe="$(maior_perfil_que_cabe "$livre_final")"
            warn "a máquina comporta mais do que $PG_PROFILE pressupõe:"
            warn "  ${livre_final} GB livres contra um orçamento de ${budget} GB (limite do container: ${limite_gb} GB)."
            if [[ "$cabe" != "$PG_PROFILE" ]]; then
                warn "  o perfil $cabe caberia — considere --pg-profile $cabe."
            else
                warn "  nenhum perfil do catálogo encaixa melhor; o ajuste é por retrofit."
            fi
            warn "  a sobra vira page cache e não é perdida, mas effective_cache_size"
            warn "  fica subdimensionado. Fórmula: postgres/docs/perfis.md, seção Retrofit."
        fi

        # A soma total ainda pode não caber: dedicada-8gb é o piso do catálogo.
        # Conta = limite do container, não o número do nome do perfil.
        if (( limite_gb + neighbors_gb > mem_gb )); then
            warn "orçamento apertado: $PG_PROFILE (limite do container ~${limite_gb} GB) + vizinhos (~${neighbors_gb} GB)"
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

    # Pooler sem Postgres local: exige flags de host/senha do banco remoto.
    if service_selected pgbouncer && ! service_selected postgres; then
        # Reexecução: senha já no .env/credentials — não exigir de novo.
        local tem_senha="false"
        [[ -n "$POSTGRES_PASSWORD" ]] && tem_senha="true"
        grep -q '^PGB_PASSWORD=' "$WORKDIR/secrets/credentials.env" 2>/dev/null && tem_senha="true"
        grep -q '^PGB_PASSWORD=' "$WORKDIR/services/pgbouncer/.env" 2>/dev/null && tem_senha="true"
        [[ -n "$PGBOUNCER_DB_HOST" ]] \
            || die "pgbouncer sem postgres neste host exige --pgbouncer-db-host <ip do banco>"
        [[ "$tem_senha" == "true" ]] \
            || die "pgbouncer sem postgres neste host exige --postgres-password (a senha do banco remoto)"
    fi

    if [[ "$METRICS_ENABLED" == "true" ]]; then
        # Perfil de métricas já resolvido no dimensionamento acima.

        # Herdar destino de alerta anterior (impede --update de desligar).
        herdar_destino_de_alerta

        # --metrics-publish nunca 0.0.0.0 (exporter entrega internos do banco).
        case "$METRICS_PUBLISH_IP" in
            0.0.0.0|"::"|"*") die "--metrics-publish exige uma interface específica (use a privada), nunca 0.0.0.0" ;;
        esac

        # Validar par e-mail/SMTP aqui (evita restart loop no start).
        if [[ -n "$ALERT_EMAIL_TO" ]]; then
            [[ -n "$ALERT_SMTP_HOST" ]] || die "--alert-email-to exige --alert-smtp-host (host:porta)"
            [[ -n "$ALERT_EMAIL_FROM" ]] || die "--alert-email-to exige --alert-email-from"
        fi
        if [[ "$MONITORING_ENABLED" == "true" ]] && ! tem_destino_de_alerta; then
            warn "sem destino de alerta: o Alertmanager ficará DESLIGADO."
            warn "  As regras continuam sendo avaliadas e os alertas aparecem em"
            warn "  'bdh metrics', mas NINGUÉM é notificado. Para ligar depois:"
            warn "    bash setup.sh --update --alert-slack-webhook https://hooks.slack.com/..."
        fi

        # macOS: node/cAdvisor medem a VM, não o host.
        if [[ "$OS_FAMILY" == "macos" ]]; then
            info "macOS: node exporter e cAdvisor ficam desligados (medem a VM, não o host)"
        fi
    fi

    info "serviços ....... ${SERVICES[*]}"
    if service_selected postgres; then info "perfil PG ...... $PG_PROFILE"; fi
    if service_selected redis; then info "perfil Redis ... $REDIS_PROFILE"; fi
    if service_selected meilisearch; then info "perfil Meili ... $MEILI_PROFILE"; fi
    if service_selected opensearch; then info "perfil OpenSearch $OPENSEARCH_PROFILE"; fi
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
# Lê `.setup-state` e preenche o que NÃO veio por flag.
# Regra: flag explícita sobrescreve; ausência herda do estado.
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
            OPENSEARCH_PORT)  foi_explicita OPENSEARCH_PORT || OPENSEARCH_PORT="$valor" ;;
            PGBOUNCER_DB_HOST) foi_explicita PGBOUNCER_DB_HOST || PGBOUNCER_DB_HOST="$valor" ;;
            PGBOUNCER_DB_PORT) foi_explicita PGBOUNCER_DB_PORT || PGBOUNCER_DB_PORT="$valor" ;;
            PGBOUNCER_BIND_IP) foi_explicita PGBOUNCER_BIND_IP || PGBOUNCER_BIND_IP="$valor" ;;
            PGBOUNCER_PORT)   foi_explicita PGBOUNCER_PORT  || PGBOUNCER_PORT="$valor" ;;
            PG_PROFILE)       foi_explicita PG_PROFILE      || PG_PROFILE="$valor" ;;
            REDIS_PROFILE)    foi_explicita REDIS_PROFILE   || REDIS_PROFILE="$valor" ;;
            MEILI_PROFILE)    foi_explicita MEILI_PROFILE   || MEILI_PROFILE="$valor" ;;
            METRICS_PROFILE)  foi_explicita METRICS_PROFILE || METRICS_PROFILE="$valor" ;;
            OPENSEARCH_PROFILE) foi_explicita OPENSEARCH_PROFILE || OPENSEARCH_PROFILE="$valor" ;;
            # `METRICS_ENABLED` só é herdado quando LIGADO: desligar observabilidade
            # é uma decisão que precisa ser tomada, nunca herdada de um estado antigo.
            METRICS_ENABLED)  [[ "$valor" == "true" ]] && METRICS_ENABLED="true" ;;
            MONITORING_ENABLED) [[ "$METRICS_ENABLED" == "true" ]] && MONITORING_ENABLED="$valor" ;;
            MONITORING_BIND_IP) foi_explicita MONITORING_BIND_IP || MONITORING_BIND_IP="$valor" ;;
            METRICS_PUBLISH_IP) foi_explicita METRICS_PUBLISH_IP || { METRICS_PUBLISH_IP="$valor"; MONITORING_ENABLED="false"; } ;;
            METRICS_SCRAPE)     foi_explicita METRICS_SCRAPE     || METRICS_SCRAPE="$valor" ;;
        esac
    done < "$arquivo"

    # --add-service: une ao conjunto herdado (não substitui).
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

    # load_state já rodou em validate_and_prompt(); não chamar de novo aqui.

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
        # macOS: não atualiza o SO; só confere curl/openssl.
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
# OpenSearch exige vm.max_map_count ≥ 262144 (default Debian: 65530).
# Persistir em /etc/sysctl.d/ — sem isso o valor volta no reboot.
configure_sysctl() {
    [[ "$OS_FAMILY" == "linux" ]] || return 0

    # Só quando há serviço que precisa. Escrever sysctl num host que não roda
    # nenhum dos dois é mexer em configuração de kernel sem motivo.
    service_selected opensearch || service_selected redis || return 0

    section "Parâmetros de kernel"

    configure_overcommit
    configure_thp

    service_selected opensearch || return 0

    local arquivo=/etc/sysctl.d/99-brasildatahub.conf
    local atual
    atual="$(sysctl -n vm.max_map_count 2>/dev/null || printf '0')"

    # Nunca rebaixar: valor maior no host pode ser de outro serviço.
    local alvo="$VM_MAX_MAP_COUNT"
    [[ "$atual" -gt "$alvo" ]] && alvo="$atual"

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$atual" -ge "$VM_MAX_MAP_COUNT" ]]; then
            _log "    ${C_DIM}[dry-run] vm.max_map_count já em ${atual} (≥ ${VM_MAX_MAP_COUNT}); persistiria ${alvo} em ${arquivo}${C_RESET}"
        else
            _log "    ${C_DIM}[dry-run] vm.max_map_count: ${atual} → ${alvo} e ${arquivo}${C_RESET}"
        fi
        return 0
    fi

    if [[ "$atual" -lt "$VM_MAX_MAP_COUNT" ]]; then
        run sysctl -w "vm.max_map_count=${alvo}"
        ok "vm.max_map_count: ${atual} → ${alvo}"
    else
        ok "vm.max_map_count já em ${atual} (mínimo exigido: ${VM_MAX_MAP_COUNT})"
    fi

    # Reescrever o arquivo inteiro, e não acrescentar: uma execução repetida
    # deixaria a mesma linha duas vezes, e a última venceria em silêncio.
    {
        printf '# GERADO por setup.sh — não editar à mão.\n'
        printf '# O OpenSearch usa mmap para os segmentos do Lucene; o default do\n'
        printf '# Debian (65530) o faz morrer no bootstrap check. O mínimo que\n'
        printf '# exigimos é %s; um valor maior já presente no host é PRESERVADO.\n' "$VM_MAX_MAP_COUNT"
        printf 'vm.max_map_count=%s\n' "$alvo"
    } > "$arquivo"
    ok "persistido em ${arquivo}: ${alvo}"
}

# vm.overcommit_memory=1 (Redis): BGSAVE/AOF precisam de fork(); overcommit 0
# pode recusar o fork pelo tamanho virtual. Arquivo próprio (não 99-brasildatahub).
configure_overcommit() {
    service_selected redis || return 0

    local arquivo=/etc/sysctl.d/60-redis.conf
    local atual
    atual="$(sysctl -n vm.overcommit_memory 2>/dev/null || printf '0')"

    if [[ "$DRY_RUN" == "true" ]]; then
        _log "    ${C_DIM}[dry-run] vm.overcommit_memory: ${atual} → 1 e ${arquivo}${C_RESET}"
        return 0
    fi

    if [[ "$atual" != "1" ]]; then
        run sysctl -w vm.overcommit_memory=1
        ok "vm.overcommit_memory: ${atual} → 1"
    else
        ok "vm.overcommit_memory já em 1"
    fi

    {
        printf '# GERADO por setup.sh — não editar à mão.\n'
        printf '# Exigido pelo Redis: sem overcommit, o fork() do BGSAVE pode ser\n'
        printf '# recusado mesmo havendo memória livre. Ver redis/README.md.\n'
        printf 'vm.overcommit_memory = 1\n'
    } > "$arquivo"
    ok "persistido em ${arquivo}"
}

# THP off: não é sysctl — unit oneshot Before=docker.service.
#
# Vale para os TRÊS serviços de dados, e não só para o Redis (que era o único
# no gate até 2026-08):
#   - Redis: com THP always, o fork do snapshot copia páginas de 2 MB.
#   - PostgreSQL: recomendação da própria documentação. THP always faz a
#     compactação síncrona entrar no caminho de uma alocação qualquer, e o
#     sintoma é latência errática sem causa visível no banco. Não confundir com
#     huge pages EXPLÍCITAS (`huge_pages=try`), que são desejáveis e continuam
#     funcionando com THP desligado.
#   - JVM (OpenSearch): mesma compactação síncrona, agora dentro de uma pausa
#     de GC.
# Medido em 2026-08-05: bdh-data, bdh-search e bdh-monitor estavam com
# `[always]` porque o gate só olhava o Redis.
configure_thp() {
    service_selected redis || service_selected postgres \
        || service_selected opensearch || service_selected meilisearch || return 0

    local unit=/etc/systemd/system/disable-thp.service
    local atual
    atual="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || printf 'indisponível')"

    # Kernel sem THP compilado (ou container sem /sys): nada a fazer, e não é erro.
    if [[ "$atual" == "indisponível" ]]; then
        ok "Transparent Huge Pages não exposto pelo kernel — nada a desligar"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        _log "    ${C_DIM}[dry-run] THP: ${atual} → never, via ${unit}${C_RESET}"
        return 0
    fi

    cat > "$unit" <<'EOF'
[Unit]
Description=Desabilita Transparent Huge Pages (exigido pelo Redis)
Documentation=https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/latency/
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=basic.target
EOF
    run systemctl daemon-reload
    run systemctl enable --now disable-thp.service
    ok "Transparent Huge Pages: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
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

    # Overlays de métricas no dir do serviço; -f extra em start_services.
    if [[ "$METRICS_ENABLED" == "true" ]]; then
        for s in "${SERVICES[@]}"; do
            # Serviço sem exporter não tem overlay para baixar — e pedi-lo
            # matava o provisionamento inteiro (ver SERVICES_COM_EXPORTER).
            if ! tem_overlay_metrics "$s"; then
                info "$s: sem exporter (métricas nativas ou fora do escopo do Prometheus)"
                continue
            fi
            dir="$(service_dir "$s")"
            if [[ "$DRY_RUN" != "true" ]]; then
                curl -fsSL "${RAW_BASE}/${s}/docker-compose.metrics.yml" \
                    -o "$dir/docker-compose.metrics.yml" \
                    || die "falha ao baixar ${RAW_BASE}/${s}/docker-compose.metrics.yml"
            fi
            ok "$s: overlay de métricas"
        done

        # 03-role-metrics.sh no host: cluster já init não roda initdb de novo.
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

        # Coleta remota: overlay publica exporters; proteção = firewall.
        if [[ -n "$METRICS_PUBLISH_IP" && "$DRY_RUN" != "true" ]]; then
            for s in "${SERVICES[@]}"; do
                tem_overlay_metrics "$s" || continue
                dir="$(service_dir "$s")"
                curl -fsSL "${RAW_BASE}/${s}/docker-compose.metrics-remote.yml" \
                    -o "$dir/docker-compose.metrics-remote.yml" \
                    || die "falha ao baixar ${RAW_BASE}/${s}/docker-compose.metrics-remote.yml"
                ok "$s: exporter publicado em ${METRICS_PUBLISH_IP}"
            done
            # node_exporter no projeto monitoring (só ele sobe no host observado).
            dir="$(service_dir monitoring)"
            run mkdir -p "$dir/targets" "$dir/secrets"
            curl -fsSL "${RAW_BASE}/monitoring/docker-compose.yml" -o "$dir/docker-compose.yml" \
                || die "falha ao baixar ${RAW_BASE}/monitoring/docker-compose.yml"
            curl -fsSL "${RAW_BASE}/monitoring/docker-compose.remote.yml" -o "$dir/docker-compose.remote.yml" \
                || die "falha ao baixar ${RAW_BASE}/monitoring/docker-compose.remote.yml"
            touch "$dir/secrets/meili-metrics.key"
            protect_metrics_key "$dir/secrets/meili-metrics.key"
            ok "monitoring: node exporter para coleta remota"
        fi

        # monitoring fora de SERVICES: dois volumes; laço bind quebraria o YAML.
        if [[ "$MONITORING_ENABLED" == "true" ]]; then
            dir="$(service_dir monitoring)"
            run mkdir -p "$dir/targets" "$dir/secrets"
            if [[ "$DRY_RUN" != "true" ]]; then
                curl -fsSL "${RAW_BASE}/monitoring/docker-compose.yml" \
                    -o "$dir/docker-compose.yml" \
                    || die "falha ao baixar ${RAW_BASE}/monitoring/docker-compose.yml"
                grep -q 'ghcr.io/brasildatahub' "$dir/docker-compose.yml" \
                    || die "conteúdo inesperado em $dir/docker-compose.yml (ref '$REF' existe?)"
                # credentials_file do Meili deve existir (senão Prometheus recusa tudo).
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
# Gerado por setup.sh — modo --volumes bind.
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

    # Pooler sem banco local: senha remota vem por flag e deve sobreviver ao --update.
    if service_selected pgbouncer && ! service_selected postgres && [[ -z "$POSTGRES_PASSWORD" ]]; then
        POSTGRES_PASSWORD="${PGB_PASSWORD:-}"
        if [[ -z "$POSTGRES_PASSWORD" ]]; then
            POSTGRES_PASSWORD="$(grep -h '^PGB_PASSWORD=' "$(service_dir pgbouncer)/.env" 2>/dev/null | cut -d= -f2-)"
        fi
    fi

    [[ -z "$POSTGRES_PASSWORD" ]] && POSTGRES_PASSWORD="$(gen_secret)"
    [[ -z "$DADOS_READ_PASSWORD" ]] && DADOS_READ_PASSWORD="$(gen_secret)"
    [[ -z "$REDIS_PASSWORD" ]] && REDIS_PASSWORD="$(gen_secret)"
    [[ -z "$MEILI_MASTER_KEY" ]] && MEILI_MASTER_KEY="$(gen_secret)"
    # Credenciais próprias da monitoração, de menor privilégio: a senha do
    # metrics_read não é a do postgres, e a chave do Meili não é a master key.
    [[ -z "$PG_METRICS_PASSWORD" ]] && PG_METRICS_PASSWORD="$(gen_secret)"
    [[ -z "$GRAFANA_ADMIN_PASSWORD" ]] && GRAFANA_ADMIN_PASSWORD="$(gen_secret)"

    # --- teto de CPU do OpenSearch --------------------------------------------
    # Docker recusa cpus > CPUs da máquina. Rebaixa o teto do perfil se necessário.
    local os_cpu_ajustado=""
    if service_selected opensearch && [[ "$DRY_RUN" != "true" ]]; then
        local vcpus teto_perfil
        vcpus="$(docker info -f '{{.NCPU}}' 2>/dev/null || true)"
        case "$vcpus" in ''|*[!0-9]*) vcpus="$(nproc 2>/dev/null || printf '0')" ;; esac
        teto_perfil="$(fetch_profile opensearch | awk -F= '/^OS_CPU_LIMIT=/{gsub(/[^0-9.]/,"",$2); print $2; exit}')"
        if [[ -n "$teto_perfil" ]] && (( vcpus > 0 )) \
           && awk "BEGIN{exit !($teto_perfil > $vcpus)}"; then
            os_cpu_ajustado="$vcpus"
            warn "OS_CPU_LIMIT do perfil é ${teto_perfil}, e a máquina tem ${vcpus} vCPU."
            warn "  Ajustado para ${vcpus} — o Docker recusaria criar o container."
        fi
    fi

    # Para onde o pooler aponta. Resolvido AQUI, e não no parser, porque o
    # gateway da bridge só existe depois de install_docker().
    if service_selected pgbouncer && [[ -z "$PGBOUNCER_DB_HOST" && "$DRY_RUN" != "true" ]]; then
        case "$BIND_IP" in
            0.0.0.0|""|127.0.0.1|localhost) PGBOUNCER_DB_HOST="$(docker_bridge_gateway)" ;;
            *) PGBOUNCER_DB_HOST="$BIND_IP" ;;
        esac
        info "pgbouncer aponta para ${PGBOUNCER_DB_HOST}:${PGBOUNCER_DB_PORT:-$POSTGRES_PORT}"
    fi

    # Perfil de métricas baixado uma vez; limites dos exporters vão ao .env de cada serviço.
    local profile_metrics=""
    if [[ "$METRICS_ENABLED" == "true" && "$DRY_RUN" != "true" ]]; then
        profile_metrics="$WORKDIR/services/.metrics-profile.env"
        fetch_profile monitoring > "$profile_metrics"
    fi

    for s in "${SERVICES[@]}"; do
        dir="$(service_dir "$s")"
        env_file="$dir/.env"
        [[ "$DRY_RUN" == "true" ]] && { _log "    ${C_DIM}[dry-run] escreveria $env_file a partir de $s/profiles/$(service_profile "$s").env${C_RESET}"; continue; }

        # Preservar PGBACKREST_* / BDH_BACKUP_* no .env (operador as escreve;
        # regenerar o perfil apagaria e o up falharia com ${VAR:?}).
        local -a preservadas=()
        if [[ -f "$env_file" ]]; then
            local linha_pres
            while IFS= read -r linha_pres; do
                preservadas+=("$linha_pres")
            done < <(grep -E '^(PGBACKREST_[A-Z_]+|BDH_BACKUP_[A-Z_]+)=' "$env_file" 2>/dev/null || true)
        fi

        # .env = perfil + senhas/binds locais (perfil versionado não leva segredo).
        {
            fetch_profile "$s"
            printf '\n# --- deploy (gerado por setup.sh em %s) ---\n' "$(now_iso)"
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
            # BIND_IP no .env do OpenSearch (sem auth; default 0.0.0.0 seria exposição).
            opensearch)
                printf 'BIND_IP=%s\nOPENSEARCH_PORT=%s\n' "$BIND_IP" "$OPENSEARCH_PORT"
                # Depois do perfil: última env_file vence (rebaixa cpus sem editar perfil).
                if [[ -n "$os_cpu_ajustado" ]]; then
                    printf 'OS_CPU_LIMIT=%s\n' "$os_cpu_ajustado"
                fi
                ;;
            # PGB_* obrigatórias no .env (`${VAR:?}` no compose).
            pgbouncer)
                printf 'PGB_DB_HOST=%s\n' "$PGBOUNCER_DB_HOST"
                printf 'PGB_DB_PORT=%s\n' "${PGBOUNCER_DB_PORT:-$POSTGRES_PORT}"
                printf 'PGB_DB_NAME=%s\n' "$POSTGRES_DB"
                printf 'PGB_USER=%s\n' "$PGBOUNCER_DB_USER"
                printf 'PGB_PASSWORD=%s\n' "$POSTGRES_PASSWORD"
                printf 'PGBOUNCER_BIND_IP=%s\nPGBOUNCER_PORT=%s\n' "$PGBOUNCER_BIND_IP" "$PGBOUNCER_PORT"
                ;;
            esac

            if (( ${#preservadas[@]} )); then
                printf '\n# --- backup: escritas pelo operador, preservadas na reexecução ---\n'
                printf '%s\n' "${preservadas[@]}"
            fi

        } > "$env_file"
        chmod 600 "$env_file"
        if [[ -n "$(service_profile "$s")" ]]; then
            ok "$s: .env gerado do perfil $(service_profile "$s")"
        else
            # PgBouncer não tem perfil de máquina — é dimensionado pela
            # aplicação. A linha antiga terminava em "do perfil " e parecia bug.
            ok "$s: .env gerado (sem perfil de máquina)"
        fi

        # Senha do exporter em arquivo separado: mudar .env recria o Postgres.
        if [[ "$METRICS_ENABLED" == "true" && "$s" == "postgres" ]]; then
            {
                printf '# Credencial do postgres_exporter — gerado por setup.sh em %s.\n' "$(now_iso)"
                printf '# Separado do .env de propósito: acrescentar variáveis ao .env do\n'
                printf '# serviço faria o Compose recriar o container do banco.\n'
                printf 'DATA_SOURCE_PASS=%s\n' "$PG_METRICS_PASSWORD"
            } > "$dir/.env.metrics"
            chmod 600 "$dir/.env.metrics"
            ok "postgres: credencial do exporter em .env.metrics"
        fi
    done

    # METRICS_BIND_IP em arquivo próprio (não no .env do serviço — evita recreate).
    if [[ -n "$METRICS_PUBLISH_IP" && "$DRY_RUN" != "true" ]]; then
        {
            printf '# Gerado por setup.sh — interface de publicação dos exporters.\n'
            printf '# Lido como AMBIENTE (nunca como env_file de serviço).\n'
            printf 'METRICS_BIND_IP=%s\n' "$METRICS_PUBLISH_IP"
        } > "$WORKDIR/.metrics-remote.env"
        chmod 600 "$WORKDIR/.metrics-remote.env"
        ok "coleta remota: exporters em ${METRICS_PUBLISH_IP}"

        # .env do monitoring necessário mesmo só com node-exporter (Compose interpola tudo).
        dir="$(service_dir monitoring)"
        {
            cat "$profile_metrics"
            printf '\n# --- deploy remoto (gerado por setup.sh em %s) ---\n' "$(now_iso)"
            printf '# Este host é OBSERVADO: só o node exporter sobe daqui. Prometheus,\n'
            printf '# Grafana e Alertmanager vivem no host de monitoração.\n'
            printf 'COMPOSE_PROFILES=node\n'
            printf 'METRICS_BIND_IP=%s\n' "$METRICS_PUBLISH_IP"
            printf 'MON_HOSTNAME=%s\n' "$(host_label)"
            printf 'METRICS_NETWORK=%s\n' "$METRICS_NETWORK"
            # Só para satisfazer a interpolação — o Grafana não sobe aqui.
            printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD"
        } > "$dir/.env"
        chmod 600 "$dir/.env"
    fi

    if [[ "$METRICS_ENABLED" == "true" && "$MONITORING_ENABLED" == "true" && "$DRY_RUN" != "true" ]]; then
        # COMPOSE_PROFILES = coletores Compose, não dimensionamento.
        # node/cadvisor só em Linux (macOS mediria a VM).
        local compose_profiles=""
        if [[ "$OS_FAMILY" == "linux" ]]; then
            compose_profiles="node"
            [[ "$METRICS_CONTAINERS" == "true" ]] && compose_profiles="node,containers"
        fi

        dir="$(service_dir monitoring)"
        {
            cat "$profile_metrics"
            printf '\n# --- deploy (gerado por setup.sh em %s) ---\n' "$(now_iso)"
            printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD"
            printf 'MON_HOSTNAME=%s\n' "$(host_label)"
            printf 'MONITORING_BIND_IP=%s\n' "$MONITORING_BIND_IP"
            printf 'PROMETHEUS_PORT=%s\nGRAFANA_PORT=%s\n' "$PROMETHEUS_PORT" "$GRAFANA_PORT"
            printf 'METRICS_NETWORK=%s\n' "$METRICS_NETWORK"
            printf 'GRAFANA_ROOT_URL=http://localhost:%s\n' "$GRAFANA_PORT"
            printf 'COMPOSE_PROFILES=%s\n' "$compose_profiles"
            # Só vars informadas: vazio ≠ "não configurada" para generate-config.sh.
            [[ -n "$ALERT_SLACK_WEBHOOK" ]] && printf 'ALERTMANAGER_SLACK_WEBHOOK=%s\n' "$ALERT_SLACK_WEBHOOK"
            [[ -n "$ALERT_SLACK_CHANNEL" ]] && printf 'ALERTMANAGER_SLACK_CHANNEL=%s\n' "$ALERT_SLACK_CHANNEL"
            [[ -n "$ALERT_WEBHOOK_URL" ]]   && printf 'ALERTMANAGER_WEBHOOK_URL=%s\n' "$ALERT_WEBHOOK_URL"
            [[ -n "$ALERT_EMAIL_TO" ]]      && printf 'ALERTMANAGER_EMAIL_TO=%s\n' "$ALERT_EMAIL_TO"
            [[ -n "$ALERT_EMAIL_FROM" ]]    && printf 'ALERTMANAGER_EMAIL_FROM=%s\n' "$ALERT_EMAIL_FROM"
            [[ -n "$ALERT_SMTP_HOST" ]]     && printf 'ALERTMANAGER_SMTP_HOST=%s\n' "$ALERT_SMTP_HOST"
            [[ -n "$ALERT_SMTP_USER" ]]     && printf 'ALERTMANAGER_SMTP_USER=%s\n' "$ALERT_SMTP_USER"
            [[ -n "$ALERT_SMTP_PASSWORD" ]] && printf 'ALERTMANAGER_SMTP_PASSWORD=%s\n' "$ALERT_SMTP_PASSWORD"
            printf 'ALERTMANAGER_EXTERNAL_URL=%s\n' "$ALERT_EXTERNAL_URL"
            # `true` fecha o bloco: o último `[[ ]]` falso derrubaria o `set -e`.
            true
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
            printf '# Gerado por setup.sh em %s. NÃO versione este arquivo.\n\n' "$(now_iso)"
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
            # Num host de aplicação esta é a ÚNICA credencial que existe, e sem
            # ela no arquivo o `--update` não teria de onde herdá-la.
            if service_selected pgbouncer; then
                printf '\n# --- pooler (aponta para o banco em %s) ---\n' "$PGBOUNCER_DB_HOST"
                printf 'PGB_DB_HOST=%s\nPGB_USER=%s\nPGB_PASSWORD=%s\nPGBOUNCER_PORT=%s\n' \
                    "$PGBOUNCER_DB_HOST" "$PGBOUNCER_DB_USER" "$POSTGRES_PASSWORD" "$PGBOUNCER_PORT"
            fi
            if [[ "$METRICS_ENABLED" == "true" ]]; then
                printf '\n# --- observabilidade ---\n'
                # Credenciais de menor privilégio (metrics_read / chave /metrics).
                printf 'PG_METRICS_PASSWORD=%s\n' "$PG_METRICS_PASSWORD"
                if [[ "$MONITORING_ENABLED" == "true" ]]; then
                    printf 'GRAFANA_ADMIN_PASSWORD=%s\nGRAFANA_PORT=%s\nPROMETHEUS_PORT=%s\n' \
                        "$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_PORT" "$PROMETHEUS_PORT"
                fi
            fi
        } > "$WORKDIR/secrets/credentials.env.novo"

        # Merge de credentials.env (não truncar senhas de serviços anteriores).
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
            # monitoring fora de SERVICES, mas precisa gravar no .setup-state.
            local servicos_estado
            servicos_estado="$(IFS=,; printf '%s' "${SERVICES[*]}")"
            if [[ "$SOMENTE_MONITORING" == "true" ]]; then
                servicos_estado="${servicos_estado:+${servicos_estado},}monitoring"
            fi
            printf 'SERVICES=%s\n' "$servicos_estado"
            printf 'VOLUMES_MODE=%s\n' "$VOLUMES_MODE"
            # POSTGRES_DB, BIND_IP, ALLOW_FROM etc. no estado — sem eles a reexecução
            # recria banco / reexpõe / esvazia firewall.
            printf 'WORKDIR=%s\n' "$WORKDIR"
            printf 'POSTGRES_DB=%s\n' "$POSTGRES_DB"
            printf 'BIND_IP=%s\n' "$BIND_IP"
            printf 'ALLOW_FROM=%s\n' "$ALLOW_FROM"
            printf 'POSTGRES_PORT=%s\n' "$POSTGRES_PORT"
            printf 'REDIS_PORT=%s\n' "$REDIS_PORT"
            printf 'MEILI_PORT=%s\n' "$MEILI_PORT"
            printf 'OPENSEARCH_PORT=%s\n' "$OPENSEARCH_PORT"
            # Host/porta/bind do PgBouncer no estado — sem eles --update reescreve defaults.
            if service_selected pgbouncer; then
                printf 'PGBOUNCER_DB_HOST=%s\n' "$PGBOUNCER_DB_HOST"
                printf 'PGBOUNCER_BIND_IP=%s\n' "$PGBOUNCER_BIND_IP"
                printf 'PGBOUNCER_PORT=%s\n' "$PGBOUNCER_PORT"
                printf 'PGBOUNCER_DB_PORT=%s\n' "${PGBOUNCER_DB_PORT:-$POSTGRES_PORT}"
            fi
            # Cada chave num `if` próprio: sob set -e, `false && echo` abortaria.
            if service_selected postgres; then printf 'PG_PROFILE=%s\n' "$PG_PROFILE"; fi
            if service_selected redis; then printf 'REDIS_PROFILE=%s\n' "$REDIS_PROFILE"; fi
            if service_selected meilisearch; then printf 'MEILI_PROFILE=%s\n' "$MEILI_PROFILE"; fi
            if service_selected opensearch; then printf 'OPENSEARCH_PROFILE=%s\n' "$OPENSEARCH_PROFILE"; fi
            printf 'METRICS_ENABLED=%s\n' "$METRICS_ENABLED"
            if [[ "$METRICS_ENABLED" == "true" ]]; then
                printf 'METRICS_PROFILE=%s\n' "$METRICS_PROFILE"
                printf 'MONITORING_ENABLED=%s\n' "$MONITORING_ENABLED"
                # MONITORING_BIND_IP no estado: sem herança, --update volta a loopback.
                printf 'MONITORING_BIND_IP=%s\n' "$MONITORING_BIND_IP"
                # METRICS_PUBLISH_IP / METRICS_SCRAPE no estado (senão --update apaga).
                [[ -n "$METRICS_PUBLISH_IP" ]] && printf 'METRICS_PUBLISH_IP=%s\n' "$METRICS_PUBLISH_IP"
                [[ -n "$METRICS_SCRAPE" ]] && printf 'METRICS_SCRAPE=%s\n' "$METRICS_SCRAPE"
                [[ -n "$HOST_LABEL" ]] && printf 'HOST_LABEL=%s\n' "$HOST_LABEL"
                true
            fi
        } > "$WORKDIR/.setup-state"
    fi
}

start_services() {
    section "Subindo os serviços"
    local s dir compose_args
    # METRICS_BIND_IP: interpolação do Compose (overlay remoto exige sem default).
    [[ -n "$METRICS_PUBLISH_IP" ]] && export METRICS_BIND_IP="$METRICS_PUBLISH_IP"
    for s in "${SERVICES[@]}"; do
        dir="$(service_dir "$s")"
        compose_args=(--project-directory "$dir" -f "$dir/docker-compose.yml")
        # Ordem: base → metrics → remote → backup → backup-local → override
        # (igual ao `bdh`). Overlays de backup sempre que existirem — omitir
        # desliga archive_mode em silêncio.
        [[ -f "$dir/docker-compose.metrics.yml" ]] && compose_args+=(-f "$dir/docker-compose.metrics.yml")
        [[ -f "$dir/docker-compose.metrics-remote.yml" ]] && compose_args+=(-f "$dir/docker-compose.metrics-remote.yml")
        [[ -f "$dir/docker-compose.backup.yml" ]] && compose_args+=(-f "$dir/docker-compose.backup.yml")
        [[ -f "$dir/docker-compose.backup-local.yml" ]] && compose_args+=(-f "$dir/docker-compose.backup-local.yml")
        [[ -f "$dir/docker-compose.override.yml" ]] && compose_args+=(-f "$dir/docker-compose.override.yml")
        # --metrics-only: sem --force-recreate (só o exporter novo).
        if [[ "$RECREATE" == "true" && "$METRICS_ONLY" != "true" ]]; then
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

    # initdb só em volume vazio — completar database/roles se a 1ª subida falhou no meio.
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

    # Depende do estado dos dados: falha aqui não usa die (bancos já podem estar no ar).

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

    # --- host OBSERVADO de um desenho distribuído ----------------------------
    if [[ -n "$METRICS_PUBLISH_IP" ]]; then
        local mdir_r; mdir_r="$(service_dir monitoring)"
        export METRICS_BIND_IP="$METRICS_PUBLISH_IP"
        # Só node-exporter neste host (profile node); Prometheus/Grafana alhures.
        if COMPOSE_PROFILES=node run docker compose -p monitoring \
                --project-directory "$mdir_r" \
                -f "$mdir_r/docker-compose.yml" \
                -f "$mdir_r/docker-compose.remote.yml" \
                up -d node-exporter; then
            ok "node exporter no ar em ${METRICS_PUBLISH_IP}:9100"
        else
            warn "node exporter não subiu — as métricas de HOST desta máquina"
            warn "  ficarão ausentes no Prometheus remoto ('bdh logs monitoring')"
        fi
        # @apelido embutido: este host conhece o hostname; o Prometheus remoto não.
        local apelido; apelido="$(host_label)"
        info "aponte o Prometheus do outro host para:"
        service_selected postgres && info "  --metrics-scrape postgres=${METRICS_PUBLISH_IP}:9187@${apelido}"
        service_selected redis    && info "  --metrics-scrape redis=${METRICS_PUBLISH_IP}:9121@${apelido}"
        service_selected opensearch && info "  --metrics-scrape opensearch=${METRICS_PUBLISH_IP}:${OPENSEARCH_PORT}@${apelido}"
        info "  --metrics-scrape node=${METRICS_PUBLISH_IP}:9100@${apelido}"
    fi

    [[ "$MONITORING_ENABLED" != "true" ]] && {
        info "--no-monitoring: Prometheus deve ser apontado de fora"
        if [[ -z "$METRICS_PUBLISH_IP" ]]; then
            warn "  os exporters escutam só na rede Docker '${METRICS_NETWORK}', SEM porta"
            warn "  publicada: um Prometheus em outro host não os alcança. Para o desenho"
            warn "  distribuído, use --metrics-publish <ip da interface privada>."
        fi
        return 0
    }

    # --- alvos e segredo do Prometheus ---------------------------------------
    local mdir; mdir="$(service_dir monitoring)"
    run mkdir -p "$mdir/targets" "$mdir/secrets"

    # Alvos = nomes de serviço Compose + labels.host. Sem arquivo se serviço ausente.
    # blackbox.json de fora: alvo é URL, não máquina.
    local hl; hl="$(host_label)"
    service_selected postgres \
        && printf '[{"targets":["postgres-exporter:9187"],"labels":{"host":"%s"}}]\n' "$hl" \
           > "$mdir/targets/postgres.json"
    service_selected redis \
        && printf '[{"targets":["redis-exporter:9121"],"labels":{"host":"%s"}}]\n' "$hl" \
           > "$mdir/targets/redis.json"
    if service_selected meilisearch && [[ -n "$MEILI_METRICS_KEY" ]]; then
        printf '[{"targets":["meilisearch:7700"],"labels":{"host":"%s"}}]\n' "$hl" \
            > "$mdir/targets/meilisearch.json"
        printf '%s' "$MEILI_METRICS_KEY" > "$mdir/secrets/meili-metrics.key"
    fi
    # OpenSearch: alvo em /_prometheus/metrics (plugin na imagem), sem exporter.
    service_selected opensearch \
        && printf '[{"targets":["opensearch:9200"],"labels":{"host":"%s"}}]\n' "$hl" \
           > "$mdir/targets/opensearch.json"
    if [[ "$OS_FAMILY" == "linux" ]]; then
        printf '[{"targets":["node-exporter:9100"],"labels":{"host":"%s"}}]\n' "$hl" \
            > "$mdir/targets/node.json"
        [[ "$METRICS_CONTAINERS" == "true" ]] \
            && printf '[{"targets":["cadvisor:8080"],"labels":{"host":"%s"}}]\n' "$hl" \
               > "$mdir/targets/cadvisor.json"
    fi

    # Remover arquivo de alvo local se o serviço saiu de --services.
    local job_local
    for job_local in postgres redis meilisearch opensearch; do
        service_selected "$job_local" && continue
        [[ -f "$mdir/targets/${job_local}.json" ]] || continue
        run rm -f "$mdir/targets/${job_local}.json"
        info "alvo obsoleto removido: ${job_local} (o serviço não está mais neste host)"
    done
    # A chave de métricas do Meilisearch acompanha o alvo dele: deixada para
    # trás, é um segredo em disco para um serviço que não existe mais.
    service_selected meilisearch || run rm -f "$mdir/secrets/meili-metrics.key"
    [[ "$METRICS_CONTAINERS" == "true" ]] || run rm -f "$mdir/targets/cadvisor.json"
    # --- alvos REMOTOS --------------------------------------------------------
    # Um arquivo por job com sufixo -remoto (glob <job>*.json).
    if [[ -n "$METRICS_SCRAPE" ]]; then
        local -a pares=(); local par job destino json
        IFS=',' read -r -a pares <<< "$METRICS_SCRAPE"
        for par in "${pares[@]}"; do
            case "${par%%=*}" in
                postgres|redis|node|opensearch|meilisearch|cadvisor|blackbox) ;;
                *) warn "--metrics-scrape: job desconhecido em '$par' (ignorado)"; continue ;;
            esac
            destino="${par#*=}"
            case "$destino" in *@*) destino="${destino%@*}" ;; esac
            # O `*:[0-9]*` de antes aceitava `fe80::1` sem colchetes — que passa
            # aqui e o Prometheus rejeita depois, com o alvo já escrito em disco.
            [[ "$destino" =~ :[0-9]{1,5}$ ]] \
                || die "--metrics-scrape: '$par' não está no formato job=host:porta[@apelido]"
            case "$destino" in
                \[*\]:*) ;;
                *:*:*) die "--metrics-scrape: IPv6 exige colchetes — use [${destino%:*}]:${destino##*:}" ;;
            esac
        done
        for job in postgres redis node opensearch meilisearch cadvisor; do
            if json="$(alvos_remotos_json "$job" "$METRICS_SCRAPE")"; then
                printf '%s\n' "$json" > "$mdir/targets/${job}-remoto.json"
                ok "alvo remoto do job $job: $json"
            else
                # Remover *-remoto órfão quando o job sai de --metrics-scrape.
                rm -f "$mdir/targets/${job}-remoto.json"
            fi
        done
    fi

    protect_metrics_key "$mdir/secrets/meili-metrics.key"
    ok "alvos escritos em $mdir/targets/"
    if [[ "$UPDATE_MODE" == "true" ]]; then
        # Mudar rótulo encerra séries antigas; rate()/increase() erram por uma janela.
        info "os alvos agora levam o rótulo host=$hl"
        info "  as séries antigas foram encerradas e recriadas: rate() e increase()"
        info "  que cruzarem este instante ficam errados pelos próximos ~5 minutos"
    fi

    # if ! compose: sob set -e, falha de pull não aborta antes do firewall.
    # Sem destino de alerta, Alertmanager fica fora do conjunto ativo (profile).
    local override="$mdir/docker-compose.override.yml"
    if tem_destino_de_alerta; then
        [[ -f "$override" ]] && { rm -f "$override"; ok "destino de alerta configurado: Alertmanager religado"; }
    else
        cat > "$override" <<'EOF'
# Gerado por setup.sh — NENHUM destino de alerta foi informado.
#
# Alertmanager recusa subir sem receiver; profile inativo evita restart loop.
# Para religar: informe um destino e reaplique (--update --alert-...).
services:
  alertmanager:
    profiles: ["alerting"]
EOF
        warn "Alertmanager desligado: nenhum destino de alerta configurado"
    fi

    local compose_args=(--project-directory "$mdir" -f "$mdir/docker-compose.yml")
    [[ -f "$override" ]] && compose_args+=(-f "$override")
    local up_args=(up -d)
    [[ "$RECREATE" == "true" ]] && up_args+=(--force-recreate)
    if ! run docker compose -p monitoring "${compose_args[@]}" "${up_args[@]}"; then
        warn "monitoring não subiu — o provisionamento segue sem observabilidade."
        warn "Veja 'bdh logs monitoring' e depois rode: bash setup.sh --metrics-only"
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
        # Loopback: sem regra ufw (DNAT só para 127.0.0.1).
        if [[ "$s" == "pgbouncer" ]]; then
            case "$PGBOUNCER_BIND_IP" in
                127.0.0.1|localhost)
                    info "pgbouncer: em loopback, sem regra de firewall"
                    continue ;;
            esac
        fi
        if [[ -n "$ALLOW_FROM" ]]; then
            # Apagar allow permissivo antigo antes da regra restrita.
            if [[ "$DRY_RUN" != "true" ]]; then
                ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
            fi
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

    # Exporters /metrics sem auth: incluir portas na DOCKER-USER.
    local -a portas_exporter=()
    if [[ -n "$METRICS_PUBLISH_IP" ]]; then
        service_selected postgres && portas_exporter+=(9187)
        service_selected redis && portas_exporter+=(9121)
        # OpenSearch/Meili: métricas na porta do serviço (não exporter).
        service_selected opensearch && portas_exporter+=("$OPENSEARCH_PORT")
        service_selected meilisearch && portas_exporter+=("$MEILI_PORT")
        portas_exporter+=(9100)
        for port in "${portas_exporter[@]}"; do
            if [[ -n "$ALLOW_FROM" ]]; then
                IFS=',' read -r -a cidrs <<< "$ALLOW_FROM"
                for cidr in "${cidrs[@]}"; do
                    run ufw allow from "$cidr" to any port "$port" proto tcp
                done
            else
                run ufw allow "${port}/tcp"
                warn "exporter na porta $port aberto para QUALQUER origem (/metrics não tem senha)"
            fi
        done
        ok "portas de exporter liberadas: ${portas_exporter[*]}"
    fi

    # Grafana/Prometheus no firewall só se não estiverem em loopback.
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
    # ufw filtra INPUT; tráfego a containers passa por DOCKER-USER.
    # Restrição real: chain DOCKER-USER em /etc/ufw/after.rules.
    # ------------------------------------------------------------------
    local rules_file=/etc/ufw/after.rules
    local begin='# BEGIN BrasilDataHub (setup.sh) — restrição das portas publicadas pelo Docker'
    local end='# END BrasilDataHub'
    # Prefixo estável (# BEGIN BrasilDataHub) — não casar o nome do script.
    local begin_re='^# BEGIN BrasilDataHub'
    local end_re='^# END BrasilDataHub'

    if [[ "$DRY_RUN" == "true" ]]; then
        _log "    ${C_DIM}[dry-run] ajustaria a chain DOCKER-USER em $rules_file${C_RESET}"
        return 0
    fi

    # Sem ALLOW_FROM: não alterar DOCKER-USER nem after.rules.
    # Chain viva sem bloco em after.rules não persiste no reboot.
    if [[ -z "$ALLOW_FROM" ]]; then
        run ufw reload
        if iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j DROP'; then
            warn "sem --allow-from: a chain DOCKER-USER existente foi PRESERVADA."
            warn "para alterá-la, repita --allow-from com a lista completa de origens."
            # Chain viva sem bloco em after.rules não persiste no reboot.
            if ! grep -qE "$begin_re" "$rules_file" 2>/dev/null; then
                warn "  ATENÇÃO: a chain está restrita mas NÃO está persistida em ${rules_file}."
                warn "  No próximo boot ela nasce vazia e as portas ficam abertas."
                warn "  Corrija reexecutando com a lista de origens, por exemplo:"
                warn "    --allow-from \$(iptables -S DOCKER-USER | awk '/-j RETURN/ && /-s/ {print \$4}' | sort -u | paste -sd,)"
            fi
        else
            warn "portas publicadas acessíveis de qualquer origem (sem --allow-from)"
            warn "as três portas de dados aceitam conexão da internet inteira."
        fi
        return 0
    fi

    # Idempotência: remove bloco anterior em after.rules (depois da guarda ALLOW_FROM).
    if grep -qE "$begin_re" "$rules_file" 2>/dev/null; then
        sed -i "/${begin_re}/,/${end_re}/d" "$rules_file"
    fi

    # Com ALLOW_FROM (flag ou estado) e chain vazia: reconstruir aqui.
    if ! iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j DROP'; then
        info "chain DOCKER-USER vazia: reconstruindo a partir de ALLOW_FROM=${ALLOW_FROM}"
    fi

    # Só CIDRs IPv4 em after.rules (iptables-restore); IPv6 invalida o arquivo.
    local -a cidrs_v4=() cidrs_v6=()
    IFS=',' read -r -a cidrs <<< "$ALLOW_FROM"
    for cidr in "${cidrs[@]}"; do
        [[ -z "$cidr" ]] && continue
        case "$cidr" in
            *:*) cidrs_v6+=("$cidr") ;;
            *)   cidrs_v4+=("$cidr") ;;
        esac
    done

    # Portas na DOCKER-USER (pula serviço em loopback).
    local -a portas_filtradas=()
    for s in "${SERVICES[@]}"; do
        if [[ "$s" == "pgbouncer" ]]; then
            case "$PGBOUNCER_BIND_IP" in 127.0.0.1|localhost) continue ;; esac
        fi
        portas_filtradas+=("$(service_internal_port "$s")")
    done
    # As portas dos exporters publicados passam pela mesma chain.
    for port in "${portas_exporter[@]+"${portas_exporter[@]}"}"; do
        portas_filtradas+=("$port")
    done

    if (( ${#cidrs_v6[@]} )); then
        warn "origens IPv6 em --allow-from (${cidrs_v6[*]}) não entram na chain DOCKER-USER:"
        warn "  ela é IPv4, e um endereço v6 ali invalida o arquivo de regras inteiro."
        warn "  O tráfego IPv6 para as portas publicadas passa pelo docker-proxy e é"
        warn "  filtrado pelo ufw (INPUT), que já recebeu as regras acima."
    fi
    if (( ${#cidrs_v4[@]} == 0 )); then
        warn "nenhuma origem IPv4 em --allow-from: as portas dos containers serão"
        warn "  BLOQUEADAS para todo o IPv4 (é o que 'só estas origens' significa)."
    fi

    # Esvaziar chain só aqui: reconstrução imediata abaixo (ufw reload sozinho não limpa).
    iptables -F DOCKER-USER 2>/dev/null || true

    {
        printf '%s\n' "$begin"
        printf '*filter\n:DOCKER-USER - [0:0]\n'
        printf -- '-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN\n'
        printf -- '-A DOCKER-USER -s 172.16.0.0/12 -j RETURN\n'   # entre containers
        printf -- '-A DOCKER-USER -s 127.0.0.0/8 -j RETURN\n'     # do próprio host
        for port in "${portas_filtradas[@]+"${portas_filtradas[@]}"}"; do
            for cidr in "${cidrs_v4[@]+"${cidrs_v4[@]}"}"; do
                printf -- '-A DOCKER-USER -p tcp --dport %s -s %s -j RETURN\n' "$port" "$cidr"
            done
            printf -- '-A DOCKER-USER -p tcp --dport %s -j DROP\n' "$port"
        done
        printf -- '-A DOCKER-USER -j RETURN\nCOMMIT\n'
        printf '%s\n' "$end"
    } >> "$rules_file"

    # `if !`, e não `run ufw reload` solto: sob `set -e` uma falha aqui aborta o
    # script com a chain recém-esvaziada — o estado mais inseguro possível.
    if ! run ufw reload; then
        warn "o 'ufw reload' falhou; aplicando as regras direto na chain DOCKER-USER."
    fi

    # Sem porta publicada: não há o que restringir (evita falso alarme).
    if (( ${#portas_filtradas[@]} == 0 )); then
        ok "nenhuma porta publicada neste host — nada a restringir na DOCKER-USER"
        return 0
    fi

    # Verificar DROP na chain; se reload falhou, aplicar à mão (sem persistência).
    if ! iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j DROP'; then
        for port in "${portas_filtradas[@]+"${portas_filtradas[@]}"}"; do
            for cidr in "${cidrs_v4[@]+"${cidrs_v4[@]}"}"; do
                iptables -A DOCKER-USER -p tcp --dport "$port" -s "$cidr" -j RETURN 2>/dev/null || true
            done
            iptables -A DOCKER-USER -p tcp --dport "$port" -j DROP 2>/dev/null || true
        done
        if iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j DROP'; then
            warn "chain DOCKER-USER povoada à mão. A persistência em $rules_file"
            warn "  NÃO foi aplicada: confira o arquivo antes do próximo boot."
        else
            warn "NÃO foi possível restringir as portas dos containers. Elas estão"
            warn "  acessíveis de qualquer origem — trate isto antes de expor dados."
        fi
    else
        ok "chain DOCKER-USER restringe as portas dos containers a ${cidrs_v4[*]:-nenhuma origem IPv4}"
    fi
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
# Instalado por setup.sh. Os caminhos vêm de setup.conf (em /etc ou ~/.config).
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
    # Mesma ordem do setup.sh: base → metrics → remote → backup → override.
    [[ -f "$dir/docker-compose.metrics.yml" ]] && args+=(-f "$dir/docker-compose.metrics.yml")
    if [[ -f "$dir/docker-compose.metrics-remote.yml" ]]; then
        # METRICS_BIND_IP sem default (arquivo próprio — não recria o serviço).
        if [[ -f "$BDH_ROOT/.metrics-remote.env" ]]; then
            set -a; . "$BDH_ROOT/.metrics-remote.env"; set +a
        fi
        args+=(-f "$dir/docker-compose.metrics-remote.yml")
    fi
    # Overlays de backup sempre que existirem: sem eles archive_mode volta a off.
    [[ -f "$dir/docker-compose.backup.yml" ]] && args+=(-f "$dir/docker-compose.backup.yml")
    [[ -f "$dir/docker-compose.backup-local.yml" ]] && args+=(-f "$dir/docker-compose.backup-local.yml")
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
for t in sorted(alvos, key=lambda x: (x["labels"].get("host", ""), x["labels"]["job"])):
    erro = t.get("lastError", "")
    print("  %-14s %-14s %-34s %s%s" % (t["labels"].get("host", "—"),
                                        t["labels"]["job"], t["scrapeUrl"], t["health"],
                                        "  " + erro[:60] if erro else ""))
' 2>/dev/null; then
        echo "  Prometheus não respondeu em 127.0.0.1:${porta}"
        echo "  (ele publica só em loopback por default — rode isto no próprio host)"
        exit 1
    fi

    echo
    echo "== servidores"
    _t 5 curl -fsS --get "http://127.0.0.1:${porta}/api/v1/query" \
        --data-urlencode 'query=sum by (host) (up) / count by (host) (up)' 2>/dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)["data"]["result"]
if not r:
    print("  nenhuma série tem rótulo host — reaplique com: bash setup.sh --update")
    print("  (sem ele a seção de infraestrutura do Grafana fica vazia)")
for x in sorted(r, key=lambda y: y["metric"].get("host", "")):
    frac = float(x["value"][1])
    print("  %-16s %s" % (x["metric"].get("host", "—"),
                          "todos os alvos no ar" if frac == 1
                          else "ATENCAO: %d%% dos alvos no ar" % round(frac * 100)))
' 2>/dev/null || echo "  (não foi possível consultar)"

    # Apelido de --metrics-scrape pode divergir do uname remoto — avisar aqui.
    _t 5 curl -fsS --get "http://127.0.0.1:${porta}/api/v1/query" \
        --data-urlencode 'query=count by (host, nodename, chave) (label_replace(node_uname_info, "chave", "$1", "host", "(.*)")) unless count by (host, nodename, chave) (label_replace(node_uname_info, "chave", "$1", "nodename", "(.*)"))' \
        2>/dev/null | python3 -c '
import json, sys
for x in json.load(sys.stdin)["data"]["result"]:
    m = x["metric"]
    print("  AVISO: apelido %r nao bate com o hostname real %r"
          % (m.get("host", ""), m.get("nodename", "")))
    print("         o link do dashboard de host vai para a maquina errada")
' 2>/dev/null || true

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
    # Cabeçalho ASCII: `column` escapa não-ASCII se locale ≠ UTF-8.
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
    # `bdh pull`: pull com os overlays certos na ordem certa.
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
        # up -d sem --force-recreate: Compose só recria o que mudou.
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
        # Conferir shm_size (não só exibir): gate do runbook mensal.
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

    # Variáveis resolvidas no login — aspas simples no corpo do MOTD.
    # shellcheck disable=SC2016
    local motd_body='#!/usr/bin/env bash
# Mensagem de login — serviços de dados da BrasilDataHub (setup.sh).
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
        info "  $s → $(service_bind_ip "$s"):${port}   ($(service_dir "$s"))"
    done
    # OpenSearch sem auth: firewall é a única barreira.
    if service_selected opensearch && [[ -z "$ALLOW_FROM" && "$BIND_IP" == "0.0.0.0" ]]; then
        _log ""
        warn "o OpenSearch está publicado em 0.0.0.0 e NÃO TEM AUTENTICAÇÃO."
        warn "quem alcançar a porta ${OPENSEARCH_PORT} lê e apaga o índice inteiro."
        warn "use --allow-from <CIDR> ou --bind-ip <interface privada>."
    fi
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
    _log "${C_BOLD}setup.sh v${SCRIPT_VERSION}${C_RESET} — serviços de dados da BrasilDataHub"
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
# test/setup.test.sh exercita a lógica de perfis e caminhos.
if [[ -z "${BDH_SETUP_LIB_ONLY:-}" ]]; then
    main
fi
