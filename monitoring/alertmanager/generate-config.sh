#!/bin/sh
# Gera alertmanager.yml a partir de envs (destino = segredo do deploy).
# Alertmanager não expande env na config; webhook URL exige geração no start.
# Imagem busybox: POSIX sh apenas (sem bash/pipefail/arrays).
set -eu

CONF=/etc/alertmanager/alertmanager.yml

log() { printf 'alertmanager-config: %s\n' "$*"; }
die() { printf 'alertmanager-config: ERRO: %s\n' "$*" >&2; exit 1; }

# Destino obrigatório — Alertmanager sem receiver não sobe.
TEM_RECEIVER=false
if [ -n "${ALERTMANAGER_SLACK_WEBHOOK:-}" ]; then TEM_RECEIVER=true; fi
if [ -n "${ALERTMANAGER_WEBHOOK_URL:-}" ];   then TEM_RECEIVER=true; fi
if [ -n "${ALERTMANAGER_EMAIL_TO:-}" ];      then TEM_RECEIVER=true; fi

if [ "$TEM_RECEIVER" = false ]; then
    die "nenhum destino configurado. Defina ALERTMANAGER_SLACK_WEBHOOK, ALERTMANAGER_WEBHOOK_URL ou o par ALERTMANAGER_EMAIL_TO/ALERTMANAGER_SMTP_*. Um Alertmanager sem destino é o problema que este serviço existe para resolver."
fi

if [ -n "${ALERTMANAGER_EMAIL_TO:-}" ]; then
    [ -n "${ALERTMANAGER_SMTP_HOST:-}" ] || die "ALERTMANAGER_EMAIL_TO exige ALERTMANAGER_SMTP_HOST (host:porta)."
    [ -n "${ALERTMANAGER_EMAIL_FROM:-}" ] || die "ALERTMANAGER_EMAIL_TO exige ALERTMANAGER_EMAIL_FROM."
fi

# Cinco alertas legítimos durante carga mensal — silenciados na janela de ETL.
ETL_TZ="${ALERTMANAGER_ETL_TIMEZONE:-America/Sao_Paulo}"
ETL_DIAS_DO_MES="${ALERTMANAGER_ETL_DAYS_OF_MONTH:-1:7}"
ETL_DIA_DA_SEMANA="${ALERTMANAGER_ETL_WEEKDAY:-saturday}"
ETL_INICIO="${ALERTMANAGER_ETL_START:-00:00}"
ETL_FIM="${ALERTMANAGER_ETL_END:-07:00}"

RESOLVE_TIMEOUT="${ALERTMANAGER_RESOLVE_TIMEOUT:-10m}"
GROUP_WAIT="${ALERTMANAGER_GROUP_WAIT:-45s}"
GROUP_INTERVAL="${ALERTMANAGER_GROUP_INTERVAL:-5m}"
# 4h e não 30m: um alerta que se repete a cada meia hora é desligado pela
# operação em duas semanas. `critical` tem repetição própria, mais curta.
REPEAT_INTERVAL="${ALERTMANAGER_REPEAT_INTERVAL:-4h}"
REPEAT_CRITICAL="${ALERTMANAGER_REPEAT_CRITICAL:-1h}"

{
cat <<EOF
# ARQUIVO GERADO no start do container por generate-config.sh — não editar à
# mão: defina as envs ALERTMANAGER_* no deploy.

global:
  resolve_timeout: ${RESOLVE_TIMEOUT}
EOF

if [ -n "${ALERTMANAGER_SMTP_HOST:-}" ]; then
cat <<EOF
  smtp_smarthost: '${ALERTMANAGER_SMTP_HOST}'
  smtp_from: '${ALERTMANAGER_EMAIL_FROM}'
  smtp_require_tls: ${ALERTMANAGER_SMTP_TLS:-true}
EOF
if [ -n "${ALERTMANAGER_SMTP_USER:-}" ]; then
    printf "  smtp_auth_username: '%s'\n" "$ALERTMANAGER_SMTP_USER"
fi
if [ -n "${ALERTMANAGER_SMTP_PASSWORD:-}" ]; then
    printf "  smtp_auth_password: '%s'\n" "$ALERTMANAGER_SMTP_PASSWORD"
fi
fi

cat <<EOF

# Janelas em que alertas específicos NÃO são notificados. O alerta continua
# ativo e visível na interface — só não acorda ninguém.
time_intervals:
  - name: janela-de-etl
    time_intervals:
      - times:
          - start_time: '${ETL_INICIO}'
            end_time: '${ETL_FIM}'
        weekdays: ['${ETL_DIA_DA_SEMANA}']
        days_of_month: ['${ETL_DIAS_DO_MES}']
        location: '${ETL_TZ}'

route:
  # Agrupar por alertname E instance: sem o instance, dois hosts com o mesmo
  # problema viram uma notificação só e o segundo host passa despercebido.
  group_by: ['alertname', 'instance']
  group_wait: ${GROUP_WAIT}
  group_interval: ${GROUP_INTERVAL}
  repeat_interval: ${REPEAT_INTERVAL}
  receiver: padrao

  routes:
    # --- os cinco falsos positivos legítimos da carga mensal ---------------
    - matchers:
        - alertname=~"IOSaturado|CacheHitBaixo|MuitosArquivosTemporarios|CheckpointsForcadosDemais|PostgresConexoesPertoDoLimite"
      receiver: padrao
      mute_time_intervals:
        - janela-de-etl

    # --- crítico repete mais -----------------------------------------------
    - matchers:
        - severity="critical"
      receiver: critico
      repeat_interval: ${REPEAT_CRITICAL}
      # continue: false (default) — um alerta crítico não deve gerar também a
      # notificação padrão.

inhibit_rules:
  # Host fora do ar cala os alertas do que roda nele. Sem isto, uma máquina
  # caída gera uma dúzia de notificações que dizem a mesma coisa.
  - source_matchers: [alertname="AlvoForaDoAr"]
    target_matchers: [severity=~"warning|info"]
    equal: ['instance']

  # A sonda de disponibilidade cala as de latência do MESMO alvo: uma página
  # que não responde não tem p95 interessante.
  - source_matchers: [alertname="SondaFalhando"]
    target_matchers: [alertname=~"Slo.*Estourado"]
    equal: ['instance']

  # Crítico cala warning do mesmo alerta e do mesmo alvo.
  - source_matchers: [severity="critical"]
    target_matchers: [severity="warning"]
    equal: ['alertname', 'instance']

receivers:
EOF

emitir_destinos() {
    if [ -n "${ALERTMANAGER_SLACK_WEBHOOK:-}" ]; then
cat <<EOF
    slack_configs:
      - api_url: '${ALERTMANAGER_SLACK_WEBHOOK}'
        channel: '${ALERTMANAGER_SLACK_CHANNEL:-#alertas}'
        send_resolved: true
        title: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}'
        text: >-
          {{ range .Alerts }}{{ .Annotations.summary }}
          {{ if .Annotations.description }}{{ .Annotations.description }}{{ end }}
          {{ if .Labels.runbook }}runbook: {{ .Labels.runbook }}{{ end }}
          {{ end }}
EOF
    fi
    if [ -n "${ALERTMANAGER_WEBHOOK_URL:-}" ]; then
cat <<EOF
    webhook_configs:
      - url: '${ALERTMANAGER_WEBHOOK_URL}'
        send_resolved: true
EOF
    fi
    if [ -n "${ALERTMANAGER_EMAIL_TO:-}" ]; then
cat <<EOF
    email_configs:
      - to: '${ALERTMANAGER_EMAIL_TO}'
        send_resolved: true
        headers:
          Subject: '[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }} — {{ .CommonLabels.instance }}'
EOF
    fi
}

echo "  - name: padrao"
emitir_destinos
echo "  - name: critico"
emitir_destinos
} > "$CONF"

log "configuração gerada"
log "janela de ETL silenciada: ${ETL_DIA_DA_SEMANA} ${ETL_INICIO}-${ETL_FIM} (dias ${ETL_DIAS_DO_MES}, ${ETL_TZ})"

# `amtool check-config` valida ANTES de o Alertmanager tentar subir: a
# alternativa é um container em restart loop com o erro escondido no log.
amtool check-config "$CONF" >/dev/null \
    || { amtool check-config "$CONF"; die "a configuração gerada é inválida (acima)"; }
log "amtool check-config: ok"

exec "$@"
