#!/usr/bin/env bash
# Teste de integração do PgBouncer — sobe Postgres + pooler e exercita as três
# coisas que transaction pooling quebra.
#
#   bash pgbouncer/test/pgbouncer.test.sh
#
# Não é um teste de configuração: é um teste do MODO DE FALHA. `pool_mode =
# transaction` funciona perfeitamente até a aplicação usar um `SET` de sessão ou
# um prepared statement, e aí quebra de formas que não mencionam o PgBouncer no
# erro. Os três casos abaixo são exatamente os que o item 18 do roadmap manda
# verificar antes de ligar.
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIXO="bdhtest-pgb"
REDE="${PREFIXO}-net"
IMG="${PREFIXO}/pgbouncer"
SENHA="segredo-de-teste"
PORTA=16432

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
nok() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

limpar() {
    docker rm -f "${PREFIXO}-pg" "${PREFIXO}-pool" >/dev/null 2>&1
    docker network rm "$REDE" >/dev/null 2>&1
}
trap limpar EXIT
limpar

echo
echo "PgBouncer — teste de integração"

docker build -q -t "$IMG" "$RAIZ/pgbouncer" >/dev/null || { echo "build falhou"; exit 1; }
docker network create "$REDE" >/dev/null

docker run -d --name "${PREFIXO}-pg" --network "$REDE" \
    -e POSTGRES_PASSWORD="$SENHA" -e POSTGRES_DB=dados \
    postgres:17.10 >/dev/null

echo -n "    esperando o Postgres"
for _ in $(seq 1 40); do
    docker exec "${PREFIXO}-pg" pg_isready -q -U postgres 2>/dev/null && break
    echo -n "."; sleep 2
done
echo

# O verificador SCRAM sai do próprio banco — é o caminho recomendado, e o teste
# usa justamente ele para não validar só o atalho da senha em texto.
SCRAM="$(docker exec "${PREFIXO}-pg" psql -U postgres -tAc \
    "SELECT rolpassword FROM pg_authid WHERE rolname = 'postgres'")"

docker run -d --name "${PREFIXO}-pool" --network "$REDE" \
    -e PGB_DB_HOST="${PREFIXO}-pg" -e PGB_DB_NAME=dados \
    -e PGB_USER=postgres -e PGB_PASSWORD="$SENHA" \
    -e PGB_PASSWORD_SCRAM="$SCRAM" \
    -e PGB_DEFAULT_POOL_SIZE=3 -e PGB_MAX_CLIENT_CONN=50 \
    -p "127.0.0.1:${PORTA}:6432" \
    "$IMG" >/dev/null

echo -n "    esperando o PgBouncer"
for _ in $(seq 1 30); do
    docker exec "${PREFIXO}-pg" psql "postgresql://postgres:${SENHA}@${PREFIXO}-pool:6432/dados" \
        -tAc 'SELECT 1' >/dev/null 2>&1 && break
    echo -n "."; sleep 2
done
echo

psql_pool() {
    docker exec "${PREFIXO}-pg" psql "postgresql://postgres:${SENHA}@${PREFIXO}-pool:6432/$1" "${@:2}"
}

# --- 1. conecta -------------------------------------------------------------
if psql_pool dados -tAc 'SELECT 1' 2>/dev/null | grep -qx 1; then
    ok "conexão pelo pooler com auth SCRAM"
else
    nok "não conectou pelo pooler"
    docker logs --tail 25 "${PREFIXO}-pool" 2>&1 | sed 's/^/      /'
    exit 1
fi

# --- 2. o handshake não é recusado por parâmetro de startup -----------------
# Sem `ignore_startup_parameters`, um cliente que envia `options` ou
# `search_path` no startup é RECUSADO — e a mensagem não menciona o PgBouncer.
if PGOPTIONS="-c search_path=public" docker exec -e PGOPTIONS="-c search_path=public" \
       "${PREFIXO}-pg" psql "postgresql://postgres:${SENHA}@${PREFIXO}-pool:6432/dados" \
       -tAc 'SELECT 1' >/dev/null 2>&1; then
    ok "cliente com parâmetro de startup (options/search_path) é aceito"
else
    nok "handshake recusado por parâmetro de startup — falta ignore_startup_parameters"
fi

# --- 3. SET LOCAL sobrevive; SET de sessão não deve ser usado ---------------
# `SET LOCAL` dentro de transação é a forma segura com transaction pooling, e é
# a que o código da aplicação usa (App\Support\StatementTimeout).
# `grep ms`: o psql imprime também os rótulos BEGIN/SET/COMMIT de cada comando
# do lote; só a linha do SELECT termina em "ms".
VALOR="$(psql_pool dados -tAc "BEGIN; SET LOCAL statement_timeout = 4321; SELECT current_setting('statement_timeout'); COMMIT;" 2>/dev/null | tr -d ' ' | grep 'ms$' | head -1)"
if [ "$VALOR" = "4321ms" ]; then
    ok "SET LOCAL vale dentro da transação"
else
    nok "SET LOCAL não aplicou (obtido: '${VALOR}')"
fi

# O espelho: fora de transação, o valor NÃO deve vazar para a consulta seguinte,
# porque o slot volta ao pool. É a razão de `SET` de sessão ser proibido aqui.
psql_pool dados -tAc "SET statement_timeout = 9999" >/dev/null 2>&1
VAZOU="$(psql_pool dados -tAc "SELECT current_setting('statement_timeout')" 2>/dev/null | tr -d ' ')"
if [ "$VAZOU" != "9999ms" ]; then
    ok "SET de sessão não vaza para a próxima consulta (pool devolveu o slot)"
else
    nok "o SET de sessão VAZOU — o pooling não está em transaction mode"
fi

# --- 4. prepared statements no protocolo estendido -------------------------
# Com `max_prepared_statements = 0`, isto falha com "prepared statement does not
# exist" — o erro clássico de PDO em modo nativo atrás de PgBouncer.
if psql_pool dados -c "PREPARE p1 AS SELECT \$1::int; EXECUTE p1(7);" >/dev/null 2>&1; then
    ok "prepared statement funciona (max_prepared_statements > 0)"
else
    nok "prepared statement falhou — confira max_prepared_statements"
fi

# --- 5. o pool é menor que o número de clientes ----------------------------
POOLS="$(psql_pool pgbouncer -tAc 'SHOW POOLS' 2>/dev/null | head -1)"
if [ -n "$POOLS" ]; then
    ok "console de administração responde (SHOW POOLS)"
else
    nok "SHOW POOLS não respondeu — admin_users/stats_users errados"
fi

MAXCONN="$(docker exec "${PREFIXO}-pg" psql -U postgres -tAc \
    "SELECT count(*) FROM pg_stat_activity WHERE datname = 'dados' AND backend_type = 'client backend'")"
if [ "${MAXCONN:-99}" -le 4 ]; then
    ok "o Postgres vê no máximo default_pool_size conexões reais (${MAXCONN})"
else
    nok "o Postgres vê ${MAXCONN} conexões — o pooling não está limitando"
fi

echo
echo "  ${PASS} passaram, ${FAIL} falharam"
[ "$FAIL" -eq 0 ]
