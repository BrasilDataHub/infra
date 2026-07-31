# Imagem de BUILD das aplicações Laravel da BrasilDataHub
# (ghcr.io/brasildatahub/laravel-builder): Composer + Node/npm no mesmo lugar.
#
# Ela existe para eliminar um estágio inteiro e um `composer install` do build
# de cada projeto. Antes eram dois estágios separados:
#
#   phpbuilder (composer:2)  -> composer install --ignore-platform-reqs
#   nodebuilder (node:22)    -> COPY --from=phpbuilder vendor + npm run build
#
# O `--ignore-platform-reqs` existia por um motivo só: a imagem `composer:2` não
# tinha as extensões do projeto, então a checagem de plataforma falharia. O
# efeito colateral é que o vendor produzido ali não era confiável como vendor de
# produção — e por isso o runtime rodava `composer install` DE NOVO.
#
# Derivando de laravel-app, este problema desaparece: aqui o PHP e as 14
# extensões são exatamente os do runtime. O `composer install` roda sem
# `--ignore-platform-reqs`, o vendor resultante É o de produção, e o Dockerfile
# da aplicação simplesmente o copia. Um `composer install` a menos por build, e
# a checagem de plataforma volta a valer.
#
# Bônus de cache: como a base é a MESMA imagem do runtime, o `docker pull` do
# builder reaproveita todas as camadas que o laravel-app já trouxe. Baixa-se
# apenas a camada do Node.
#
# Esta imagem não tem entrypoint nem healthcheck: nada aqui roda em produção.

# Bloco de versões antes do primeiro FROM: um ARG declarado depois de um FROM
# pertence àquele estágio e não é visível nos FROM seguintes.
ARG NODE_TAG=22-bookworm-slim
ARG BASE_IMAGE=ghcr.io/brasildatahub/laravel-app
ARG BASE_TAG=8.4

# Node vem COPIADO da imagem oficial, e não de um script de instalação: é a
# mesma distribuição base (bookworm), então os binários são compatíveis, e a
# procedência é a imagem que o próprio projeto Node publica — sem repositório
# de terceiros e sem download em tempo de build, que é a etapa que mais falha
# em CI. O estágio nomeado é o que permite versionar por ARG: o `--from` de um
# COPY não aceita expansão de variável.
FROM node:${NODE_TAG} AS node

FROM ${BASE_IMAGE}:${BASE_TAG}

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && node --version \
    && npm --version

WORKDIR /app
