#!/usr/bin/env bash
# Teste de integração do módulo OpenSearch — sobe o nó de verdade e afirma as
# decisões que são IMUTÁVEIS SEM REINDEXAR.
#
#   bash opensearch/test/opensearch.test.sh
#
# Três escolhas do mapping não podem ser alteradas depois sem refazer os 72,32
# milhões de documentos: `number_of_shards`, `_source: false` e
# `auto_expand_replicas`. Um teste que rode antes do primeiro `_bulk` custa
# segundos; descobrir o mesmo erro depois custa a reindexação inteira.
#
# O teste também exercita os analisadores com texto real de razão social, que é
# onde as decisões de produto vivem: `LTDA` aparece em ~70% dos documentos, e é
# a stopword que mata os 687 ms medidos no Meilisearch.
set -uo pipefail

RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIXO="bdhtest-os"
IMG="${PREFIXO}/opensearch"
PORTA=19200
INDICE=busca_estabelecimento

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
nok() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

limpar() { docker rm -f "${PREFIXO}-node" >/dev/null 2>&1; }
trap limpar EXIT
limpar

echo
echo "OpenSearch — teste de integração"

docker build -q -t "$IMG" "$RAIZ/opensearch" >/dev/null || { echo "build falhou"; exit 1; }

# Heap pequeno: o teste não indexa volume, só valida contratos. 512m sobe em
# ~30s contra os ~90s de um heap de 4 GiB.
docker run -d --name "${PREFIXO}-node" \
    -e discovery.type=single-node \
    -e DISABLE_SECURITY_PLUGIN=true \
    -e DISABLE_INSTALL_DEMO_CONFIG=true \
    -e OPENSEARCH_JAVA_OPTS="-Xms512m -Xmx512m" \
    -e indices.breaker.fielddata.limit=0% \
    --ulimit memlock=-1:-1 --ulimit nofile=65536:65536 \
    -p "127.0.0.1:${PORTA}:9200" \
    "$IMG" >/dev/null

echo -n "    esperando o nó"
for _ in $(seq 1 60); do
    curl -fs "http://127.0.0.1:${PORTA}/_cluster/health" >/dev/null 2>&1 && break
    echo -n "."; sleep 3
done
echo

api() { curl -fs -X "$1" "http://127.0.0.1:${PORTA}${2}" -H 'Content-Type: application/json' ${3:+-d "$3"}; }

if api GET /_cluster/health | grep -q '"status"'; then
    ok "o nó subiu e responde"
else
    nok "o nó não respondeu"
    docker logs --tail 30 "${PREFIXO}-node" 2>&1 | sed 's/^/      /'
    exit 1
fi

# --- criação do índice com o mapping versionado -----------------------------
if curl -fs -X PUT "http://127.0.0.1:${PORTA}/${INDICE}" \
     -H 'Content-Type: application/json' \
     --data-binary "@${RAIZ}/opensearch/index/busca_estabelecimento.json" >/dev/null 2>&1; then
    ok "o índice foi criado com o mapping versionado"
else
    nok "o mapping foi RECUSADO pelo OpenSearch"
    curl -s -X PUT "http://127.0.0.1:${PORTA}/${INDICE}" -H 'Content-Type: application/json' \
      --data-binary "@${RAIZ}/opensearch/index/busca_estabelecimento.json" | head -5 | sed 's/^/      /'
    exit 1
fi

CFG="$(api GET "/${INDICE}/_settings")"
MAP="$(api GET "/${INDICE}/_mapping")"

# --- as três decisões imutáveis ---------------------------------------------
if printf '%s' "$CFG" | grep -q '"number_of_shards":"6"'; then
    ok "6 shards — imutável sem reindexar"
else
    nok "number_of_shards != 6"
fi
if printf '%s' "$CFG" | grep -q '"auto_expand_replicas":"0-1"'; then
    ok "auto_expand_replicas 0-1 — o cluster fica GREEN com um nó só"
else
    nok "auto_expand_replicas ausente: o cluster ficaria YELLOW para sempre e o alerta de saúde perderia significado"
fi
if printf '%s' "$MAP" | grep -q '"_source":{"enabled":false}'; then
    ok "_source desabilitado — é o que leva o índice de 138 para 8,4 GB"
else
    nok "_source habilitado: o índice não caberia no page cache"
fi

# --- o resto do contrato ----------------------------------------------------
if printf '%s' "$MAP" | grep -q '"dynamic":"strict"'; then
    ok "dynamic strict — coluna renomeada no pipeline FALHA o bulk"
else
    nok "dynamic não é strict: uma coluna renomeada criaria campo silencioso"
fi
if printf '%s' "$CFG" | grep -q '"max_result_window":"10000"'; then
    ok "max_result_window em 10000 (a saída para profundidade é search_after)"
else
    nok "max_result_window fora de 10000"
fi
if printf '%s' "$CFG" | grep -q '"max_thread_count":"1"'; then
    ok "1 thread de merge por shard em regime"
else
    nok "merge.scheduler.max_thread_count != 1 — até 24 threads na NVMe do Postgres"
fi

CAMPOS="$(printf '%s' "$MAP" | tr ',' '\n' | grep -c '"type":"keyword"')"
if [ "$CAMPOS" -gt 10 ]; then
    ok "campos keyword presentes (${CAMPOS} ocorrências)"
else
    nok "mapping parece incompleto"
fi

# --- os analisadores, que são decisão de PRODUTO ---------------------------
# `LTDA` em ~70% dos 72,32 M documentos: sua postings list é praticamente o
# índice inteiro. Removê-lo é o que faz `q=COMERCIO DE ALIMENTOS LTDA` custar o
# mesmo que sem o LTDA.
TOKENS="$(api POST "/${INDICE}/_analyze" \
    '{"analyzer":"br_corporativo","text":"COMERCIO DE ALIMENTOS LTDA"}' | tr ',' '\n' | grep '"token"' | sed 's/.*"token":"//;s/".*//' | tr '\n' ' ')"
if printf '%s' "$TOKENS" | grep -qv 'ltda' && printf '%s' "$TOKENS" | grep -q 'comercio'; then
    ok "br_corporativo remove LTDA e 'de' — tokens: ${TOKENS}"
else
    nok "o analisador não removeu a forma jurídica — tokens: ${TOKENS}"
fi

# asciifolding é o que espelha o `unaccent(upper(...))` que o ETL já faz.
ACENTO="$(api POST "/${INDICE}/_analyze" \
    '{"analyzer":"br_corporativo","text":"CONSTRUÇÃO"}' | sed 's/.*"token":"//;s/".*//')"
if [ "$ACENTO" = "construcao" ]; then
    ok "asciifolding normaliza acento (CONSTRUÇÃO → construcao)"
else
    nok "acento não normalizado (obtido: '${ACENTO}')"
fi

# Sinônimo só em BUSCA: 'ind' casa 'industria' no analisador de busca…
SIN="$(api POST "/${INDICE}/_analyze" \
    '{"analyzer":"br_corporativo_busca","text":"ind"}' | tr ',' '\n' | grep -c '"token"')"
if [ "$SIN" -ge 2 ]; then
    ok "sinônimos aplicados no analisador de BUSCA (ind → industria)"
else
    nok "sinônimos não aplicados na busca"
fi
# …e NÃO no de indexação, que é o que permite editar a lista sem reindexar.
SIN_IDX="$(api POST "/${INDICE}/_analyze" \
    '{"analyzer":"br_corporativo","text":"ind"}' | tr ',' '\n' | grep -c '"token"')"
if [ "$SIN_IDX" -eq 1 ]; then
    ok "sinônimos NÃO entram na indexação — editá-los não exige reindexar"
else
    nok "sinônimos aplicados na indexação: cada linha nova custaria uma reindexação de 72 M docs"
fi

# A regra que derrubou a criação do índice na primeira tentativa: nenhum termo
# da lista de sinônimos pode ser stopword do MESMO analisador. Ele chega vazio
# ao synonym_graph e o OpenSearch recusa o índice inteiro com
# "Failed to build synonyms" — não a consulta, o índice.
COLISOES=0
STOPWORDS="de da do das dos e em a o as os para com por no na ltda me epp eireli sa s mei ss cia ei limitada microempresa"
while read -r linha; do
    case "$linha" in ''|'#'*) continue ;; esac
    termo="${linha%%,*}"
    termo="$(printf '%s' "$termo" | tr -d ' ')"
    for sw in $STOPWORDS; do
        [ "$termo" = "$sw" ] && { echo "      colisão: '$termo' é sinônimo E stopword"; COLISOES=$((COLISOES+1)); }
    done
done < "$RAIZ/opensearch/index/razao_social_sinonimos.txt"
if [ "$COLISOES" -eq 0 ]; then
    ok "nenhum sinônimo colide com stopword (senão o índice nem é criado)"
else
    nok "${COLISOES} sinônimo(s) colidem com stopword"
fi

# --- dynamic: strict na prática --------------------------------------------
if curl -fs -X POST "http://127.0.0.1:${PORTA}/${INDICE}/_doc/1" \
     -H 'Content-Type: application/json' \
     -d '{"cnpj_completo":"00000000000191","campo_que_nao_existe":"x"}' >/dev/null 2>&1; then
    nok "um campo desconhecido foi ACEITO — dynamic strict não está valendo"
else
    ok "campo desconhecido é recusado no índice (não vira campo silencioso)"
fi

# --- documento válido e busca ----------------------------------------------
api PUT "/${INDICE}/_doc/00000000000191?refresh=true" \
    '{"cnpj_completo":"00000000000191","razao_social":"COMERCIO DE ALIMENTOS BOM PRECO LTDA","uf":"SP","situacao_cadastral":"02"}' >/dev/null

BUSCA="$(api POST "/${INDICE}/_search" \
    '{"query":{"match":{"razao_social":"alimentos"}},"_source":false}')"
if printf '%s' "$BUSCA" | grep -q '"_id":"00000000000191"'; then
    ok "busca textual encontra o documento e devolve só o _id"
else
    nok "a busca não encontrou o documento"
fi

# Com `_source: false`, o hit NÃO traz o documento — a hidratação é por PK no
# Postgres, a 0,122 ms. Se `_source` voltasse, o índice inflaria de 8,4 para
# 138 GB sem que nada quebrasse.
if printf '%s' "$BUSCA" | grep -q '"_source"'; then
    nok "o hit trouxe _source — o índice não caberia no page cache"
else
    ok "o hit não traz _source (hidratação por PK no Postgres)"
fi

echo
echo "  ${PASS} passaram, ${FAIL} falharam"
[ "$FAIL" -eq 0 ]
