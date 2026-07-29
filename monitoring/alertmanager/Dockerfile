# Alertmanager da BrasilDataHub (ghcr.io/brasildatahub/alertmanager).
#
# POR QUE ALERTMANAGER E NÃO CONTACT POINT DO GRAFANA. O documento 05 §9.3-A
# admite os dois. O runbook mensal (§9.4) decide: ele começa com "silence do
# Alertmanager por 6 h" e termina com "remover o silence". Silence é um recurso
# do Alertmanager; o alerting do Grafana só roteia regras GERENCIADAS PELO
# GRAFANA, e as 18 regras desta stack são avaliadas pelo Prometheus.
#
# Custo: 128 MiB de limite. O orçamento de memória de 03 §3.2 fecha em 7.292
# MiB de 7.987 no bdh-apps; com este serviço vai a 7.420 MiB. Continua dentro,
# e está registrado como divergência no EXECUCAO.md.
#
# A política de roteamento (agrupamento, inibição, janela de ETL) vai na
# IMAGEM; o destino da notificação é segredo e vem por env no start.

FROM prom/alertmanager:v0.30.0

USER root
COPY generate-config.sh /usr/local/bin/generate-config.sh
RUN chmod +x /usr/local/bin/generate-config.sh \
    && mkdir -p /etc/alertmanager \
    && chown -R nobody:nobody /etc/alertmanager
USER nobody

ENTRYPOINT ["/usr/local/bin/generate-config.sh"]
CMD ["/bin/alertmanager", \
     "--config.file=/etc/alertmanager/alertmanager.yml", \
     "--storage.path=/alertmanager", \
     "--web.listen-address=0.0.0.0:9093"]
