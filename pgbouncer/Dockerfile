# PgBouncer (ghcr.io/brasildatahub/pgbouncer).
#
# Política de pooling na imagem; dimensionamento e segredo via env no start.
# Transaction pooling permite work_mem alto com poucas conexões reais ao Postgres.

FROM edoburu/pgbouncer:v1.24.1-p1

USER root
COPY generate-config.sh /usr/local/bin/generate-config.sh
RUN chmod +x /usr/local/bin/generate-config.sh \
    && mkdir -p /etc/pgbouncer \
    && chown -R postgres:postgres /etc/pgbouncer
USER postgres

ENTRYPOINT ["/usr/local/bin/generate-config.sh"]
CMD ["/usr/bin/pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
