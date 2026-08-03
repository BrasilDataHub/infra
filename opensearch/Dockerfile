# OpenSearch (ghcr.io/brasildatahub/opensearch).
#
# Decisões de projeto na imagem (analisadores, sinônimos, breakers); heap via perfil.
# Plugin de segurança desligado — serviço interno, cliente único atrás de firewall.

ARG OPENSEARCH_VERSION=3.3.0
FROM opensearchproject/opensearch:${OPENSEARCH_VERSION}

ENV DISABLE_SECURITY_PLUGIN=true \
    DISABLE_INSTALL_DEMO_CONFIG=true

ARG PROMETHEUS_EXPORTER_VERSION=3.3.0.0
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch \
    "https://github.com/Aiven-Open/prometheus-exporter-plugin-for-opensearch/releases/download/${PROMETHEUS_EXPORTER_VERSION}/prometheus-exporter-${PROMETHEUS_EXPORTER_VERSION}.zip"

# Sinônimos updateable — editáveis sem reindexar.
COPY --chown=opensearch:opensearch index/razao_social_sinonimos.txt \
     /usr/share/opensearch/config/analysis/razao_social_sinonimos.txt
