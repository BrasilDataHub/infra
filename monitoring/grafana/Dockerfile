# Grafana da BrasilDataHub — ghcr.io/brasildatahub/grafana
#
# Existe pelo mesmo motivo da imagem do Prometheus: provisioning e dashboards são
# ARQUIVOS, e o setup.sh só entrega docker-compose.yml e .env. Sem a
# imagem, o provisionamento teria que baixar uma árvore de ~8 arquivos por curl.
#
# Efeito colateral valioso: tira o Grafana do Docker Hub. O limite de pull
# anônimo derruba `docker compose up` num VPS novo, e o Grafana só publica lá.
ARG GRAFANA_VERSION=13.1.1
FROM grafana/grafana:${GRAFANA_VERSION}

USER root

COPY provisioning/ /etc/grafana/provisioning/
# /etc/grafana/dashboards, NÃO /var/lib/grafana/dashboards — ver o comentário em
# provisioning/dashboards/bdh.yml. Resumo: /var/lib/grafana é volume nomeado, e
# dashboards lá dentro congelariam na versão do primeiro deploy.
COPY dashboards/*.json /etc/grafana/dashboards/

# 472 é o uid do usuário grafana na imagem oficial.
RUN chown -R 472:0 /etc/grafana/provisioning /etc/grafana/dashboards \
    # Gate de build: JSON inválido só apareceria como dashboard ausente na UI,
    # sem erro visível. `grafana cli` não valida dashboards, então a checagem
    # possível é sintática — e já pega o caso real (merge conflict, jq truncado).
    && for f in /etc/grafana/dashboards/*.json; do \
           if ! grep -q '"uid"' "$f"; then \
               echo "sem uid: $f" >&2; exit 1; \
           fi; \
           if grep -q '\${DS_' "$f"; then \
               echo "referência a datasource variável em $f — rode vendorizar.sh" >&2; exit 1; \
           fi; \
       done \
    && echo "dashboards validados: $(ls -1 /etc/grafana/dashboards/*.json | wc -l)"

USER 472
