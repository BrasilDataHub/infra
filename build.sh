#!/usr/bin/env bash
# Build local das imagens da plataforma (mesmo catálogo que a CI publica).
#
#   bash build.sh laravel                 # as 3 imagens do módulo, sem publicar
#   bash build.sh laravel-app             # uma imagem só
#   bash build.sh monitoring/grafana      # por subdiretório
#   bash build.sh --tudo --push           # o repositório inteiro, publicando
#
# Catálogo lido de .github/workflows/build-publish.yml (não duplicar config).
# Sem --push: build nativo + --load. Com --push: confirmação obrigatória.
#
# GHCR exige token com `write:packages` (não vem no `gh auth login` padrão):
#
#   gh auth refresh -h github.com -s write:packages
#   bash build.sh ... --push --login
#
# Credencial conferida antes de qualquer build. Em Apple Silicon, amd64 via Rosetta.
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")" && pwd)"
WORKFLOW="$RAIZ/.github/workflows/build-publish.yml"
BUILDER="bdh"

PUSH=false
PLATAFORMA=""
RODAR_TESTE=true
SEM_CACHE=false
LISTAR=false
CATALOGO_CRU=false
DRY_RUN=false
CONFIRMADO=false
FAZER_LOGIN=false
TUDO=false
ALVOS=""

usage() {
    # Cabeçalho até `set -euo pipefail` (sem número de linha fixo).
    sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Seleção (um ou mais; sem nenhuma, use --tudo):
  NOME                nome da imagem, sem registro nem tag (ex.: laravel-app)
  DIRETORIO           módulo ou subdiretório (ex.: laravel, monitoring/grafana)

Opções:
  --push              publica no GHCR, com as plataformas do workflow
  --plataforma LISTA  sobrescreve as plataformas (ex.: linux/amd64,linux/arm64)
  --sem-teste         pula o teste-gate do módulo (a CI não pula)
  --sem-cache         --no-cache no buildx
  --tudo              todos os alvos do workflow
  --listar            imprime o catálogo lido do workflow e sai
  --catalogo          o mesmo, cru e separado por `|`, para consumo por script
  --dry-run           mostra os comandos que rodaria, sem rodar
  --sim               dispensa a confirmação do --push
  --login             faz login no GHCR com `gh auth token` antes de publicar
  -h, --help          esta ajuda
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --push)        PUSH=true; shift ;;
        --plataforma)  PLATAFORMA="$2"; shift 2 ;;
        --sem-teste)   RODAR_TESTE=false; shift ;;
        --sem-cache)   SEM_CACHE=true; shift ;;
        --tudo)        TUDO=true; shift ;;
        --listar)      LISTAR=true; shift ;;
        --catalogo)    CATALOGO_CRU=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --sim)         CONFIRMADO=true; shift ;;
        --login)       FAZER_LOGIN=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            echo "opção desconhecida: $1" >&2; usage >&2; exit 2 ;;
        *)             ALVOS="$ALVOS $1"; shift ;;
    esac
done

# --- saída -------------------------------------------------------------------
if [ -t 1 ]; then
    C_OK=$'\033[0;32m'; C_ERR=$'\033[0;31m'; C_AVISO=$'\033[0;33m'
    C_FORTE=$'\033[1m'; C_FRACO=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_ERR=""; C_AVISO=""; C_FORTE=""; C_FRACO=""; C_OFF=""
fi

log()   { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()    { printf '%s  %s✓%s %s\n' "$(date -u +%H:%M:%S)" "$C_OK" "$C_OFF" "$*"; }
aviso() { printf '%s  %s!%s %s\n' "$(date -u +%H:%M:%S)" "$C_AVISO" "$C_OFF" "$*" >&2; }
die()   { printf '%s  %s✗ %s%s\n' "$(date -u +%H:%M:%S)" "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }
secao() { printf '\n%s==> %s%s\n' "$C_FORTE" "$*" "$C_OFF"; }

TMP="$(mktemp -d)"
limpar() { rm -rf "$TMP"; }
trap limpar EXIT

# Pré-requisitos conferidos aqui (mensagem acionável, não traceback no meio do build).
[ -f "$WORKFLOW" ] || die "não encontrei $WORKFLOW — rode este script de dentro do repositório"

command -v python3 >/dev/null 2>&1 \
    || die "python3 não encontrado — é ele que lê o catálogo do workflow"

python3 -c 'import yaml' 2>/dev/null \
    || die "PyYAML não instalado. Instale com: python3 -m pip install --user pyyaml"

command -v docker >/dev/null 2>&1 || die "docker não encontrado"

docker buildx version >/dev/null 2>&1 \
    || die "docker buildx não disponível — este script depende dele para multi-arch"

docker info >/dev/null 2>&1 \
    || die "o daemon do Docker não está respondendo. Suba o Docker Desktop ou o OrbStack e tente de novo."

# --- catálogo ----------------------------------------------------------------
# Uma linha por imagem (US \037, não tab — campos vazios colapsariam com IFS).
# Resolve ${{ env/matrix }}, produto da matriz, merge multi-arch e tags de digest.
SEP=$'\037'
CATALOGO="$TMP/catalogo"
python3 - "$WORKFLOW" > "$CATALOGO" <<'PY'
import re
import sys

import yaml

SEP = "\x1f"

documento = yaml.safe_load(open(sys.argv[1]))
ENV_GLOBAL = documento.get("env") or {}
JOBS = documento["jobs"]


def expandir(valor, variaveis):
    """Resolve ${{ env.X }} / ${{ matrix.Y }} e o ${X} de dentro de um `run:`."""
    if not isinstance(valor, str):
        return "" if valor is None else str(valor)

    def por_expressao(achado):
        return str(variaveis.get(achado.group(1).strip(), achado.group(0)))

    def por_shell(achado):
        return str(variaveis.get("env." + achado.group(1), achado.group(0)))

    texto = re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", por_expressao, valor)
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", por_shell, texto)


def combinacoes(job):
    """As combinações da matriz do job, como {'matrix.chave': valor}."""
    matriz = (job.get("strategy") or {}).get("matrix") or {}
    incluir = matriz.get("include") or []
    eixos = [chave for chave in matriz if chave != "include"]
    if incluir and eixos:
        raise SystemExit(
            "matriz com `include` E eixos no mesmo job não é suportada pelo "
            "catálogo; separe em dois jobs ou ajuste build.sh"
        )
    if incluir:
        return [{f"matrix.{k}": v for k, v in item.items()} for item in incluir]
    saida = [{}]
    for eixo in eixos:
        saida = [
            dict(combinacao, **{f"matrix.{eixo}": valor})
            for combinacao in saida
            for valor in matriz[eixo]
        ]
    return saida


def variaveis_de(job, combinacao):
    ambiente = dict(ENV_GLOBAL)
    ambiente.update(job.get("env") or {})
    contexto = {f"env.{k}": v for k, v in ambiente.items()}
    contexto.update(combinacao)
    return contexto


def ancestrais(nome, visto=None):
    """O job e todos os que ele espera, subindo o `needs:`."""
    visto = visto if visto is not None else []
    if nome in visto or nome not in JOBS:
        return visto
    visto.append(nome)
    esperados = JOBS[nome].get("needs") or []
    if isinstance(esperados, str):
        esperados = [esperados]
    for pai in esperados:
        ancestrais(pai, visto)
    return visto


def linhas(valor, variaveis):
    return [
        linha.strip()
        for linha in expandir(valor, variaveis).splitlines()
        if linha.strip()
    ]


# Tags de `imagetools create` (imagem por digest sem tags: no job de manifest).
manifestos = {}
testes = {}
for nome_job, job in JOBS.items():
    for combinacao in combinacoes(job):
        variaveis = variaveis_de(job, combinacao)
        for passo in job.get("steps") or []:
            comando = passo.get("run")
            if not comando:
                continue
            texto = expandir(comando, variaveis)
            if "imagetools create" in texto:
                for tag in re.findall(r'-t\s+"?([^\s"\\]+)"?', texto):
                    manifestos.setdefault(tag.rsplit(":", 1)[0], []).append(tag)
            elif ".test.sh" in texto:
                # Só invocações de teste (não sysctl/preparação do runner).
                comandos = [
                    linha.strip()
                    for linha in texto.splitlines()
                    if ".test.sh" in linha
                ]
                testes.setdefault(nome_job, " && ".join(comandos))

# Segunda passada: os builds propriamente ditos.
alvos = {}
ordem = []
for nome_job, job in JOBS.items():
    for combinacao in combinacoes(job):
        variaveis = variaveis_de(job, combinacao)
        for passo in job.get("steps") or []:
            if not str(passo.get("uses") or "").startswith("docker/build-push-action"):
                continue
            com = passo.get("with") or {}
            tags = linhas(com.get("tags"), variaveis)
            saidas = expandir(com.get("outputs"), variaveis)
            if tags:
                imagem = tags[0].rsplit(":", 1)[0]
            else:
                achado = re.search(r"name=([^,]+)", saidas)
                if not achado:
                    raise SystemExit(
                        f"o build em '{nome_job}' não declara `tags:` nem "
                        f"`name=` em `outputs:` — não dá para saber o que publica"
                    )
                imagem = achado.group(1)
                tags = manifestos.get(imagem, [])
                if not tags:
                    raise SystemExit(
                        f"'{imagem}' é publicada por digest em '{nome_job}', mas "
                        f"nenhum `imagetools create` lhe dá tag"
                    )

            teste = ""
            for antepassado in ancestrais(nome_job):
                if antepassado in testes:
                    teste = testes[antepassado]
                    break

            registro = {
                "nome": imagem.rsplit("/", 1)[-1],
                "imagem": imagem,
                "contexto": expandir(com.get("context"), variaveis),
                "dockerfile": expandir(com.get("file"), variaveis),
                "plataformas": expandir(com.get("platforms"), variaveis) or "",
                "tags": tags,
                "build_args": linhas(com.get("build-args"), variaveis),
                "teste": teste,
            }

            # Mesmo alvo em vários jobs: somar plataformas; resto deve bater.
            anterior = alvos.get(registro["nome"])
            if anterior is None:
                alvos[registro["nome"]] = registro
                ordem.append(registro["nome"])
                continue
            plataformas = [
                p
                for p in (anterior["plataformas"] + "," + registro["plataformas"]).split(",")
                if p
            ]
            anterior["plataformas"] = ",".join(sorted(set(plataformas)))

# O `context` vazio significa "o Dockerfile padrão na raiz do contexto".
for registro in alvos.values():
    if not registro["dockerfile"]:
        registro["dockerfile"] = f"{registro['contexto']}/Dockerfile"

# Dependência entre imagens: um `BASE_IMAGE=` que aponte para outro alvo daqui.
por_imagem = {registro["imagem"]: nome for nome, registro in alvos.items()}
for registro in alvos.values():
    registro["depende"] = ""
    for argumento in registro["build_args"]:
        chave, _, valor = argumento.partition("=")
        if chave.strip() == "BASE_IMAGE" and valor.strip() in por_imagem:
            registro["depende"] = por_imagem[valor.strip()]

for nome in ordem:
    r = alvos[nome]
    print(
        SEP.join(
            [
                r["nome"],
                r["contexto"],
                r["dockerfile"],
                r["plataformas"],
                ",".join(r["tags"]),
                ",".join(r["build_args"]),
                r["teste"],
                r["depende"],
            ]
        )
    )
PY

[ -s "$CATALOGO" ] || die "não consegui ler nenhuma imagem de $WORKFLOW"

# Saída `|` para test/catalogo-build.test.sh (`cut -d'|'`).
if [ "$CATALOGO_CRU" = true ]; then
    tr "$SEP" '|' < "$CATALOGO"
    exit 0
fi

if [ "$LISTAR" = true ]; then
    # (implícita) = sem platforms: no workflow → amd64 do runner.
    printf '\n%-19s %-24s %-24s %s\n' IMAGEM CONTEXTO PLATAFORMAS TAGS
    while IFS="$SEP" read -r nome contexto _ plataformas tags _ _ depende; do
        [ -n "$depende" ] && nome="$nome←$depende"
        printf '%-19s %-24s %-24s %s\n' \
            "$nome" "$contexto" "${plataformas:-(implícita)}" "${tags//,/  }"
    done < "$CATALOGO"
    printf '\n%s←%s indica derivação: a base é buildada antes.\n' "$C_FRACO" "$C_OFF"
    exit 0
fi

# --- seleção -----------------------------------------------------------------
# Casa por nome de imagem ou diretório (ex.: monitoring → monitoring/*).
selecionados() {
    local nome contexto alvo
    while IFS="$SEP" read -r nome contexto _; do
        if [ "$TUDO" = true ]; then
            echo "$nome"
            continue
        fi
        for alvo in $ALVOS; do
            alvo="${alvo%/}"
            if [ "$alvo" = "$nome" ] || [ "$alvo" = "$contexto" ] \
               || [ "${contexto#"$alvo"/}" != "$contexto" ]; then
                echo "$nome"
                break
            fi
        done
    done < "$CATALOGO"
}

if [ "$TUDO" != true ] && [ -z "${ALVOS// /}" ]; then
    usage >&2
    die "diga o que buildar — um nome de imagem, um diretório, ou --tudo"
fi

ESCOLHIDOS="$(selecionados)"
[ -n "$ESCOLHIDOS" ] || die "nenhuma imagem casa com:${ALVOS}. Veja as disponíveis com --listar"

# Dependência entra junto e antes (derivado precisa da base nova).
TEM_DERIVADO=false
avisar_dependencias() {
    local nome linha depende
    while read -r nome; do
        linha="$(grep -m1 "^${nome}${SEP}" "$CATALOGO" || true)"
        depende="$(printf '%s' "$linha" | cut -d"$SEP" -f8)"
        [ -n "$depende" ] || continue
        TEM_DERIVADO=true
        if ! printf '%s\n' "$ESCOLHIDOS" | grep -qx "$depende"; then
            aviso "$nome deriva de $depende, que não está na seleção — usará a imagem já publicada"
        fi
    done <<< "$1"
}
avisar_dependencias "$ESCOLHIDOS"

# Sem --push: driver `docker` (buildkit em container não vê a base no daemon).
if [ "$TEM_DERIVADO" = true ] && [ "$PUSH" != true ]; then
    DRIVER="$(docker buildx inspect 2>/dev/null | awk -F': *' '/^Driver:/{print $2; exit}')"
    if [ "$DRIVER" != "docker" ]; then
        aviso "o builder ativo usa o driver '$DRIVER', que não enxerga as imagens do daemon."
        aviso "imagens derivadas viriam da base publicada, não da que este script acabou de gerar."
        aviso "troque com 'docker buildx use default' ou publique com --push."
    fi
fi

# Base antes do derivado (cadeia rasa: uma passada basta).
ORDENADOS="$(
    { while read -r nome; do
          linha="$(grep -m1 "^${nome}${SEP}" "$CATALOGO" || true)"
          printf '%s\034%s\n' "$([ -z "$(printf '%s' "$linha" | cut -d"$SEP" -f8)" ] && echo 0 || echo 1)" "$nome"
      done <<< "$ESCOLHIDOS"; } | sort -s -t$'\034' -k1,1 | cut -d$'\034' -f2
)"

# --- plataformas -------------------------------------------------------------
plataforma_nativa() {
    case "$(uname -m)" in
        arm64|aarch64) echo "linux/arm64" ;;
        x86_64|amd64)  echo "linux/amd64" ;;
        *)             die "arquitetura $(uname -m) não mapeada" ;;
    esac
}

# --- registro e credencial ---------------------------------------------------
REGISTRO="$(head -1 "$CATALOGO" | cut -d"$SEP" -f5 | cut -d, -f1 | cut -d/ -f1)"

# Conferir credencial (credsStore / credHelpers / auths) antes do build.
credencial_do_registro() {
    local helper
    helper="$(python3 - "$REGISTRO" <<'PY'
import json
import os
import sys

registro = sys.argv[1]
try:
    with open(os.path.expanduser("~/.docker/config.json")) as arquivo:
        config = json.load(arquivo)
except (OSError, ValueError):
    raise SystemExit

auxiliar = (config.get("credHelpers") or {}).get(registro) or config.get("credsStore")
if auxiliar:
    print("helper:" + auxiliar)
elif (config.get("auths") or {}).get(registro):
    print("config")
PY
)"
    case "$helper" in
        config)    return 0 ;;
        helper:*)  echo "$REGISTRO" | "docker-credential-${helper#helper:}" get >/dev/null 2>&1 ;;
        *)         return 1 ;;
    esac
}

# `gh auth login` padrão sem write:packages → 403 no push do GHCR.
gh_pode_publicar() {
    command -v gh >/dev/null 2>&1 || return 1
    gh auth status 2>&1 | grep -q "write:packages"
}

como_autenticar() {
    printf '\n    Para publicar em %s é preciso uma credencial com write:packages:\n\n' "$REGISTRO"
    if command -v gh >/dev/null 2>&1; then
        printf '      # acrescenta o escopo que falta ao token que o gh já tem\n'
        printf '      gh auth refresh -h github.com -s write:packages\n\n'
        printf '      # e então repita o comando com --login\n'
    fi
    printf '      # ou, com um Personal Access Token (classic) de escopo write:packages:\n'
    printf '      docker login %s -u SEU_USUARIO\n\n' "$REGISTRO"
}

if [ "$FAZER_LOGIN" = true ]; then
    command -v gh >/dev/null 2>&1 || die "--login precisa do gh CLI instalado e autenticado"
    if ! gh_pode_publicar; then
        como_autenticar >&2
        die "o token do gh não tem o escopo write:packages"
    fi
    USUARIO="$(gh api user --jq .login)"
    log "autenticando em $REGISTRO como $USUARIO"
    gh auth token | docker login "$REGISTRO" -u "$USUARIO" --password-stdin
fi

if [ "$PUSH" = true ] && [ "$DRY_RUN" != true ] && ! credencial_do_registro; then
    como_autenticar >&2
    die "sem credencial para $REGISTRO — nada foi buildado"
fi

# --- execução ----------------------------------------------------------------
# Builder dedicado só se multi-arch/push; uma plataforma + --load usa o daemon.
garantir_builder() {
    docker buildx inspect "$BUILDER" >/dev/null 2>&1 && return 0
    log "criando o builder '$BUILDER' (driver docker-container, exigido por multi-arch)"
    [ "$DRY_RUN" = true ] && return 0
    docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
}

rodar() {
    if [ "$DRY_RUN" = true ]; then
        printf '    %s[dry-run]%s %s\n' "$C_FRACO" "$C_OFF" "$*"
        return 0
    fi
    "$@"
}

SO_CACHE=false
TESTES_RODADOS=""
rodar_teste() {
    local comando="$1"
    [ -n "$comando" ] || return 0
    [ "$RODAR_TESTE" = true ] || return 0
    # Teste-gate uma vez por módulo (não por imagem).
    printf '%s\n' "$TESTES_RODADOS" | grep -qxF "$comando" && return 0
    TESTES_RODADOS="$TESTES_RODADOS
$comando"
    secao "Teste-gate"
    log "$comando"
    if [ "$DRY_RUN" = true ]; then
        printf '    %s[dry-run]%s %s\n' "$C_FRACO" "$C_OFF" "$comando"
        return 0
    fi
    ( cd "$RAIZ" && eval "$comando" ) || die "o teste-gate falhou — nada será publicado"
    ok "teste-gate passou"
}

construir() {
    local nome="$1" contexto dockerfile plataformas tags build_args teste linha
    linha="$(grep -m1 "^${nome}${SEP}" "$CATALOGO")"
    contexto="$(printf '%s' "$linha" | cut -d"$SEP" -f2)"
    dockerfile="$(printf '%s' "$linha" | cut -d"$SEP" -f3)"
    plataformas="$(printf '%s' "$linha" | cut -d"$SEP" -f4)"
    tags="$(printf '%s' "$linha" | cut -d"$SEP" -f5)"
    build_args="$(printf '%s' "$linha" | cut -d"$SEP" -f6)"
    teste="$(printf '%s' "$linha" | cut -d"$SEP" -f7)"

    rodar_teste "$teste"

    if [ -n "$PLATAFORMA" ]; then
        plataformas="$PLATAFORMA"
    elif [ "$PUSH" != true ]; then
        # --load: uma plataforma (nativa sem push).
        plataformas="$(plataforma_nativa)"
    elif [ -z "$plataformas" ]; then
        # Sem platforms: no workflow a CI publica amd64 do runner.
        plataformas="linux/amd64"
    fi

    local comando
    comando="docker buildx build"
    case "$plataformas" in
        *,*) garantir_builder; comando="$comando --builder $BUILDER" ;;
    esac
    comando="$comando --platform $plataformas"
    comando="$comando --file $dockerfile"

    local IFS=,
    local item
    for item in $tags;       do comando="$comando --tag $item"; done
    for item in $build_args; do comando="$comando --build-arg $item"; done
    unset IFS

    [ "$SEM_CACHE" = true ] && comando="$comando --no-cache"
    if [ "$PUSH" = true ]; then
        comando="$comando --push"
    else
        case "$plataformas" in
            # --load multi-arch: buildx recusa gravar; resultado fica no cache.
            *,*)
                aviso "duas plataformas sem --push: o build roda e valida, mas não gera imagem local"
                comando="$comando --output type=cacheonly"
                SO_CACHE=true
                ;;
            *) comando="$comando --load" ;;
        esac
    fi
    comando="$comando $contexto"

    secao "$nome  ${C_FRACO}[$plataformas]${C_OFF}"
    # Expansão intencional de $comando (args sem espaço).
    ( cd "$RAIZ" && rodar $comando ) || die "build de $nome falhou"
    ok "$nome"
}

# --- confirmação do push -----------------------------------------------------
# Única ação que sai da máquina; tags móveis sobrescrevem sem desfazer.
if [ "$PUSH" = true ] && [ "$CONFIRMADO" != true ] && [ "$DRY_RUN" != true ]; then
    secao "Vai publicar em $REGISTRO"
    while read -r nome; do
        linha="$(grep -m1 "^${nome}${SEP}" "$CATALOGO")"
        printf '    %s\n' "$(printf '%s' "$linha" | cut -d"$SEP" -f5 | tr ',' '\n' | sed "2,\$s/^/    /")"
    done <<< "$ORDENADOS"
    printf '\n    Confirma? [s/N] '
    read -r resposta
    case "$resposta" in
        s|S|sim|SIM) ;;
        *) die "cancelado" ;;
    esac
fi

INICIO="$(date +%s)"
while read -r nome; do
    [ -n "$nome" ] && construir "$nome"
done <<< "$ORDENADOS"

secao "Pronto em $(( $(date +%s) - INICIO ))s"
if [ "$PUSH" = true ]; then
    log "publicado em $REGISTRO"
elif [ "$SO_CACHE" = true ]; then
    log "build validado e no cache — sem imagem local e sem publicar"
else
    log "carregado no daemon local — nada foi publicado (use --push para isso)"
fi
