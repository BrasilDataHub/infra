#!/bin/sh
# Gera /etc/pgbouncer/pgbouncer.ini e o userlist a partir de variáveis PG_*.
#
# POSIX sh: a imagem do PgBouncer é Alpine e não tem bash.
#
# Mesma divisão dos demais módulos: a política de pooling é decisão de projeto e
# vive aqui; o dimensionamento e o segredo vêm do deploy.
set -eu

CONF=/etc/pgbouncer/pgbouncer.ini
USERLIST=/etc/pgbouncer/userlist.txt

log() { printf 'pgbouncer-config: %s\n' "$*"; }
die() { printf 'pgbouncer-config: ERRO: %s\n' "$*" >&2; exit 1; }

[ -n "${PGB_DB_HOST:-}" ] || die "defina PGB_DB_HOST (host do Postgres)"
[ -n "${PGB_DB_NAME:-}" ] || die "defina PGB_DB_NAME"
[ -n "${PGB_USER:-}" ]    || die "defina PGB_USER"
[ -n "${PGB_PASSWORD:-}" ] || die "defina PGB_PASSWORD"

POOL_MODE="${PGB_POOL_MODE:-transaction}"

# ---------------------------------------------------------------------------
# A conta que dimensiona este serviço
# ---------------------------------------------------------------------------
# `default_pool_size` é o número de conexões REAIS ao Postgres por par
# (database, usuário). Ele é o multiplicador de `work_mem` no pior caso, e por
# isso não pode ser escolhido por conforto:
#
#     default_pool_size × work_mem  ≤  memória disponível para sorts
#              20       ×   96 MB   =  1,9 GB   ✔ dentro dos 14 GiB do perfil
#
# `max_client_conn` é outra coisa inteiramente: são conexões do LADO CLIENTE,
# que custam ~2 KB cada no PgBouncer e nada no Postgres. 400 clientes sobre 20
# conexões reais é exatamente o ponto do pooler.
DEFAULT_POOL_SIZE="${PGB_DEFAULT_POOL_SIZE:-20}"
MAX_CLIENT_CONN="${PGB_MAX_CLIENT_CONN:-400}"
MIN_POOL_SIZE="${PGB_MIN_POOL_SIZE:-5}"
RESERVE_POOL_SIZE="${PGB_RESERVE_POOL_SIZE:-5}"

case "$POOL_MODE" in
    transaction|session|statement) : ;;
    *) die "PGB_POOL_MODE inválido: $POOL_MODE (transaction|session|statement)" ;;
esac

# ---------------------------------------------------------------------------
# Bancos adicionais no MESMO servidor
# ---------------------------------------------------------------------------
# Uma aplicação com mais de um banco no mesmo Postgres precisa de uma entrada
# por banco: o PgBouncer roteia pelo `dbname` que o cliente pede no handshake,
# e um banco ausente daqui é recusado com "no such database".
#
# Cada par (database, usuário) tem pool PRÓPRIO de `default_pool_size`
# conexões — dois bancos com um usuário cada são 2 × 20 = 40 conexões reais no
# pior caso. Confira contra o `max_connections` do servidor antes de crescer.
#
#   PGB_EXTRA_DATABASES="baseempresarial;outra_base"          (mesmo host)
#   PGB_EXTRA_DATABASES="baseempresarial;relatorios=10.0.1.20" (host próprio)
BANCOS_EXTRA=""
if [ -n "${PGB_EXTRA_DATABASES:-}" ]; then
    OLD_IFS="$IFS"; IFS=';'
    for entrada in $PGB_EXTRA_DATABASES; do
        entrada="$(printf '%s' "$entrada" | tr -d ' ')"
        [ -n "$entrada" ] || continue
        nome="${entrada%%=*}"
        host="${entrada#*=}"
        [ "$host" != "$entrada" ] || host="$PGB_DB_HOST"
        BANCOS_EXTRA="${BANCOS_EXTRA}${nome} = host=${host} port=${PGB_DB_PORT:-5432} dbname=${nome}
"
    done
    IFS="$OLD_IFS"
fi

cat > "$CONF" <<EOF
; ARQUIVO GERADO no start do container por generate-config.sh — não editar à
; mão: defina as envs PGB_* no deploy.

[databases]
${PGB_DB_NAME} = host=${PGB_DB_HOST} port=${PGB_DB_PORT:-5432} dbname=${PGB_DB_NAME}
${BANCOS_EXTRA}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = ${PGB_LISTEN_PORT:-6432}

auth_type = scram-sha-256
auth_file = ${USERLIST}

; Aspas simples nos comentários abaixo, e não crase: este bloco é um heredoc
; NÃO-quotado (precisa expandir as variáveis), e ali a crase inicia substituição
; de comando — 'SET' virou uma tentativa de executar o comando SET.
; ---------------------------------------------------------------------------
; transaction pooling: a conexão real volta ao pool a cada COMMIT.
;
; É o que permite 400 clientes sobre 20 conexões — e é também o que QUEBRA duas
; coisas, que precisam ser verificadas na aplicação antes de ligar:
;
;   1. 'SET' de sessão. Um 'SET work_mem' fora de transação vale para a
;      próxima conexão que pegar aquele slot, que é de outro cliente. O código
;      desta operação usa 'SET LOCAL' dentro de transação
;      (App\\Support\\StatementTimeout), que é seguro — mas qualquer 'SET'
;      novo precisa seguir a mesma regra. O 'server_reset_query_always' abaixo
;      é a rede de segurança para quando alguém não seguir.
;   2. Prepared statements no protocolo estendido. O PgBouncer 1.21+ os
;      suporta com 'max_prepared_statements' > 0; com 0, o PDO do PHP em modo
;      nativo falha com "prepared statement does not exist".
; ---------------------------------------------------------------------------
pool_mode = ${POOL_MODE}
max_client_conn = ${MAX_CLIENT_CONN}
default_pool_size = ${DEFAULT_POOL_SIZE}
min_pool_size = ${MIN_POOL_SIZE}
reserve_pool_size = ${RESERVE_POOL_SIZE}
reserve_pool_timeout = ${PGB_RESERVE_POOL_TIMEOUT:-3}

; Sem isto, transaction pooling e PDO em modo nativo são incompatíveis. 200 é
; folgado para o conjunto de consultas desta aplicação e custa memória no
; PgBouncer, não no banco.
max_prepared_statements = ${PGB_MAX_PREPARED_STATEMENTS:-200}

; Fecha conexão de servidor ociosa: um slot preso é um slot a menos para o
; pico, e o Postgres cobra memória por backend mesmo ocioso.
server_idle_timeout = ${PGB_SERVER_IDLE_TIMEOUT:-600}
; Recicla a conexão real periodicamente — evita que um backend acumule cache de
; catálogo e memória de sessão pelo resto do mês.
server_lifetime = ${PGB_SERVER_LIFETIME:-3600}

; ---------------------------------------------------------------------------
; A guarda contra vazamento de estado entre CLIENTES DIFERENTES.
;
; Em transaction pooling, um 'SET' fora de transação é enviado como transação
; implícita e aplicado à conexão de servidor do momento — e NÃO é desfeito.
; O próximo cliente que pegar aquele slot herda a configuração de outro
; visitante. Foi verificado no teste de integração: sem estas duas linhas, um
; 'SET statement_timeout = 9999' feito por um cliente aparece no
; 'current_setting' de outro.
;
; 'server_reset_query_always = 1' é o que faz o DISCARD ALL rodar também em
; transaction mode (por default ele só roda em session mode). Custa um
; round-trip por transação e nenhuma IO — barato perto de um vazamento de
; estado silencioso entre requisições de usuários distintos.
; ---------------------------------------------------------------------------
server_reset_query = DISCARD ALL
server_reset_query_always = ${PGB_SERVER_RESET_ALWAYS:-1}

; Espera máxima na fila do pool antes de devolver erro ao cliente. Sem teto, uma
; consulta lenta segurando o pool transforma degradação em travamento — e o
; cliente fica esperando sem saber por quê.
query_wait_timeout = ${PGB_QUERY_WAIT_TIMEOUT:-30}

; 'ignore_startup_parameters': o cliente PHP envia parâmetros que o PgBouncer
; não repassa em transaction pooling. Sem esta linha, a conexão é RECUSADA no
; handshake com "unsupported startup parameter" — e o erro não menciona o
; PgBouncer, o que torna o diagnóstico caro.
ignore_startup_parameters = extra_float_digits,options,search_path

; Administração e métricas ('SHOW POOLS', 'SHOW STATS') restritas ao usuário
; da aplicação; não há usuário de admin separado porque não há console exposto.
admin_users = ${PGB_USER}
stats_users = ${PGB_USER}

log_connections = ${PGB_LOG_CONNECTIONS:-0}
log_disconnections = ${PGB_LOG_DISCONNECTIONS:-0}
log_pooler_errors = 1
EOF

# `auth_file` com a senha em SCRAM. Gerar o verificador exige o Postgres, então
# o caminho suportado é receber o hash pronto (PGB_PASSWORD_SCRAM) ou usar a
# senha em texto — que o PgBouncer aceita e converte no handshake.
if [ -n "${PGB_PASSWORD_SCRAM:-}" ]; then
    printf '"%s" "%s"\n' "$PGB_USER" "$PGB_PASSWORD_SCRAM" > "$USERLIST"
else
    log "AVISO: usando senha em texto no userlist. Para SCRAM, extraia o verificador com:"
    log "  SELECT rolpassword FROM pg_authid WHERE rolname = '${PGB_USER}';"
    log "  e passe em PGB_PASSWORD_SCRAM."
    printf '"%s" "%s"\n' "$PGB_USER" "$PGB_PASSWORD" > "$USERLIST"
fi

# ---------------------------------------------------------------------------
# Usuários adicionais
# ---------------------------------------------------------------------------
# O PgBouncer autentica o CLIENTE contra este arquivo e reabre a conexão de
# servidor com o mesmo usuário. Um usuário ausente daqui é recusado no
# handshake — e o erro não menciona o userlist.
#
# É o que permite manter o privilégio da aplicação: sem a entrada de
# `dados_read`, a única saída seria apontar a conexão de leitura para o
# superusuário, trocando um pooler por uma escalação de privilégio.
#
#   PGB_EXTRA_USERS="dados_read=senha;relatorios=outra"
#
# Senha com `;` ou `=` não passa por aqui — use PGB_PASSWORD_SCRAM para o
# usuário principal e mantenha os extras com senhas alfanuméricas.
if [ -n "${PGB_EXTRA_USERS:-}" ]; then
    OLD_IFS="$IFS"; IFS=';'
    for entrada in $PGB_EXTRA_USERS; do
        [ -n "$entrada" ] || continue
        usuario="${entrada%%=*}"
        senha="${entrada#*=}"
        [ -n "$usuario" ] && [ "$senha" != "$entrada" ] \
            || die "PGB_EXTRA_USERS: entrada inválida '${usuario}' (use usuario=senha)"
        printf '"%s" "%s"\n' "$usuario" "$senha" >> "$USERLIST"
        log "usuário adicional no userlist: ${usuario}"
    done
    IFS="$OLD_IFS"
fi

chmod 0600 "$USERLIST"

log "pool_mode=${POOL_MODE} default_pool_size=${DEFAULT_POOL_SIZE} max_client_conn=${MAX_CLIENT_CONN}"
log "pior caso de sort no banco: ${DEFAULT_POOL_SIZE} × work_mem"

exec "$@"
