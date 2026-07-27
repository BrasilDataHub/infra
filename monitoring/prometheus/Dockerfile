# Prometheus da BrasilDataHub — ghcr.io/brasildatahub/prometheus
#
# Por que existe uma imagem nossa, se o Prometheus upstream serve: prometheus.yml
# e as regras de alerta são ARQUIVOS, e o infra-setup.sh só sabe entregar um
# docker-compose.yml e um .env por serviço. Configuração em arquivo ou viaja
# dentro da imagem, ou exigiria uma dúzia de `curl` novos no provisionamento.
#
# O que NÃO está aqui, de propósito: retenção, limites de memória e os alvos.
# Retenção e limites são do perfil (monitoring/profiles/*.env); os alvos são do
# host (/etc/prometheus/targets/*.json, escritos pelo infra-setup.sh). Retunar a
# retenção nunca deve exigir rebuild.
#
# Versão: 3.13 é a LTS atual (suporte até 2027-07-31). A 3.5, LTS anterior, sai
# de suporte em 2026-07-31.
ARG PROM_VERSION=v3.13.1
FROM prom/prometheus:${PROM_VERSION}

USER root

COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY rules/ /etc/prometheus/rules/

# targets/ e secrets/ precisam EXISTIR mesmo vazios: o Prometheus recusa a config
# inteira se o credentials_file do job do Meilisearch não existir, e um host sem
# Meilisearch ficaria sem monitoração nenhuma por causa disso. O placeholder vazio
# resolve — o job simplesmente não tem alvo, e a credencial nunca é usada.
RUN mkdir -p /etc/prometheus/targets /etc/prometheus/secrets \
    && touch /etc/prometheus/secrets/meili-metrics.key \
    && chmod 600 /etc/prometheus/secrets/meili-metrics.key \
    # /etc/prometheus é root:root na imagem oficial e o processo roda como
    # nobody: sem o chown, o hot-reload dos targets falha com permission denied.
    && chown -R nobody:nobody /etc/prometheus \
    # Gate de build, no mesmo espírito do shm-guard.test.sh que roda antes de
    # publicar o Postgres: config ou regra inválida só se manifestaria como
    # container em restart loop no servidor, horas depois.
    && promtool check config /etc/prometheus/prometheus.yml \
    && promtool check rules /etc/prometheus/rules/*.yml

USER nobody
