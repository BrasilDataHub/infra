# Prometheus da BrasilDataHub — ghcr.io/brasildatahub/prometheus
#
# Imagem própria: embute prometheus.yml e regras de alerta — o setup.sh
# entrega compose + .env por serviço; config em arquivo viaja na imagem.
#
# Retenção e limites: monitoring/profiles/*.env.
# Alvos: /etc/prometheus/targets/*.json (escritos pelo setup.sh no host).
#
# Versão: 3.13 LTS.
ARG PROM_VERSION=v3.13.1
FROM prom/prometheus:${PROM_VERSION}

USER root

COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY rules/ /etc/prometheus/rules/

# targets/ e secrets/ precisam existir mesmo vazios: o Prometheus recusa a
# config se o credentials_file do Meilisearch não existir.
RUN mkdir -p /etc/prometheus/targets /etc/prometheus/secrets \
    && touch /etc/prometheus/secrets/meili-metrics.key \
    && chmod 600 /etc/prometheus/secrets/meili-metrics.key \
    # /etc/prometheus é root:root; o processo roda como nobody.
    && chown -R nobody:nobody /etc/prometheus \
    # Gate de build: config/regra inválida não passa da imagem.
    && promtool check config /etc/prometheus/prometheus.yml \
    && promtool check rules /etc/prometheus/rules/*.yml

USER nobody
