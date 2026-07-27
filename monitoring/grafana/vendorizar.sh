#!/usr/bin/env bash
# ==============================================================================
# vendorizar.sh — baixa dashboards do grafana.com e os normaliza para o
# provisioning por arquivo do Grafana.
#
# Rodado À MÃO, ao atualizar um dashboard — não faz parte do build nem do deploy.
# O resultado é versionado em dashboards/*.json, e é ele que entra na imagem.
#
# POR QUE NORMALIZAR (o passo que, se pulado, entrega painéis vazios e ninguém
# entende): o JSON publicado no grafana.com é feito para o IMPORT INTERATIVO. Ele
# traz um bloco `__inputs` declarando um datasource variável `${DS_PROMETHEUS}`,
# que a UI resolve perguntando ao usuário. O provisioning por arquivo NÃO resolve
# nada disso — ele carrega o JSON como está, cada painel aponta para um
# datasource chamado literalmente "${DS_PROMETHEUS}", que não existe, e o
# dashboard abre em branco.
#
# Por isso trocamos toda referência pelo uid FIXO do nosso datasource
# (provisioning/datasources/prometheus.yml), removemos __inputs/__requires e
# zeramos o id.
#
# Baixar no deploy em vez de versionar foi descartado: quebraria a
# reprodutibilidade e exigiria rede no host no momento do provisionamento.
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")"

DATASOURCE_UID="bdh-prometheus"

# id do grafana.com : arquivo de destino : uid que daremos ao dashboard
DASHBOARDS=(
    "1860:dashboards/node.json:bdh-node"
    "9628:dashboards/postgres.json:bdh-postgres"
    "763:dashboards/redis.json:bdh-redis"
)

for entry in "${DASHBOARDS[@]}"; do
    IFS=':' read -r id destino uid <<< "$entry"

    revisao="$(curl -fsS "https://grafana.com/api/dashboards/${id}" | jq -r '.revision')"
    nome="$(curl -fsS "https://grafana.com/api/dashboards/${id}" | jq -r '.name')"

    curl -fsS "https://grafana.com/api/dashboards/${id}/revisions/${revisao}/download" \
        | jq --arg uid "$uid" --arg ds "$DATASOURCE_UID" '
            # 1. fora os blocos que só o import interativo entende
            del(.__inputs, .__requires, .__elements)
            # 2. toda referência de datasource passa a apontar para o nosso uid.
            #    walk() pega os aninhados: painel, alvo, template e anotação.
            | walk(
                if type == "object" and has("datasource") then
                    if (.datasource | type) == "object" and (.datasource.type // "") == "prometheus" then
                        .datasource = {"type": "prometheus", "uid": $ds}
                    elif (.datasource | type) == "string" then
                        .datasource = {"type": "prometheus", "uid": $ds}
                    else . end
                else . end
              )
            # 3. identidade estável: o uid é o que a URL do dashboard usa, e o id
            #    numérico precisa ser null para o provisioning aceitar.
            | .id = null
            | .uid = $uid
            # 4. sem isto, o Grafana marca o dashboard como "com alterações
            #    pendentes" a cada reinício.
            | .version = 1
          ' > "$destino"

    # --- correção de PG17 -----------------------------------------------------
    # O dashboard 9628 é anterior ao PostgreSQL 17, que moveu os contadores de
    # checkpoint de pg_stat_bgwriter para pg_stat_checkpointer. Sem este patch,
    # os painéis de checkpoint abrem VAZIOS num banco 17 — e vazio parece "não
    # está acontecendo nada", não "estou consultando a métrica errada".
    #
    # Duas séries do dashboard não têm equivalente e continuam vazias:
    # buffers_backend e buffers_backend_fsync foram para pg_stat_io, que o
    # postgres_exporter 0.20.1 ainda não expõe. Registrado em UPSTREAM.md.
    if [ "$id" = "9628" ]; then
        sed -i.bak \
            -e 's/pg_stat_bgwriter_buffers_checkpoint_total/pg_stat_checkpointer_buffers_written_total/g' \
            -e 's/pg_stat_bgwriter_checkpoint_write_time_total/pg_stat_checkpointer_write_time_total/g' \
            -e 's/pg_stat_bgwriter_checkpoint_sync_time_total/pg_stat_checkpointer_sync_time_total/g' \
            "$destino"
        rm -f "$destino.bak"
        printf '    patch PG17 aplicado (checkpoint: bgwriter -> checkpointer)\n'
    fi

    printf '  %-28s <- grafana.com/%s rev %s (%s)\n' "$destino" "$id" "$revisao" "$nome"

    # Falha aqui e não em produção: se sobrou uma referência ao datasource
    # variável, o dashboard abriria vazio sem nenhum erro visível.
    # shellcheck disable=SC2016  # o literal procurado é '${DS_', não uma expansão
    if grep -q '\${DS_' "$destino"; then
        printf '    ERRO: ainda há referência a ${DS_...} em %s\n' "$destino" >&2
        exit 1
    fi
done

printf '\nRevise o diff antes de commitar: um dashboard novo pode usar métricas de\n'
printf 'coletores que desligamos de propósito (ver postgres/docs/metricas.md).\n'
