#!/usr/bin/env bash
# Build local das imagens da plataforma — o mesmo que a CI publica, na sua máquina.
#
#   bash build.sh laravel                 # as 3 imagens do módulo, sem publicar
#   bash build.sh laravel-app             # uma imagem só
#   bash build.sh monitoring/grafana      # por subdiretório
#   bash build.sh --tudo --push           # o repositório inteiro, publicando
#
# PARA QUE ELE EXISTE: publicar era exclusividade do GitHub Actions, e quando o
# workflow está lento — ou quando se quer só ver se uma mudança de Dockerfile
# compila — não havia alternativa a esperar a fila do runner. Este script usa a
# CPU da sua máquina e, se você pedir, empurra para o mesmo registro com os
# mesmos nomes e as mesmas tags.
#
# O QUE ELE NÃO FAZ: inventar configuração. Contexto, Dockerfile, plataformas,
# tags e build-args de cada imagem são LIDOS de .github/workflows/build-publish.yml
# — nada aqui é uma segunda cópia daquilo. Uma cópia divergiria na primeira
# imagem nova, e o sintoma seria publicar a tag errada em silêncio. O teste em
# test/catalogo-build.test.sh afirma que a leitura continua batendo.
#
# Por padrão NÃO publica: builda na arquitetura nativa e carrega no daemon local.
# Publicar exige `--push` e uma confirmação — é a única ação deste script que sai
# da sua máquina.
#
# CREDENCIAL, para quem for publicar: o GHCR exige um token com escopo
# `write:packages`, que NÃO é um dos que o `gh auth login` pede por padrão. Sem
# ele o login funciona e o push falha com 403, num texto que não menciona
# autenticação. Uma vez só, na máquina:
#
#   gh auth refresh -h github.com -s write:packages
#   bash build.sh ... --push --login
#
# O script confere a credencial ANTES de buildar qualquer coisa.
#
# SOBRE O TEMPO, numa estação Apple Silicon: o `linux/arm64` é nativo, e o
# `linux/amd64` passa por emulação — mas pela Rosetta do OrbStack/Docker Desktop,
# não pelo QEMU do runner. Medido em 01/08/2026, do zero, `laravel-app` nas duas
# arquiteturas (M-series, 11 núcleos):
#
#   linux/arm64 (nativo)     55 s
#   linux/amd64 (Rosetta)   352 s
#   as duas, em paralelo    376 s
#
# Um `--push` multi-arch daqui não é instantâneo, mas é minutos.
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
    # Da linha 2 até o `set -euo pipefail`, exclusive: o cabeçalho inteiro, sem
    # um número de linha fixo que desalinha ao primeiro parágrafo acrescentado.
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

# --- pré-requisitos ----------------------------------------------------------
# Verificados aqui, com o que fazer a respeito, em vez de deixar o erro aparecer
# no meio do primeiro build como um traceback de Python ou um "unknown flag".
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
# Uma linha por imagem, oito campos:
#   nome  contexto  dockerfile  plataformas  tags  build-args  teste  depende-de
#
# O separador é US (\037), e não tab, por um motivo que custa uma tarde: tab é
# "IFS whitespace" para o bash, e uma sequência dele conta como UM delimitador.
# Campos vazios — e vários módulos não declaram `platforms:` — colapsariam, e a
# linha inteira andaria uma coluna para a esquerda em silêncio.
#
# O que este bloco resolve, e que um `grep` no YAML não resolveria: a expansão de
# ${{ env.X }} e ${{ matrix.Y }}, o produto da matriz (é ela que produz as quatro
# imagens de `monitoring` e as duas de `laravel-derivados`), a fusão das
# arquiteturas de um mesmo alvo em um manifest só, e as tags de uma imagem
# publicada por digest — que não estão no step do build, e sim no `imagetools
# create` do job de manifest.
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


# Primeira passada: as tags criadas por `imagetools create`. Uma imagem publicada
# por digest não tem `tags:` no step do build — quem lhe dá nome é o job de
# manifest, e é de lá que estas tags saem.
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
                # Só as invocações de teste, e não o `run:` inteiro. O que fica
                # de fora é a preparação do runner — o `sudo sysctl
                # vm.max_map_count` do OpenSearch, por exemplo, que não existe no
                # macOS e cujo valor o Docker Desktop e o OrbStack já entregam
                # alto o bastante.
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

            # Um alvo dividido em vários jobs — uma arquitetura por runner — é
            # UMA imagem no fim. As plataformas se somam; o resto tem de bater.
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

# A forma que test/catalogo-build.test.sh consome. `|` em vez do US interno
# porque um teste precisa poder cortar a linha com `cut -d'|'` sem malabarismo —
# e nenhum campo do workflow contém pipe, o que o próprio teste afirma contando
# os campos.
if [ "$CATALOGO_CRU" = true ]; then
    tr "$SEP" '|' < "$CATALOGO"
    exit 0
fi

if [ "$LISTAR" = true ]; then
    # `(implícita)` é um módulo que não declara `platforms:` no workflow: a CI
    # publica a arquitetura do runner, que é amd64.
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
# Um argumento casa por NOME DE IMAGEM (`laravel-app`) ou por DIRETÓRIO — e um
# diretório casa também os contextos abaixo dele, que é o que faz `monitoring`
# pegar as quatro imagens de `monitoring/*`.
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

# Dependência entra junto e ANTES: publicar um `laravel-worker` sem republicar o
# `laravel-app` de que ele deriva entrega um derivado da base anterior.
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

# Sem `--push`, a base de um derivado é a imagem que acabou de ser carregada no
# daemon. Isso só funciona com o driver `docker`: um buildkit em container tem
# store próprio, não enxerga o daemon, e iria buscar a base no registro — onde
# ela ainda é a da publicação anterior. O build passaria, entregando um derivado
# da base errada, que é justamente o erro que este script existe para não
# cometer.
if [ "$TEM_DERIVADO" = true ] && [ "$PUSH" != true ]; then
    DRIVER="$(docker buildx inspect 2>/dev/null | awk -F': *' '/^Driver:/{print $2; exit}')"
    if [ "$DRIVER" != "docker" ]; then
        aviso "o builder ativo usa o driver '$DRIVER', que não enxerga as imagens do daemon."
        aviso "imagens derivadas viriam da base publicada, não da que este script acabou de gerar."
        aviso "troque com 'docker buildx use default' ou publique com --push."
    fi
fi

# Ordena pondo cada base antes de quem deriva dela. A cadeia é rasa de propósito
# (uma imagem base, dois derivados), então uma passada basta.
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

# O `docker login` grava a credencial num helper (`credsStore`, ou um
# `credHelpers` por registro) ou, sem helper nenhum, no `auths` do
# config.json. Consultar os três é o que permite descobrir a falta ANTES do
# build — a alternativa é o que aconteceu na primeira tentativa deste script:
# rodar o teste-gate inteiro, buildar as duas arquiteturas, e só descobrir no
# `pushing layers` que não havia credencial, com um "403 Forbidden" cujo texto
# não menciona login.
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

# Um token do `gh auth login` NÃO serve para publicar por padrão: os escopos
# pedidos são `repo`, `read:org`, `gist` e `workflow`. Falta `write:packages`, e
# sem ele o GHCR responde 403 no push — não no login.
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
# O builder dedicado só é criado quando faz falta. Com uma plataforma só e
# `--load`, o driver padrão do daemon serve e é mais rápido — ele carrega a
# imagem sem passar por exportação.
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
    # O mesmo teste-gate cobre várias imagens do módulo; rodá-lo uma vez por
    # imagem seria repetir minutos de build sem afirmar nada de novo.
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
        # `--load` aceita uma plataforma só. Sem push, a útil é a da máquina.
        plataformas="$(plataforma_nativa)"
    elif [ -z "$plataformas" ]; then
        # Os módulos de infraestrutura não declaram `platforms:` — a CI publica
        # a arquitetura do runner, que é amd64.
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
            # `--load` grava no daemon, que guarda uma arquitetura por tag: com
            # duas plataformas o buildx recusa. É o caso de quem passou
            # `--plataforma` com as duas só para conferir se as duas compilam —
            # então o build roda inteiro e o resultado fica no cache, sem imagem
            # local. Recusar aqui seria pior: é uma verificação legítima.
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
    # shellcheck disable=SC2086
    # A expansão é intencional: `$comando` é uma linha de comando montada acima,
    # com argumentos que não contêm espaço (tags, plataformas e caminhos deste
    # repositório). Aspas aqui fariam o docker receber tudo como um argumento só.
    ( cd "$RAIZ" && rodar $comando ) || die "build de $nome falhou"
    ok "$nome"
}

# --- confirmação do push -----------------------------------------------------
# A única coisa aqui que sai da máquina. As tags exatas aparecem antes, porque
# uma tag móvel sobrescreve o que está publicado e não há desfazer.
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
