# PgBouncer da BrasilDataHub (ghcr.io/brasildatahub/pgbouncer).
#
# Mesma divisão dos outros módulos: a POLÍTICA de pooling vai na imagem, o
# DIMENSIONAMENTO vem de envs no start (generate-config.sh), e o segredo vem
# do deploy.
#
# Ele existe por causa de uma conta, não por gosto de arquitetura. O item 18 do
# roadmap sobe `work_mem` de 32 para 96 MB para atacar 9.545 derrames de ~37 MB
# (~706 GB de IO evitável). Mas `work_mem` é POR OPERAÇÃO de sort/hash, e o
# pior caso multiplica pelas conexões:
#
#     100 conexões × 96 MB = 9,6 GB   → OOM dentro de um limite de 14 GiB
#      60 conexões × 96 MB = 5,8 GB   → cabe
#
# Com transaction pooling, 60 conexões reais atendem centenas de clientes. É
# isso que torna os 96 MB seguros — e é por isso que PgBouncer e work_mem são
# um par indivisível, nunca dois itens independentes.

FROM edoburu/pgbouncer:v1.24.1-p1

USER root
COPY generate-config.sh /usr/local/bin/generate-config.sh
RUN chmod +x /usr/local/bin/generate-config.sh \
    && mkdir -p /etc/pgbouncer \
    && chown -R postgres:postgres /etc/pgbouncer
USER postgres

ENTRYPOINT ["/usr/local/bin/generate-config.sh"]
CMD ["/usr/bin/pgbouncer", "/etc/pgbouncer/pgbouncer.ini"]
