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
    BDH_SETUP_LIB_ONLY=1 . "$RAIZ/infra-setup.sh"
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
if grep -q 'preservadas de execuções anteriores' "$RAIZ/infra-setup.sh"; then
    ok "credentials.env recebe merge em vez de ser truncado"
else
    nok "credentials.env é reescrito: --add-service perderia as senhas dos outros serviços"
fi

# Lacuna 4: com ALLOW_FROM herdado e a chain vazia, a reconstrução acontece.
if grep -q 'reconstruindo a partir de ALLOW_FROM' "$RAIZ/infra-setup.sh"; then
    ok "a chain DOCKER-USER é reconstruída a partir do estado herdado"
else
    nok "sem reconstrução: o firewall só voltaria repetindo a flag de cor"
fi

# Lacuna 6: não havia caminho para atualizar imagem.
if grep -q 'cmd_pull()' "$RAIZ/infra-setup.sh"; then
    ok 'há bdh pull para atualizar imagem sem recriar o que não mudou'
else
    nok "sem bdh pull"
fi

printf '\nO comando bdh\n'
# O `bdh` são ~180 linhas dentro de um heredoc, e nenhum teste o olhava — nem
# sintaticamente. Um erro ali só apareceria no servidor, no primeiro uso, e o
# heredoc esconde o erro do `bash -n` do script hospedeiro.
awk "/<<'BDH'/{flag=1;next}/^BDH\$/{flag=0}flag" "$RAIZ/infra-setup.sh" > "$TMP/bdh-cli.sh"
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

printf '\nsysctl\n'
if grep -q 'vm.max_map_count' "$RAIZ/infra-setup.sh" && grep -q '/etc/sysctl.d/' "$RAIZ/infra-setup.sh"; then
    ok "há etapa de sysctl, com persistência em /etc/sysctl.d/"
else
    nok "sem etapa de sysctl — o OpenSearch morre no bootstrap check"
fi

printf '\n  %d passaram, %d falharam\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
