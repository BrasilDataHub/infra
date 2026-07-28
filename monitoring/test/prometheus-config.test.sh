#!/usr/bin/env bash
# Testes da configuração do Prometheus e dos dashboards do Grafana.
# Rodar: bash monitoring/test/prometheus-config.test.sh
#
# Roda na CI ANTES de publicar as imagens, pelo mesmo motivo do
# shm-guard.test.sh: config inválida só se manifestaria como container em
# restart loop no servidor, e um dashboard com datasource errado abre VAZIO sem
# erro nenhum — ninguém percebe até precisar dele.
#
# Precisa de Docker (usa o promtool da imagem oficial) e de jq.
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
PROM_IMAGE="prom/prometheus:v3.13.1"
PASS=0; FAIL=0

ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
nok()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# Roda o promtool com o diretório do módulo montado em /w. Via `sh -c` para que
# os globs sejam expandidos DENTRO do container: expandidos no host, dependeriam
# do diretório de onde o teste foi invocado (e o teste roda tanto da raiz do
# repositório quanto de monitoring/).
promtool() {
    docker run --rm -v "$RAIZ:/w:ro" -w /w --entrypoint sh "$PROM_IMAGE" -c "promtool $*"
}

echo
echo "Configuração do Prometheus"

# O credentials_file do job do Meilisearch precisa existir, senão o Prometheus
# recusa a config INTEIRA — e um host sem Meilisearch ficaria sem monitoração
# nenhuma. O placeholder vive na imagem; aqui simulamos o mesmo.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/secrets" "$TMP/targets"
touch "$TMP/secrets/meili-metrics.key"
# O caminho reescrito é o de DENTRO do container (/t/secrets), não o do host.
sed 's#/etc/prometheus/secrets/#/t/secrets/#' "$RAIZ/prometheus/prometheus.yml" > "$TMP/prometheus.yml"
# `mktemp -d` cria 0700, e a imagem do Prometheus roda como `nobody`: no Linux o
# container nem atravessa o diretório, e o promtool devolve "permission denied"
# — que este teste reportava como "prometheus.yml inválido". No macOS o bind
# mount ignora as permissões do host, então o erro só aparecia na CI.
chmod -R a+rX "$TMP"

if docker run --rm -v "$TMP:/t" -v "$RAIZ:/w:ro" --entrypoint promtool "$PROM_IMAGE" \
     check config /t/prometheus.yml >/dev/null 2>&1; then
    ok "prometheus.yml é válido"
else
    nok "prometheus.yml inválido — rode: promtool check config"
fi

if promtool check rules prometheus/rules/*.yml >/dev/null 2>&1; then
    ok "regras de alerta são válidas"
else
    nok "regras de alerta inválidas — rode: promtool check rules"
fi

if docker run --rm -v "$RAIZ:/w:ro" -w /w/test --entrypoint promtool "$PROM_IMAGE" \
     test rules alertas.test.yml >/dev/null 2>&1; then
    ok "testes unitários dos alertas passam"
else
    nok "testes unitários dos alertas falharam — rode: promtool test rules"
fi

# Todo job de SERVIÇO usa file_sd: é o que faz um serviço não instalado ficar SEM
# ALVO em vez de ficar `up == 0` para sempre, envenenando o alerta que mais
# importa.
#
# Três exceções, todas com o mesmo argumento — o alvo vive no MESMO projeto
# Compose que o Prometheus, então ou os dois existem ou nenhum existe:
#   1. o job `prometheus` (127.0.0.1, responde mesmo com a rede doente);
#   2. o job `alertmanager`;
#   3. o bloco `alerting.alertmanagers`, que é destino e não alvo.
estaticos="$(grep -c 'static_configs' "$RAIZ/prometheus/prometheus.yml")"
if [ "$estaticos" -eq 3 ]; then
    ok "só prometheus e alertmanager são estáticos; o resto usa file_sd"
else
    nok "há $estaticos static_configs (esperado 3) — jobs de serviço devem usar file_sd_configs"
fi

# A verificação acima é de contagem e envelheceria mal sozinha. Esta é a que
# realmente importa: nenhum job de serviço pode ter alvo estático.
for job in node postgres redis meilisearch cadvisor blackbox opensearch; do
    trecho="$(awk -v j="$job" '
        $0 ~ "^  - job_name: "j"$" {dentro=1; next}
        /^  - job_name:/ {dentro=0}
        dentro {print}
    ' "$RAIZ/prometheus/prometheus.yml")"
    if [ -z "$trecho" ]; then
        nok "job $job sumiu do prometheus.yml"
    elif printf '%s' "$trecho" | grep -q 'static_configs'; then
        nok "job $job usa static_configs — um host sem esse serviço ficaria up == 0 para sempre"
    else
        ok "job $job usa file_sd"
    fi
done

# O job do blackbox só funciona com os quatro relabels: sem o primeiro, o
# Prometheus tentaria coletar métricas da PÁGINA em vez de sondá-la.
for campo in __param_target __param_module blackbox-exporter:9115; do
    if grep -q "$campo" "$RAIZ/prometheus/prometheus.yml"; then
        ok "relabel do blackbox tem $campo"
    else
        nok "relabel do blackbox sem $campo — as sondas não funcionariam"
    fi
done

# O destino dos alertas. Antes deste roadmap, 18 regras eram avaliadas e não
# iam a lugar nenhum; sem este bloco, voltariam a não ir.
if grep -q 'alertmanagers:' "$RAIZ/prometheus/prometheus.yml"; then
    ok "há um Alertmanager configurado como destino dos alertas"
else
    nok "nenhum alertmanager em alerting: — as regras seriam avaliadas sem destino"
fi

# A chave do Meilisearch entra por credentials_file. Se alguém trocar por
# `credentials:` inline, o segredo passa a viver na IMAGEM publicada.
if grep -qE '^\s+credentials:' "$RAIZ/prometheus/prometheus.yml"; then
    nok "há credencial INLINE no prometheus.yml — use credentials_file"
else
    ok "nenhuma credencial inline na config (só credentials_file)"
fi

echo
echo "Alertmanager e blackbox_exporter"

# `amtool check-config` já roda no entrypoint da imagem; aqui o que se valida é
# a regra de negócio: o container tem de RECUSAR subir sem destino. Um
# Alertmanager silencioso reproduz exatamente o estado que ele veio corrigir.
docker build -q -t bdh-test/alertmanager "$RAIZ/alertmanager" >/dev/null 2>&1
if docker run --rm --entrypoint /usr/local/bin/generate-config.sh \
       bdh-test/alertmanager true >/dev/null 2>&1; then
    nok "o Alertmanager subiu SEM destino configurado"
else
    ok "o Alertmanager recusa subir sem destino"
fi

if docker run --rm -e ALERTMANAGER_WEBHOOK_URL=https://exemplo.invalido/hook \
       --entrypoint /usr/local/bin/generate-config.sh \
       bdh-test/alertmanager true >/dev/null 2>&1; then
    ok "a configuração gerada passa no amtool check-config"
else
    nok "a configuração gerada é inválida — rode o entrypoint à mão para ver o erro"
fi

# A janela de ETL precisa estar na config gerada, senão os cinco falsos
# positivos legítimos da carga mensal acordam alguém toda madrugada de D0.
if docker run --rm -e ALERTMANAGER_WEBHOOK_URL=https://exemplo.invalido/hook \
       --entrypoint /usr/local/bin/generate-config.sh bdh-test/alertmanager \
       sh -c 'cat /etc/alertmanager/alertmanager.yml' 2>/dev/null \
     | grep -q 'mute_time_intervals'; then
    ok "a janela de silenciamento do ETL está na configuração gerada"
else
    nok "sem mute_time_intervals — os 5 alertas da carga mensal notificariam"
fi

docker build -q -t bdh-test/blackbox "$RAIZ/blackbox" >/dev/null 2>&1
if docker run --rm --entrypoint blackbox_exporter bdh-test/blackbox \
       --config.file=/etc/blackbox_exporter/config.yml --config.check >/dev/null 2>&1; then
    ok "blackbox.yml é válido"
else
    nok "blackbox.yml inválido"
fi

# Uma sonda por classe de SLO (05 §9.2). Se um módulo sumir, a classe fica sem
# medição e o alerta correspondente nunca avalia nada.
for modulo in borda_hit condicional_304 empresa_por_cnpj hub_territorial \
              autocomplete busca anonima_sem_cookie; do
    if grep -q "^  ${modulo}:" "$RAIZ/blackbox/blackbox.yml"; then
        ok "módulo $modulo presente"
    else
        nok "módulo $modulo ausente — a classe de SLO ficaria sem sonda"
    fi
done

echo
echo "Dashboards do Grafana"

for f in "$RAIZ"/grafana/dashboards/*.json; do
    nome="$(basename "$f")"

    if ! jq empty "$f" >/dev/null 2>&1; then
        nok "$nome — JSON inválido"
        continue
    fi

    # __inputs/${DS_...} são resolvidos APENAS pelo import interativo. No
    # provisioning por arquivo, o painel aponta para um datasource inexistente e
    # o dashboard abre em branco, sem erro.
    # shellcheck disable=SC2016  # o literal procurado é '${DS_', não uma expansão
    if grep -q '\${DS_' "$f" || jq -e '.__inputs' "$f" >/dev/null 2>&1; then
        nok "$nome — sobrou __inputs/\${DS_...}; rode grafana/vendorizar.sh"
        continue
    fi

    if [ "$(jq -r '.uid // empty' "$f")" = "" ]; then
        nok "$nome — sem uid fixo (a URL do dashboard mudaria a cada deploy)"
        continue
    fi

    # Toda referência de datasource precisa apontar para o uid provisionado.
    # Exceções legítimas: "grafana" é o datasource embutido (-- Grafana --),
    # usado por painéis de anotação e de texto; e "$..." são variáveis de
    # template do próprio dashboard.
    outros="$(jq -r '[.. | objects | select(has("datasource")) | .datasource
                      | select(type == "object") | .uid // empty
                      | select(. != "bdh-prometheus" and . != "grafana"
                               and (startswith("$") | not))]
                     | length' "$f" 2>/dev/null || echo 0)"
    if [ "${outros:-0}" -ne 0 ]; then
        nok "$nome — $outros referência(s) a datasource diferente de bdh-prometheus"
        continue
    fi

    ok "$nome — provisionável ($(jq -r '.uid' "$f"))"
done

echo
echo "Perfis"

for p in "$RAIZ"/profiles/*.env; do
    nome="$(basename "$p")"
    faltando=""
    for chave in PROM_RETENTION_TIME PROM_RETENTION_SIZE PROM_MEMORY_LIMIT GRAFANA_MEMORY_LIMIT; do
        grep -qE "^${chave}=" "$p" || faltando="$faltando $chave"
    done
    if [ -n "$faltando" ]; then
        # Retenção por tempo sem retenção por tamanho é o furo clássico: um pico
        # de cardinalidade enche o disco que o Postgres divide com o Prometheus.
        nok "$nome — faltam:$faltando"
    else
        ok "$nome — completo"
    fi
done

echo
echo "  $PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
