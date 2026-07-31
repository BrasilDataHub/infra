#!/usr/bin/env bash
# O teste que faltava: rodar o script DUAS VEZES e comparar o que ele produziu.
#
#   bash test/reexecucao.test.sh
#
# Nenhum teste executava `main()` nem re-execução (05 §5.2, item 11), e é
# exatamente aí que morava o defeito mais caro do script: ele GRAVA o
# `.setup-state` e não o RELÊ.
#
# A consequência não é teórica. `--metrics-only` — o comando que o README
# indica para ligar observabilidade — roda o `main()` inteiro com os DEFAULTS DE
# FÁBRICA. Num servidor de dados isso significa:
#
#   POSTGRES_DB volta para "dados"  → o .env muda → o Postgres é RECRIADO, e a
#                                     DSN do exporter aponta para um database
#                                     que não existe (o real é dados_cnpj)
#   BIND_IP volta para 0.0.0.0      → recriado E reexposto
#   ALLOW_FROM volta para vazio     → a chain DOCKER-USER é esvaziada
#   SERVICES volta ao trio default  → instala Redis e Meilisearch do zero num
#                                     host que talvez só tenha Postgres
#
# Cada valor, sozinho, parece plausível. É por isso que só um teste de
# RE-EXECUÇÃO pega.
#
# O teste roda em modo dry-run e com um WORKDIR temporário: não sobe container,
# não toca em nada do host.
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  ✓ %s\n' "$1"; PASS=$((PASS+1)); }
nok() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '\nRe-execução: o estado é lido de volta\n'

# Um `.setup-state` como o que uma instalação real deixa.
mkdir -p "$TMP/workdir"
cat > "$TMP/workdir/.setup-state" <<STATE
SCRIPT_VERSION=teste
REF=main
INSTALLED_AT=2026-07-01T00:00:00Z
SERVICES=postgres
VOLUMES_MODE=named
WORKDIR=$TMP/workdir
POSTGRES_DB=dados_cnpj
BIND_IP=10.0.0.5
ALLOW_FROM=10.0.0.0/24
POSTGRES_PORT=15432
REDIS_PORT=6379
MEILI_PORT=7700
PG_PROFILE=compartilhada-14gb
METRICS_ENABLED=false
STATE

# Carrega o script como biblioteca e exercita load_state() diretamente: é a
# função que decide, e testá-la isolada mostra QUAL valor veio de onde.
carregar() {
    # shellcheck disable=SC1090
    BDH_SETUP_LIB_ONLY=1 . "$RAIZ/setup.sh"
    set +e
    trap - ERR
    WORKDIR="$TMP/workdir"
}

# --- 1. sem flags: tudo herdado -------------------------------------------
(
    carregar
    load_state >/dev/null 2>&1

    erros=""
    [[ "$POSTGRES_DB"    == "dados_cnpj"         ]] || erros="$erros POSTGRES_DB=$POSTGRES_DB"
    [[ "$BIND_IP"        == "10.0.0.5"           ]] || erros="$erros BIND_IP=$BIND_IP"
    [[ "$ALLOW_FROM"     == "10.0.0.0/24"        ]] || erros="$erros ALLOW_FROM=$ALLOW_FROM"
    [[ "$POSTGRES_PORT"  == "15432"              ]] || erros="$erros POSTGRES_PORT=$POSTGRES_PORT"
    [[ "$SERVICES_INPUT" == "postgres"           ]] || erros="$erros SERVICES=$SERVICES_INPUT"
    [[ "$PG_PROFILE"     == "compartilhada-14gb" ]] || erros="$erros PG_PROFILE=$PG_PROFILE"
    printf '%s' "$erros"
) > "$TMP/r1"
if [[ ! -s "$TMP/r1" ]]; then
    ok "sem flags, TUDO é herdado do .setup-state (era o defeito: voltava ao default)"
else
    nok "valores não herdados:$(cat "$TMP/r1")"
fi

# --- 2. flag explícita vence o estado -------------------------------------
(
    carregar
    POSTGRES_DB="outro"; _explicita POSTGRES_DB
    BIND_IP="0.0.0.0";   _explicita BIND_IP
    load_state >/dev/null 2>&1

    erros=""
    [[ "$POSTGRES_DB" == "outro"   ]] || erros="$erros POSTGRES_DB=$POSTGRES_DB"
    [[ "$BIND_IP"     == "0.0.0.0" ]] || erros="$erros BIND_IP=$BIND_IP"
    # o que NÃO foi passado continua vindo do estado
    [[ "$ALLOW_FROM"  == "10.0.0.0/24" ]] || erros="$erros ALLOW_FROM=$ALLOW_FROM"
    printf '%s' "$erros"
) > "$TMP/r2"
if [[ ! -s "$TMP/r2" ]]; then
    ok "flag explícita sobrescreve; a ausente continua herdando"
else
    nok "precedência errada:$(cat "$TMP/r2")"
fi

# --- 2b. a interface do painel sobrevive ao --update -----------------------
# `MONITORING_BIND_IP` era gravado no `.env` do monitoring e NÃO no
# `.setup-state`, e `load_state` não tinha caso para ele. O efeito: quem
# publicou o Grafana numa interface alcançável — a VPN, a rede privada — via o
# PRÓXIMO `--update` devolvê-lo a 127.0.0.1. Nada falhava; o painel só parava
# de responder, e o default de fábrica é loopback justamente porque o
# Prometheus não tem autenticação, o que faz a reversão parecer inofensiva.
mkdir -p "$TMP/wd-mon"
cat > "$TMP/wd-mon/.setup-state" <<STATE
SERVICES=postgres
WORKDIR=$TMP/wd-mon
METRICS_ENABLED=true
MONITORING_ENABLED=true
METRICS_PROFILE=metricas-512mb
MONITORING_BIND_IP=100.113.167.6
STATE
(
    carregar
    WORKDIR="$TMP/wd-mon"
    load_state >/dev/null 2>&1
    [[ "$MONITORING_BIND_IP" == "100.113.167.6" ]] \
        || printf 'MONITORING_BIND_IP=%s' "$MONITORING_BIND_IP"
) > "$TMP/r2b"
if [[ ! -s "$TMP/r2b" ]]; then
    ok "a interface do painel é herdada (era o defeito: voltava a 127.0.0.1)"
else
    nok "interface do painel não herdada: $(cat "$TMP/r2b")"
fi

# E o inverso: a flag tem de vencer o estado. Sem `_explicita` na análise de
# `--metrics-bind-ip`, o valor herdado venceria a flag recém-passada e mudar a
# interface do painel viraria uma operação sem efeito nenhum.
(
    carregar
    WORKDIR="$TMP/wd-mon"
    MONITORING_BIND_IP="127.0.0.1"; _explicita MONITORING_BIND_IP
    load_state >/dev/null 2>&1
    [[ "$MONITORING_BIND_IP" == "127.0.0.1" ]] \
        || printf 'MONITORING_BIND_IP=%s' "$MONITORING_BIND_IP"
) > "$TMP/r2c"
if [[ ! -s "$TMP/r2c" ]]; then
    ok "--metrics-bind-ip explícito vence o estado (inclusive para voltar ao loopback)"
else
    nok "a flag não venceu o estado: $(cat "$TMP/r2c")"
fi

# O estado precisa CONTER o que promete herdar. O teste acima passaria com o
# script gravando o valor em lugar nenhum, porque a fixture é escrita à mão.
if grep -q "printf 'MONITORING_BIND_IP=%s" "$RAIZ/setup.sh"; then
    ok "o setup.sh grava MONITORING_BIND_IP no .setup-state"
else
    nok "MONITORING_BIND_IP não é gravado no estado — a herança acima é letra morta"
fi

# --- 2d. recriar container é decisão separada de reaplicar configuração ----
# `--update` e `--add-service` marcavam FORCE=true, e FORCE=true virava
# `--force-recreate` em TODO serviço. O modo que o README manda usar derrubava
# um Postgres de 156 GB cuja definição não mudara, e o `--add-service` — cujo
# comentário promete "sem tocar nos outros" — recriava todos eles.
#
# O custo real não é o restart: é o ETL com cursor server-side que morre com
# `AdminShutdown` a horas do início.
verifica_recreate() {
    local flag="$1" esperado="$2" desc="$3"
    (
        carregar
        # shellcheck disable=SC2086  # a flag precisa ser dividida em palavras
        parse_args $flag >/dev/null 2>&1 || true
        [[ "$RECREATE" == "$esperado" ]] || printf 'RECREATE=%s' "$RECREATE"
    ) > "$TMP/rc"
    if [[ ! -s "$TMP/rc" ]]; then ok "$desc"; else nok "$desc — $(cat "$TMP/rc")"; fi
}
if declare -f parse_args >/dev/null 2>&1; then
    verifica_recreate "--update"                 "false" "--update NÃO força recriação (Compose recria só o que mudou)"
    verifica_recreate "--add-service opensearch" "false" "--add-service NÃO recria os serviços que já existiam"
    verifica_recreate "--force"                  "true"  "--force recria por decreto (é o que 'do zero' significa)"
else
    # A análise de flags não é uma função isolável: afirma-se sobre o código.
    if grep -q 'update) UPDATE_MODE="true"; FORCE="true"; RECREATE="true"' "$RAIZ/setup.sh"; then
        nok "--update voltou a forçar recriação de todos os serviços"
    else
        ok "--update não marca RECREATE"
    fi
    grep -q -- '-f|--force) FORCE="true"; RECREATE="true"' "$RAIZ/setup.sh" \
        && ok "--force é o único modo que recria por decreto" \
        || nok "--force deixou de marcar RECREATE"
    grep -q '\[\[ "\$RECREATE" == "true" \]\] && up_args+=(--force-recreate)' "$RAIZ/setup.sh" \
        && ok "o monitoring usa RECREATE, não FORCE" \
        || nok "o monitoring voltou a recriar por FORCE"
    grep -q 'if \[\[ "\$RECREATE" == "true" && "\$METRICS_ONLY" != "true" \]\]' "$RAIZ/setup.sh" \
        && ok "os serviços de dados usam RECREATE, não FORCE" \
        || nok "os serviços de dados voltaram a recriar por FORCE"
fi

# `--bind-ip 0.0.0.0` é o caso que prova que a distinção não pode ser feita
# olhando só o valor: ele é IDÊNTICO ao default, e ainda assim precisa vencer o
# estado quando foi pedido de propósito.
(
    carregar
    BIND_IP="0.0.0.0"; _explicita BIND_IP
    load_state >/dev/null 2>&1
    printf '%s' "$BIND_IP"
) > "$TMP/r2b"
if [[ "$(cat "$TMP/r2b")" == "0.0.0.0" ]]; then
    ok "--bind-ip 0.0.0.0 (igual ao default) vence o estado quando é explícito"
else
    nok "flag com valor igual ao default foi ignorada"
fi

# --- 3. --add-service ACRESCENTA, não substitui ---------------------------
(
    carregar
    ADD_SERVICE="opensearch"
    load_state >/dev/null 2>&1
    printf '%s' "$SERVICES_INPUT"
) > "$TMP/r3"
if [[ "$(cat "$TMP/r3")" == "postgres,opensearch" ]]; then
    ok "--add-service acrescenta ao conjunto herdado"
else
    nok "--add-service produziu '$(cat "$TMP/r3")' — substituir removeria os outros serviços do conjunto gerenciado"
fi

(
    carregar
    ADD_SERVICE="postgres"
    load_state >/dev/null 2>&1
    printf '%s' "$SERVICES_INPUT"
) > "$TMP/r3b"
if [[ "$(cat "$TMP/r3b")" == "postgres" ]]; then
    ok "--add-service de um serviço já instalado é no-op"
else
    nok "serviço duplicado no conjunto: '$(cat "$TMP/r3b")'"
fi

# --- 4. observabilidade: liga herdando, mas não DESLIGA por herança -------
cat > "$TMP/workdir/.setup-state.metrics" <<STATE
SERVICES=postgres
VOLUMES_MODE=named
METRICS_ENABLED=true
METRICS_PROFILE=metricas-2gb
MONITORING_ENABLED=true
STATE
(
    carregar
    cp "$TMP/workdir/.setup-state.metrics" "$TMP/workdir/.setup-state"
    load_state >/dev/null 2>&1
    printf '%s|%s' "$METRICS_ENABLED" "$METRICS_PROFILE"
) > "$TMP/r4"
if [[ "$(cat "$TMP/r4")" == "true|metricas-2gb" ]]; then
    ok "observabilidade já ligada é herdada com o perfil"
else
    nok "observabilidade não herdada: '$(cat "$TMP/r4")'"
fi

printf '\nCatálogo: os serviços novos\n'
(
    carregar
    erros=""
    [[ "$(service_internal_port opensearch)" == "9200" ]] || erros="$erros porta-interna-os"
    [[ "$(service_internal_port pgbouncer)"  == "6432" ]] || erros="$erros porta-interna-pgb"
    [[ "$(service_volume_key opensearch)"    == "os_data" ]] || erros="$erros volume-key-os"
    # A linha que impede o `auto` do Postgres de superdimensionar: sem ela, o
    # heap de 8 GiB do motor de busca não é descontado do orçamento do host.
    [[ "$(neighbor_budget_gb compartilhada-8gb)" == "8" ]] || erros="$erros orcamento-os"
    printf '%s' "$erros"
) > "$TMP/r5"
if [[ ! -s "$TMP/r5" ]]; then
    ok "opensearch e pgbouncer estão no catálogo, com orçamento de vizinho"
else
    nok "catálogo incompleto:$(cat "$TMP/r5")"
fi

# O dimensionamento coordenado COM o motor de busca: num host de 31 GiB, o
# Postgres não pode receber o perfil de 32 GB.
(
    carregar
    viz=$(( $(neighbor_budget_gb compartilhada-8gb) + $(neighbor_budget_gb metricas-2gb) ))
    printf '%s' "$(detect_pg_profile $(( 31 - viz )))"
) > "$TMP/r6"
if [[ "$(cat "$TMP/r6")" != "dedicada-32gb" ]]; then
    ok "com OpenSearch no host, o Postgres não recebe o perfil de 32 GB (recebeu $(cat "$TMP/r6"))"
else
    nok "o Postgres foi superdimensionado ignorando o heap do motor de busca"
fi

printf '\nHost só de observabilidade e merge de credenciais\n'
# Lacuna 7: `monitoring` em --services não era aceito, porque o gerador de
# override de bind assume um volume de dados por serviço. Um host só de
# observabilidade — que é o desenho deste roadmap, com o Prometheus no bdh-apps
# — não era provisionável.
# `validate_and_prompt` faz muito mais que validar (detecta RAM, baixa perfis);
# o que interessa aqui é o trecho da allowlist, exercitado diretamente.
(
    carregar
    SERVICES_INPUT="monitoring"
    IFS=',' read -r -a SERVICES <<< "$SERVICES_INPUT"
    for s in "${SERVICES[@]}"; do
        case "$s" in
            postgres|redis|meilisearch|opensearch|pgbouncer) ;;
            monitoring)
                METRICS_ENABLED="true"; MONITORING_ENABLED="true"; SOMENTE_MONITORING="true" ;;
            *) printf 'RECUSADO'; exit ;;
        esac
    done
    if [[ "$SOMENTE_MONITORING" == "true" ]]; then
        restantes=()
        for s in "${SERVICES[@]}"; do
            [[ "$s" == "monitoring" ]] || restantes+=("$s")
        done
        SERVICES=("${restantes[@]+"${restantes[@]}"}")
    fi
    printf '%s|%s|%s' "$SOMENTE_MONITORING" "$METRICS_ENABLED" "${#SERVICES[@]}"
) > "$TMP/r7"
if [[ "$(cat "$TMP/r7")" == "true|true|0" ]]; then
    ok "--services monitoring provisiona host só de observabilidade (0 serviços de dados)"
else
    nok "host só de observabilidade não aceito: '$(cat "$TMP/r7")'"
fi

# Lacuna 3: credentials.env era reescrito com as credenciais apenas dos serviços
# DESTA execução. Um --add-service truncava as senhas dos outros, e o operador
# só descobria ao precisar delas.
if grep -q 'preservadas de execuções anteriores' "$RAIZ/setup.sh"; then
    ok "credentials.env recebe merge em vez de ser truncado"
else
    nok "credentials.env é reescrito: --add-service perderia as senhas dos outros serviços"
fi

# Lacuna 4: com ALLOW_FROM herdado e a chain vazia, a reconstrução acontece.
if grep -q 'reconstruindo a partir de ALLOW_FROM' "$RAIZ/setup.sh"; then
    ok "a chain DOCKER-USER é reconstruída a partir do estado herdado"
else
    nok "sem reconstrução: o firewall só voltaria repetindo a flag de cor"
fi

# Lacuna 6: não havia caminho para atualizar imagem.
if grep -q 'cmd_pull()' "$RAIZ/setup.sh"; then
    ok 'há bdh pull para atualizar imagem sem recriar o que não mudou'
else
    nok "sem bdh pull"
fi

printf '\nO comando bdh\n'
# O `bdh` são ~180 linhas dentro de um heredoc, e nenhum teste o olhava — nem
# sintaticamente. Um erro ali só apareceria no servidor, no primeiro uso, e o
# heredoc esconde o erro do `bash -n` do script hospedeiro.
awk "/<<'BDH'/{flag=1;next}/^BDH\$/{flag=0}flag" "$RAIZ/setup.sh" > "$TMP/bdh-cli.sh"
if [[ -s "$TMP/bdh-cli.sh" ]] && bash -n "$TMP/bdh-cli.sh" 2>/dev/null; then
    ok "o corpo do comando bdh tem sintaxe válida ($(wc -l < "$TMP/bdh-cli.sh" | tr -d ' ') linhas)"
else
    nok "o corpo do bdh não passa no bash -n — o erro só apareceria no servidor"
fi
for verbo in status logs up down restart verify pull metrics creds path; do
    if grep -qE "^\s+${verbo}\)" "$TMP/bdh-cli.sh"; then
        :
    else
        nok "o bdh não trata o verbo '${verbo}'"
    fi
done
ok "todos os verbos do bdh estão no dispatch"

# --- 6. A ORDEM: load_state precisa rodar ANTES de o array SERVICES existir --
#
# Este e o teste que faltava. Os de cima chamam load_state() diretamente e
# passam mesmo com a ordem errada — foi exatamente o que aconteceu: load_state
# vivia em preflight(), que roda DEPOIS de validate_and_prompt() ter derivado o
# array SERVICES da string SERVICES_INPUT. Resultado: `--add-service opensearch`
# acrescentava a string e ninguem mais olhava para ela. O servico simplesmente
# nao era provisionado, sem erro nenhum.
#
# Aqui o que se exercita e o FLUXO: chama validate_and_prompt() de verdade e
# confere o ARRAY, que e o que todo o resto do script consome.
printf '\nordem de carregamento\n'
(
    carregar
    mkdir -p "$WORKDIR"
    cat > "$WORKDIR/.setup-state" <<'ST'
SERVICES=postgres,redis,meilisearch
PG_PROFILE=dedicada-8gb
MEILI_PROFILE=busca-4gb
ST
    ADD_SERVICE="opensearch"
    UPDATE_MODE="true"
    AUTO="true"
    validate_and_prompt >/dev/null 2>&1
    printf '%s|%s' "${SERVICES[*]}" "$MEILI_PROFILE"
) > "$TMP/r6" 2>/dev/null
saida="$(cat "$TMP/r6")"
if [[ "${saida%%|*}" == *"opensearch"* ]]; then
    ok "--add-service chega ao ARRAY SERVICES, e nao so a string"
else
    nok "o array ficou '${saida%%|*}' — o servico nao seria provisionado"
fi
if [[ "${saida##*|}" == "busca-4gb" ]]; then
    ok "perfil herdado sobrevive ao dimensionamento"
else
    nok "perfil virou '${saida##*|}' em vez do herdado busca-4gb"
fi

# --- 7. o OpenSearch entra no ORCAMENTO de memoria ---------------------------
#
# Ele entrou no catalogo de servicos sem entrar na conta de vizinhos: o
# `neighbor_budget_gb` tinha a entrada, e nada a somava. Numa maquina com
# Postgres e Meilisearch, `--add-service opensearch` reportava "vizinhos 7 GB"
# ignorando os 8 GiB do motor, e o `auto` do Postgres escolhia um perfil que nao
# cabe. O sintoma seria OOM-kill semanas depois.
printf '\norcamento de memoria\n'
(
    carregar
    mkdir -p "$WORKDIR"
    cat > "$WORKDIR/.setup-state" <<'ST'
SERVICES=postgres,redis,meilisearch
PG_PROFILE=dedicada-8gb
MEILI_PROFILE=busca-4gb
REDIS_PROFILE=cache-512mb
ST
    ADD_SERVICE="opensearch"; UPDATE_MODE="true"; AUTO="true"
    validate_and_prompt >/dev/null 2>&1
    # 8 do OpenSearch tem de estar na conta
    printf '%s' "$(neighbor_budget_gb "$OPENSEARCH_PROFILE")"
) > "$TMP/r7" 2>/dev/null
if [[ "$(cat "$TMP/r7")" == "8" ]]; then
    ok "o perfil do OpenSearch declara orcamento de 8 GB"
else
    nok "orcamento do OpenSearch veio '$(cat "$TMP/r7")'"
fi
if grep -qF 'neighbors_gb + $(neighbor_budget_gb "$OPENSEARCH_PROFILE")' "$RAIZ/setup.sh"; then
    ok "o orcamento do OpenSearch e SOMADO aos vizinhos"
else
    nok "o OpenSearch nao entra em neighbors_gb — o auto do Postgres superdimensiona"
fi

# --- 8. dimensionamento em maquina DEDICADA -------------------------------
printf '\ndimensionamento\n'

# 8a. profile_budget_gb com o perfil "compartilhada"
(
    carregar
    printf '%s' "$(profile_budget_gb compartilhada-14gb)"
) > "$TMP/d1"
if [[ "$(cat "$TMP/d1")" == "14" ]]; then
    ok "profile_budget_gb entende o perfil compartilhada"
else
    nok "devolveu '$(cat "$TMP/d1")' — dentro de (( )) isso vira -14 e a checagem e pulada"
fi

# 8b. o auto NAO pode escolher um perfil que a checagem seguinte recusa.
# 28, 29, 30 e 56 GiB sao tamanhos NOMINAIS comuns (32 e 64 GB reportando
# menos), e neles o script se matava sugerindo o perfil que acabara de recusar.
(
    carregar
    falhas=""
    for m in 27 28 29 30 31 46 47 55 56 62 94; do
        p="$(detect_pg_profile $m)"
        b="$(profile_budget_gb "$p")"
        (( b * 87 / 100 > m )) && falhas="${falhas} ${m}GB:${p}"
    done
    printf '%s' "$falhas"
) > "$TMP/d2"
if [[ -z "$(cat "$TMP/d2")" ]]; then
    ok "o perfil escolhido pelo auto sempre CABE (limite = 87% do orcamento)"
else
    nok "o auto escolhe perfil que a checagem recusa:$(cat "$TMP/d2")"
fi
# O acima confere a REGRA; este confere que o SCRIPT a aplica. Sem isto o teste
# passaria mesmo com a checagem antiga, que comparava o nome do perfil com a RAM.
if grep -qF 'limite_gb=$(( budget * 87 / 100 ))' "$RAIZ/setup.sh"; then
    ok "a checagem compara o LIMITE do container, nao o nome do perfil"
else
    nok "a checagem ainda usa o numero do nome — recusa perfil que subiria bem"
fi

# 8c. o conselho da mensagem de erro precisa ser acionavel
(
    carregar
    printf '%s|%s' "$(maior_perfil_que_cabe 30)" "$(maior_perfil_que_cabe 55)"
) > "$TMP/d3"
if [[ "$(cat "$TMP/d3")" == "dedicada-32gb|dedicada-64gb" ]]; then
    ok "maior_perfil_que_cabe devolve o maior que REALMENTE cabe"
else
    nok "devolveu '$(cat "$TMP/d3")'"
fi

# 8d. o aviso de capacidade ociosa: dispara onde deve e cala onde deve
(
    carregar
    erros=""
    # (livre, deve_avisar)
    for caso in "15:nao" "23:sim" "31:nao" "47:sim" "55:sim" "62:nao" "94:sim"; do
        m="${caso%%:*}"; esperado="${caso##*:}"
        b="$(profile_budget_gb "$(detect_pg_profile $m)")"
        if (( m >= b + b / 4 )); then real="sim"; else real="nao"; fi
        [[ "$real" == "$esperado" ]] || erros="${erros} ${m}GB(esperado=$esperado,real=$real)"
    done
    printf '%s' "$erros"
) > "$TMP/d4"
if [[ -z "$(cat "$TMP/d4")" ]]; then
    ok "o aviso de capacidade ociosa dispara nas faixas certas"
else
    nok "divergencia:$(cat "$TMP/d4")"
fi
if grep -qF 'livre_final >= budget + budget / 4' "$RAIZ/setup.sh" \
   && grep -q 'comporta mais do que' "$RAIZ/setup.sh"; then
    ok "o aviso de capacidade ociosa existe no script"
else
    nok "o script nao avisa quando a maquina comporta mais que o perfil"
fi

# 8e. servico SEM perfil nao pode matar o provisionamento
(
    carregar
    PROFILES_DIR="$TMP"          # forca o caminho local, sem rede
    fetch_profile pgbouncer >/dev/null 2>&1 && printf 'ok' || printf 'MORREU'
) > "$TMP/d5"
if [[ "$(cat "$TMP/d5")" == "ok" ]]; then
    ok "servico sem perfil (pgbouncer) nao aborta o setup"
else
    nok "fetch_profile morre com pgbouncer — e o README manda rodar --add-service pgbouncer"
fi

printf '\nsysctl\n'
if grep -q 'vm.max_map_count' "$RAIZ/setup.sh" && grep -q '/etc/sysctl.d/' "$RAIZ/setup.sh"; then
    ok "há etapa de sysctl, com persistência em /etc/sysctl.d/"
else
    nok "sem etapa de sysctl — o OpenSearch morre no bootstrap check"
fi

# Encontrada uma maquina real com vm.max_map_count=1048576 — quatro vezes o
# minimo do OpenSearch. Persistir 262144 por cima rebaixaria no proximo boot
# um valor que outro servico pode depender, e o sintoma apareceria longe daqui.
(
    carregar
    VM_MAX_MAP_COUNT=262144
    atual=1048576
    alvo="$VM_MAX_MAP_COUNT"
    [[ "$atual" -gt "$alvo" ]] && alvo="$atual"
    printf '%s' "$alvo"
) > "$TMP/sysctl1"
if [[ "$(cat "$TMP/sysctl1")" == "1048576" ]]; then
    ok "um valor de max_map_count MAIOR que o exigido e preservado"
else
    nok "rebaixaria para $(cat "$TMP/sysctl1")"
fi
if grep -q 'NUNCA rebaixar' "$RAIZ/setup.sh" && grep -qF 'alvo="$atual"' "$RAIZ/setup.sh"; then
    ok "a guarda de nao-rebaixamento esta no script, nao so no teste"
else
    nok "o script nao preserva valor maior"
fi

printf '\n  %d passaram, %d falharam\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
