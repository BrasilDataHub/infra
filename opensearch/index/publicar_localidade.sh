#!/usr/bin/env bash
# Publica o índice de localidades (regiões, estados e municípios do IBGE) para o
# autocomplete da home.
#
# Segue a mesma disciplina de `busca_estabelecimento`: índice físico com sufixo
# de carga, alias versionado, troca atômica e retenção do N-1. São 5.602
# documentos e 1,2 MB — a carga inteira leva menos de um segundo, então não há
# janela de indisponibilidade a administrar.
#
# Uso:
#   publicar_localidade.sh <load_id> [opensearch_host] [container_postgres]
#
# O host do OpenSearch é argumento porque a topologia varia com o orçamento: na
# máquina única ele é o próprio localhost; com serviços separados é o IP privado
# do host de busca. Nada aqui presume um arranjo.
#
#   publicar_localidade.sh 202607                        # máquina única
#   publicar_localidade.sh 202607 10.0.1.11:9200         # host de busca separado
set -euo pipefail

LOAD_ID="${1:?informe o load_id, no formato AAAAMM}"
OS="${2:-localhost:9200}"
PG_CONTAINER="${3:-postgres-postgres-1}"
PG_USER="${PG_USER:-postgres}"
PG_DB="${PG_DB:-dados_cnpj}"

ALIAS="busca_localidade"
INDICE="${ALIAS}-${LOAD_ID}"
MAPPING="$(dirname "$0")/busca_localidade.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

log "criando $INDICE"
curl -sf -X PUT "$OS/$INDICE" -H 'Content-Type: application/json' \
    --data-binary "@$MAPPING" >/dev/null

# O peso reproduz o TYPE_ORDER do LocalitySearchService: granularidade mais
# ampla primeiro, capital na frente das demais cidades do estado.
log "extraindo do Postgres"
docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -At -F$'\t' -c "
  select 'region', r.cod_regiao_ibge::text, r.nome_regiao, r.nome_regiao,
         coalesce(r.sigla_regiao,''), 'Região', '', 3.0
    from ibge_regiao r
  union all
  select 'state', e.cod_estado_ibge::text, e.nome_estado,
         case when e.sigla_uf is not null then e.nome_estado||' ('||e.sigla_uf||')'
              else e.nome_estado end,
         coalesce(e.sigla_uf,''), 'Estado', coalesce(e.sigla_uf,''), 2.0
    from ibge_estado e
  union all
  select 'city', c.cod_cidade_ibge::text, c.nome_cidade,
         case when e.sigla_uf is not null then c.nome_cidade||' - '||e.sigla_uf
              else c.nome_cidade end,
         '', 'Município', coalesce(e.sigla_uf,''),
         case when c.capital then 1.6 else 1.0 end
    from ibge_cidade c
    left join ibge_estado e on e.cod_estado_ibge = c.cod_estado_ibge
" > "$TMP/loc.tsv"

LINHAS="$(wc -l < "$TMP/loc.tsv")"
log "$LINHAS linhas extraídas"
# 27 UFs + 5 regiões + ~5.570 municípios. Menos que isso é carga incompleta, e
# publicar um alias sobre índice incompleto é pior que falhar aqui.
if [[ "$LINHAS" -lt 5500 ]]; then
    log "ERRO: esperado ao menos 5500 localidades, veio $LINHAS"
    exit 1
fi

python3 -c '
import json, sys
for ln in open(sys.argv[1]):
    p = ln.rstrip("\n").split("\t")
    if len(p) < 8:
        continue
    tipo, ibge, nome, label, sigla, hint, uf, peso = p[:8]
    print(json.dumps({"index": {"_id": f"{tipo}:{ibge}"}}))
    d = {"tipo": tipo, "ibge_id": ibge, "nome": nome, "nome_exato": nome,
         "label": label, "hint": hint, "peso": float(peso)}
    if sigla:
        d["sigla"] = sigla
    if uf:
        d["uf"] = uf
    print(json.dumps(d, ensure_ascii=False))
' "$TMP/loc.tsv" > "$TMP/loc.ndjson"

log "indexando"
curl -sf -X POST "$OS/$INDICE/_bulk" -H 'Content-Type: application/x-ndjson' \
    --data-binary "@$TMP/loc.ndjson" -o "$TMP/bulk.out"

# O _bulk devolve HTTP 200 mesmo com itens falhos: quem não olhar item por item
# publica um índice furado.
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
itens = d["items"]
took = d["took"]
erros = [i["index"] for i in itens if i["index"].get("error")]
if erros:
    print(f"ERRO: {len(erros)} documentos falharam; primeiro: {erros[0]}", file=sys.stderr)
    sys.exit(1)
print(f"indexados {len(itens)} documentos em {took} ms", file=sys.stderr)
' "$TMP/bulk.out"

curl -sf -X POST "$OS/$INDICE/_refresh" >/dev/null
DOCS="$(curl -sf "$OS/$INDICE/_count" | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')"
log "$DOCS documentos no índice"

# Amostra de sanidade antes de trocar o alias: se o autocomplete não tolera erro
# de digitação, o índice não serve ao propósito de existir.
log "verificando tolerância a erro de digitação"
ACERTO="$(curl -sf "$OS/$INDICE/_search" -H 'Content-Type: application/json' -d '{
  "size": 1, "_source": ["label"],
  "query": {"match": {"nome": {"query": "curtiba", "fuzziness": "AUTO", "prefix_length": 1}}}
}' | python3 -c 'import sys,json;h=json.load(sys.stdin)["hits"]["hits"];print(h[0]["_source"]["label"] if h else "")')"
if [[ "$ACERTO" != Curitiba* ]]; then
    log "ERRO: 'curtiba' devolveu '$ACERTO', esperado Curitiba"
    exit 1
fi
log "ok: curtiba -> $ACERTO"

log "promovendo alias $ALIAS -> $INDICE"
ANTERIOR="$(curl -sf "$OS/_alias/$ALIAS" 2>/dev/null \
    | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin)))' 2>/dev/null || true)"

ACOES="{\"add\":{\"index\":\"$INDICE\",\"alias\":\"$ALIAS\"}}"
for velho in $ANTERIOR; do
    [[ "$velho" == "$INDICE" ]] && continue
    ACOES="$ACOES,{\"remove\":{\"index\":\"$velho\",\"alias\":\"$ALIAS\"}}"
done
curl -sf -X POST "$OS/_aliases" -H 'Content-Type: application/json' \
    -d "{\"actions\":[$ACOES]}" >/dev/null

log "PRONTO: $ALIAS aponta para $INDICE ($DOCS documentos)"
if [[ -n "$ANTERIOR" ]]; then
    log "N-1 preservado: $ANTERIOR (apagar após 7 dias, como em busca_estabelecimento)"
fi
