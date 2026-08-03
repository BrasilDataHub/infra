# Imagem de build Laravel (ghcr.io/brasildatahub/laravel-builder): Composer + Node/npm.
#
# Deriva de laravel-app — composer install sem --ignore-platform-reqs.
# Sem entrypoint nem healthcheck.

ARG NODE_TAG=22-bookworm-slim
ARG BASE_IMAGE=ghcr.io/brasildatahub/laravel-app
ARG BASE_TAG=8.4-r3

FROM node:${NODE_TAG} AS node

FROM ${BASE_IMAGE}:${BASE_TAG}

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && node --version \
    && npm --version

WORKDIR /app
