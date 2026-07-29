#!/usr/bin/env bash
# ATENÇÃO: este arquivo não é o provisionador. É um aviso.
#
# O repositório passou de `infra` para `plataforma`, e o script de
# `infra-setup.sh` para `setup.sh`. O GitHub redireciona o REPOSITÓRIO
# renomeado, mas não um ARQUIVO que mudou de nome — sem este stub, o comando
# de instalação antigo receberia um 404 e quem o rodasse não saberia por quê.
#
# Pode ser removido depois que a documentação e a memória muscular tiverem
# migrado. Sem data marcada: ele custa 30 linhas e evita um diagnóstico caro.
set -euo pipefail

NOVA_URL="https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/setup.sh"

# Para stderr: se alguém canalizou este script para `bash`, a saída padrão pode
# estar sendo consumida por outra coisa.
cat >&2 <<EOF

  ┌──────────────────────────────────────────────────────────────────┐
  │  ESTE SCRIPT MUDOU DE LUGAR                                      │
  └──────────────────────────────────────────────────────────────────┘

  repositório:  BrasilDataHub/infra   →  BrasilDataHub/plataforma
  script:       infra-setup.sh        →  setup.sh

  Use:

    curl -fsSL ${NOVA_URL} | sudo bash -s -- --auto

  As opções são as mesmas; nada mudou no comportamento nem nos caminhos em
  disco (/opt/brasildatahub, .setup-state, o CLI \`bdh\`). Uma instalação
  existente continua funcionando — basta apontar para a URL nova.

EOF

# Sai com erro de propósito: um \`curl | bash\` que "termina bem" sem provisionar
# nada é pior que um que falha alto.
exit 1
