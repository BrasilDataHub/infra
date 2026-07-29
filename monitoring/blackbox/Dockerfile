# blackbox_exporter da BrasilDataHub (ghcr.io/brasildatahub/blackbox-exporter),
# com os módulos das classes de SLO embutidos.
#
# Config na IMAGEM, alvos no HOST — a mesma divisão do Prometheus. O que varia
# entre hosts é a lista de URLs, não a definição do que é uma "página pública";
# os alvos vivem em targets/blackbox.json e são relidos a quente.

FROM quay.io/prometheus/blackbox-exporter:v0.28.0

COPY blackbox.yml /etc/blackbox_exporter/config.yml
