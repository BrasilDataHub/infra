#!/usr/bin/env bash
# Cria (ou lê) a chave de API do Meilisearch usada pelo Prometheus para coletar
# /metrics, e imprime o valor da chave no stdout.
#
#   MEILI_MASTER_KEY=... bash metrics-key.sh [URL]
#   # URL default: http://127.0.0.1:7700
#
# A chave tem UMA ação — `metrics.get` — e não dá acesso a índice nenhum. A
# master key é usada só aqui, uma vez, e nunca chega ao Prometheus.
#
# IDEMPOTENTE por construção: a chave é criada com um `uid` FIXO (um UUID v4
# constante, versionado neste arquivo). Na primeira vez o POST cria; nas
# seguintes ele responde 409 e o GET devolve a chave existente. Isso evita a
# alternativa frágil de listar todas as chaves e filtrar por descrição.
#
# É o que o `infra-setup.sh --metrics` executa. Também serve para rodar à mão
# quando o Meilisearch está noutra máquina.
set -euo pipefail

MEILI_URL="${1:-${MEILI_URL:-http://127.0.0.1:7700}}"
: "${MEILI_MASTER_KEY:?defina MEILI_MASTER_KEY}"

# UUID fixo — não gere um novo: é ele que torna o script idempotente.
KEY_UID="8c3f1d2e-7b4a-4c9e-9f21-6264686d6574"

# 409 (já existe) é sucesso aqui; qualquer outro erro cai no GET abaixo, que
# falha com mensagem clara se a chave realmente não existir.
curl -fsS -X POST "${MEILI_URL}/keys" \
    -H "Authorization: Bearer ${MEILI_MASTER_KEY}" \
    -H 'Content-Type: application/json' \
    -d "{
          \"uid\": \"${KEY_UID}\",
          \"name\": \"prometheus\",
          \"description\": \"scrape de /metrics pelo Prometheus (infra/monitoring) — só métricas, nenhum dado\",
          \"actions\": [\"metrics.get\"],
          \"indexes\": [\"*\"],
          \"expiresAt\": null
        }" >/dev/null 2>&1 || true

curl -fsS "${MEILI_URL}/keys/${KEY_UID}" \
    -H "Authorization: Bearer ${MEILI_MASTER_KEY}" \
    | sed -n 's/.*"key":"\([^"]*\)".*/\1/p'
