#!/usr/bin/env bash
# Gera o postgresql.conf a partir das envs PG_* e delega ao entrypoint
# oficial da imagem postgres (que cuida de initdb, permissões e step-down
# para o usuário postgres).
set -euo pipefail

/usr/local/bin/generate-config.sh

exec docker-entrypoint.sh "$@"
