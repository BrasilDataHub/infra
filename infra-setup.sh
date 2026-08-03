#!/usr/bin/env bash
# Stub de compatibilidade: o provisionador é setup.sh (repo renomeado de infra → plataforma).
# O GitHub redireciona o repositório, não o arquivo — sem este stub, a URL antiga retorna 404.
set -euo pipefail

NOVA_URL="https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh"

cat >&2 <<EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │  ESTE SCRIPT MUDOU DE LUGAR                                      │
  └──────────────────────────────────────────────────────────────────┘

  repositório:  BrasilDataHub/infra   →  BrasilDataHub/plataforma
  script:       infra-setup.sh        →  setup.sh

  Use:

    curl -fsSL ${NOVA_URL} | sudo bash -s -- --auto

  Opções e caminhos em disco (/opt/brasildatahub, .setup-state, CLI bdh) são os mesmos.

EOF

# exit 1: curl|bash que “sucede” sem provisionar é pior que falha explícita.
exit 1
