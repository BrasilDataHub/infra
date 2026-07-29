# OpenSearch da BrasilDataHub (ghcr.io/brasildatahub/opensearch).
#
# Mesma divisão dos demais módulos: o que é DECISÃO DE PROJETO vai na imagem
# (analisadores, lista de sinônimos, breakers, watermarks), e o que é
# DIMENSIONAMENTO vem de env no start (perfis em profiles/).
#
# Por que Apache 2.0 e não Elasticsearch: a condição C5 do dossiê de 23/07 —
# "sharding sob BUSL" — foi a única que não se confirmou, mas o motivo de o
# OpenSearch ter sido escolhido continua valendo: a licença não impõe limite ao
# que se pode fazer com o índice de 72 milhões de documentos.

ARG OPENSEARCH_VERSION=3.3.0
FROM opensearchproject/opensearch:${OPENSEARCH_VERSION}

# O plugin de segurança fica DESLIGADO, e isso é uma decisão, não preguiça: ele
# custa ~300 MiB de heap e TLS obrigatório entre nós, para proteger um serviço
# que não publica porta fora do host e cujo único cliente é a aplicação, do
# outro lado de um firewall restrito ao par de IPs (item 8). TLS entre nós é o
# item 33 do roadmap, e entra quando houver mais de um nó.
ENV DISABLE_SECURITY_PLUGIN=true \
    DISABLE_INSTALL_DEMO_CONFIG=true

# O exporter de métricas. Sem ele, o `opensearch.rules.yml` fica sem nenhuma
# série para avaliar — e o componente que hoje consome 93% do IO de leitura do
# host continuaria com ZERO regras de alerta, que é o estado que o item 23
# corrige.
#
# `--batch` porque o instalador é interativo por default e travaria o build
# pedindo confirmação das permissões do plugin.
ARG PROMETHEUS_EXPORTER_VERSION=3.3.0.0
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch \
    "https://github.com/Aiven-Open/prometheus-exporter-plugin-for-opensearch/releases/download/${PROMETHEUS_EXPORTER_VERSION}/prometheus-exporter-${PROMETHEUS_EXPORTER_VERSION}.zip"

# A lista de sinônimos é `updateable: true` no mapping: editá-la é um
# `POST /_reload_search_analyzers`, sem reindexar os 72 milhões de documentos.
# Ela entra na imagem porque é decisão de produto e precisa ser versionada.
COPY --chown=opensearch:opensearch index/razao_social_sinonimos.txt \
     /usr/share/opensearch/config/analysis/razao_social_sinonimos.txt
