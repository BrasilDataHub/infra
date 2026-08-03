# Alertmanager (ghcr.io/brasildatahub/alertmanager).
#
# Política de roteamento na imagem; destino de notificação via env no start.
# Silence é recurso do Alertmanager — as regras são avaliadas pelo Prometheus.

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
