# Deploy do PostgreSQL

**A forma recomendada é Docker Compose direto no host do banco.** Se for
obrigatório usar Dokploy, Coolify ou outro painel, o caminho correto é criar o
serviço como **Compose stack** e colar o mesmo YAML — nunca usar o modo
"Databases"/banco gerenciado do painel. As duas coisas estão explicadas abaixo.

Um perfil ([perfis.md](perfis.md)) tem **três partes**, e só a primeira é
variável de ambiente:

| Parte | Como se aplica |
|---|---|
| envs `PG_*` | `environment:` — chega íntegra em qualquer plataforma |
| **limite de memória** | recurso do serviço |
| **`/dev/shm`** | recurso do container — **é o que se perde no caminho** |

Foi a terceira que custou 6h43 de ETL na Base Empresarial em 25/07/2026
([diagnóstico](troubleshooting.md#1-could-not-resize-shared-memory-segment)).

---

## Por que Docker Compose

1. **O que está no git é o que roda.** Sem uma camada traduzindo o YAML para
   outra coisa, `git diff` é a auditoria da configuração.
2. **Todos os recursos do container funcionam** — `/dev/shm`, limite de memória
   e bind da porta no IP privado. Em Swarm (e portanto no Dokploy), dois desses
   três se perdem em silêncio.
3. **Redeploy não desfaz nada.** Não existe definição paralela guardada no
   painel para divergir do repositório.
4. **Um banco não usa o que o painel oferece.** Build a partir do git,
   roteamento HTTP, TLS, preview environment e rolling update não se aplicam a
   um Postgres com volume único. Sobra a camada extra — e o risco dela.

O host do banco continua precisando de preparação ([host.md](host.md)); isso
não muda com a plataforma.

---

## A receita

Dois arquivos, ambos vindos do repositório: o compose e o `.env` do perfil
escolhido ([catálogo](perfis.md#os-perfis)).

```bash
BASE=https://raw.githubusercontent.com/BrasilDataHub/infra/main/postgres
mkdir -p /srv/postgres && cd /srv/postgres

curl -fsSL "$BASE/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$BASE/profiles/dedicada-16gb.env" -o .env    # <- perfil escolhido

# o perfil já traz o tuning PG_*, o PG_MEMORY_LIMIT e o PG_SHM_BYTES;
# falta o que só este deploy sabe:
cat >> .env <<'EOF'
POSTGRES_DB=dados_cnpj
POSTGRES_PASSWORD=troque-esta-senha
DADOS_READ_PASSWORD=troque-esta-senha
# opcionais: BIND_IP (default 0.0.0.0), POSTGRES_PORT, PG_VOLUME
EOF
chmod 600 .env

docker compose up -d
```

Os arquivos de perfil ficam em [`postgres/profiles/`](../profiles/) e são **os
mesmos** que o [`infra-setup.sh`](../../README.md#setup-automatizado-de-vps)
baixa — não há uma segunda cópia dos valores em lugar nenhum.

O `restart: unless-stopped` cobre o boot do host desde que o Docker suba com a
máquina (`systemctl enable docker`).

As três partes do perfil aparecem assim no YAML — é o que precisa estar presente
em qualquer variação que você escreva:

```yaml
    environment:
      # 1. bloco PG_* do perfil
    volumes:
      - pg_data:/var/lib/postgresql/data
      - type: tmpfs                      # 2. /dev/shm do perfil
        target: /dev/shm
        tmpfs:
          size: ${PG_SHM_BYTES:-1073741824}
    deploy:
      resources:
        limits:
          memory: ${PG_MEMORY_LIMIT:-7G} # 3. limite de memória

volumes:
  pg_data:
    driver: local
    name: ${PG_VOLUME:-bdh_pg_data}
```

> **Por que mount `tmpfs` e não `shm_size`?** Os dois produzem o mesmo
> resultado no Compose (verificado: `/dev/shm` com o tamanho pedido). Mas
> `shm_size` **não existe no `ContainerSpec` do Swarm** — em stack, painel ou
> `docker service create` ele é descartado sem erro e `/dev/shm` volta aos
> 64 MB de default do Docker. O mount `tmpfs` é preservado nos dois casos
> (verificado com `docker stack config`), então mantém-se uma receita só.

---

## Se for obrigatório usar Dokploy ou Coolify

A regra é curta: **crie o serviço como recurso do tipo Compose/Stack e cole o
mesmo YAML. Não use a seção "Databases"** (ou equivalente de banco gerenciado) —
foi por ali que o incidente entrou, porque a UI não expõe `/dev/shm` nem mount
`tmpfs`, e o que você ajustar por fora some no próximo redeploy.

Uma adaptação ao colar: as variáveis do `.env` (bloco `PG_*`, `PG_SHM_BYTES`,
`PG_MEMORY_LIMIT`, senhas) vão no campo **Environment** do stack.

Isso vale para Dokploy (sempre Swarm) e para Coolify nos dois modos. Com o
mount `tmpfs`, a receita é a mesma nos três casos — não há variante a decorar.

Três coisas que o painel **não** entrega, e como compensar:

| O que se perde | Consequência | O que fazer |
|---|---|---|
| `shm_size` (Swarm não tem o campo) | `/dev/shm` = 64 MB → queries paralelas morrem com `DiskFull` | já resolvido pelo mount `tmpfs` da receita |
| **`BIND_IP` numa interface específica** | em Swarm o IP do bind é ignorado e o serviço escuta em `0.0.0.0`¹ | como o default do repositório já é `0.0.0.0`, isso só importa se você **queria** restringir: nesse caso use firewall por origem ou não publique a porta |
| ajustes feitos por `docker service update` | somem no próximo redeploy pelo painel | manter tudo no YAML do stack; nada de correção só por CLI |

¹ verificado com `docker stack config`, que avisa:
`ignoring IP-address (…:5432:5432/tcp) service will listen on '0.0.0.0'`.

**Emergência em serviço já existente** (banco no ar, sem recriar o stack):

```bash
docker service update \
  --mount-add type=tmpfs,destination=/dev/shm,tmpfs-size=2147483648 \
  --limit-memory 14G \
  <nome-do-servico>          # ex.: databases-postgres-krjkec
```

Reinicia o container em segundos; o volume de dados não é tocado. **É paliativo:
um redeploy pelo painel desfaz.** A correção durável é o stack com o YAML.

---

## Outras plataformas

**Kubernetes** — não tem `shm_size`; o idioma é um `emptyDir` em memória:

```yaml
volumeMounts:
  - { name: dshm, mountPath: /dev/shm }
volumes:
  - name: dshm
    emptyDir: { medium: Memory, sizeLimit: 2Gi }
```

⚠️ O `emptyDir` em memória **conta contra `resources.limits.memory`** —
dimensione como `limite do perfil + tamanho do /dev/shm` (14Gi + 2Gi = 16Gi),
senão o pod é despejado por OOM quando o `/dev/shm` encher.

**`docker run`** — só para teste pontual; não deixa configuração versionada:

```bash
docker run -d --name postgres \
  --shm-size=2g --memory=14g \
  -v bdh_pg_data:/var/lib/postgresql/data \
  -p 5432:5432 \
  --env-file perfil-16gb.env \
  -e POSTGRES_DB=dados_cnpj -e POSTGRES_PASSWORD="$SENHA" \
  ghcr.io/brasildatahub/postgres:17
```

---

## Verificação pós-deploy

Rode **depois de todo deploy e de todo redeploy**. Não confie na configuração
declarada — confira a efetiva.

```bash
C=<container>

# 1. /dev/shm bate com o perfil?  (64M = a receita não foi aplicada)
docker exec $C df -h /dev/shm

# 2. o guard reclamou no start?
docker logs $C 2>&1 | grep shm-guard
#    saudável: shm-guard: /dev/shm=2 GB — pico estimado ... OK.

# 3. o limite de memória foi aplicado?  (Memory=0 = sem limite)
docker inspect $C --format 'Memory={{.HostConfig.Memory}}'

# 4. o conf gerado foi aceito inteiro?  (deve voltar vazio)
docker exec $C psql -U postgres -d <db> -c \
  "SELECT sourceline, name, error FROM pg_file_settings
    WHERE NOT applied OR error IS NOT NULL;"

# 5. o volume é o esperado, e no disco certo?
docker inspect $C --format '{{range .Mounts}}{{.Type}} {{.Name}}{{println}}{{end}}'
df -h "$(docker info -f '{{.DockerRootDir}}')"
```

> **Use `df`, não `docker inspect`, para o `/dev/shm`.** Com mount `tmpfs`,
> `HostConfig.ShmSize` reporta um valor que **não tem relação** com o tamanho
> real (verificado: 4,7 GB num container cujo `/dev/shm` é de 256 MB; no
> incidente, 67108864). O `df` mostra o que o Postgres enxerga.

Se o item 2 trouxer o banner `/dev/shm INSUFICIENTE PARA O PERFIL`, o
`/dev/shm` não chegou ao container — e o `shm-guard` reduziu
`max_parallel_workers_per_gather` para o banco subir sem quebrar
([como funciona](../README.md#guarda-de-devshm)). Corrija a receita; a
degradação é rede de segurança, não solução.

Valores efetivos do perfil, quando quiser conferir mais a fundo:
[validação de um perfil implantado](perfis.md#validação-de-um-perfil-implantado).

---

## Checklist

- [ ] Perfil escolhido pelo working set ([como escolher](perfis.md#como-escolher))
- [ ] Host preparado ([host.md](host.md)): NVMe local, sysctl, THP off, e
      `docker info -f '{{.DockerRootDir}}'` no NVMe (é onde o volume vive)
- [ ] YAML com **as três partes**: bloco `PG_*`, `tmpfs` em `/dev/shm`, limite de memória
- [ ] Senha longa e aleatória — a porta é publicada em `0.0.0.0` por default;
      se quiser restringir, `BIND_IP`/firewall/VPN ([host.md](host.md#rede))
- [ ] Senhas em `.env` fora do git (ou secret), nunca no YAML
- [ ] [Verificação pós-deploy](#verificação-pós-deploy) — os 5 comandos
- [ ] Backups ativos: snapshot do provedor + pgBackRest ([backup/](../backup/))

---

## Ver também

- [troubleshooting.md](troubleshooting.md) — sintomas, causas e correções
- [perfis.md](perfis.md) — os perfis e a justificativa de cada parâmetro
- [estrategia-deploy.md](estrategia-deploy.md) — por que Compose, com a
  comparação entre as opções e o histórico da decisão
- [host.md](host.md) — preparação da máquina
