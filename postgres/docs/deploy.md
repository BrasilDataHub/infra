# Deploy do PostgreSQL

**Docker Compose no host do banco** (YAML deste repositório). Se um painel for
obrigatório, use modo **Compose stack** com o mesmo YAML — nunca a seção
Databases / banco gerenciado.

Um perfil ([perfis.md](perfis.md)) tem **três partes**:

| Parte | Como se aplica |
|---|---|
| envs `PG_*` | `environment:` — chega íntegra em qualquer plataforma |
| **limite de memória** | `deploy.resources.limits.memory` / `PG_MEMORY_LIMIT` |
| **`/dev/shm`** | mount `tmpfs` com `PG_SHM_BYTES` |

> **Constraint:** Swarm descarta `shm_size` (não existe no `ContainerSpec`) sem
> erro — `/dev/shm` volta a 64 MB. Use o mount `tmpfs` do compose do repositório;
> ele é preservado em Compose e em Swarm (`docker stack config`).

## Receita

```bash
BASE=https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/postgres
mkdir -p /srv/postgres && cd /srv/postgres

curl -fsSL "$BASE/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$BASE/profiles/dedicada-16gb.env" -o .env    # <- perfil escolhido

cat >> .env <<'EOF'
POSTGRES_DB=dados_cnpj
POSTGRES_PASSWORD=troque-esta-senha
DADOS_READ_PASSWORD=troque-esta-senha
# opcionais: BIND_IP (default 0.0.0.0), POSTGRES_PORT, PG_VOLUME
EOF
chmod 600 .env

docker compose up -d
```

Perfis em [`postgres/profiles/`](../profiles/) — os mesmos que o
[`setup.sh`](../../README.md#setup-automatizado-de-vps) baixa.

`restart: unless-stopped` cobre o boot do host se o Docker subir com a máquina
(`systemctl enable docker`).

As três partes no YAML:

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

## Dokploy / Coolify

Crie o serviço como **Compose/Stack** e cole o mesmo YAML. Variáveis do `.env`
vão no campo Environment do stack. Não use a seção Databases — a UI não expõe
`/dev/shm` nem mount `tmpfs`, e ajustes por fora somem no redeploy.

| O que o painel perde | Consequência | Compensação |
|---|---|---|
| `shm_size` (Swarm) | `/dev/shm` = 64 MB → `DiskFull` em queries paralelas | mount `tmpfs` da receita |
| `BIND_IP` em interface específica | Swarm escuta em `0.0.0.0` (`docker stack config` avisa) | firewall por origem, ou não publicar a porta |
| `docker service update` | some no próximo redeploy | tudo no YAML do stack |

Emergência em serviço Swarm já no ar (paliativo — redeploy desfaz):

```bash
docker service update \
  --mount-add type=tmpfs,destination=/dev/shm,tmpfs-size=2147483648 \
  --limit-memory 14G \
  <nome-do-servico>
```

## Outras plataformas

**Kubernetes** — `emptyDir` em memória (não há `shm_size`):

```yaml
volumeMounts:
  - { name: dshm, mountPath: /dev/shm }
volumes:
  - name: dshm
    emptyDir: { medium: Memory, sizeLimit: 2Gi }
```

O `emptyDir` em memória **conta contra `resources.limits.memory`** — dimensione
`limite do perfil + tamanho do /dev/shm` (ex.: 14Gi + 2Gi = 16Gi).

**`docker run`** — só para teste; não versiona configuração:

```bash
docker run -d --name postgres \
  --shm-size=2g --memory=14g \
  -v bdh_pg_data:/var/lib/postgresql/data \
  -p 5432:5432 \
  --env-file perfil-16gb.env \
  -e POSTGRES_DB=dados_cnpj -e POSTGRES_PASSWORD="$SENHA" \
  ghcr.io/brasildatahub/postgres:17
```

## Verificação pós-deploy

Rode depois de todo deploy e redeploy. Preferível:

```bash
bdh verify postgres || { echo "NÃO inicie a carga"; exit 1; }
```

Compara `/dev/shm` efetivo com `PG_SHM_BYTES` do `.env` e sai != 0 se divergirem.

À mão:

```bash
C=<container>

# 1. /dev/shm bate com o perfil?  (64M = receita não aplicada)
docker exec $C df -h /dev/shm

# 2. o guard reclamou no start?
docker logs $C 2>&1 | grep shm-guard
#    saudável: shm-guard: /dev/shm=2 GB — pico estimado ... OK.

# 3. limite de memória?  (Memory=0 = sem limite)
docker inspect $C --format 'Memory={{.HostConfig.Memory}}'

# 4. conf aceito inteiro?  (deve voltar vazio)
docker exec $C psql -U postgres -d <db> -c \
  "SELECT sourceline, name, error FROM pg_file_settings
    WHERE NOT applied OR error IS NOT NULL;"

# 5. volume esperado, no disco certo?
docker inspect $C --format '{{range .Mounts}}{{.Type}} {{.Name}}{{println}}{{end}}'
df -h "$(docker info -f '{{.DockerRootDir}}')"
```

> Use `df`, não `docker inspect`, para `/dev/shm`. Com mount `tmpfs`,
> `HostConfig.ShmSize` não reflete o tamanho real.

Banner `/dev/shm INSUFICIENTE PARA O PERFIL` → o `shm-guard` reduziu
`max_parallel_workers_per_gather` ([guarda](../README.md#guarda-de-devshm)).
Corrija a receita; degradação é rede de segurança.

Validação mais profunda: [perfis.md](perfis.md#validação-de-um-perfil-implantado).

## Checklist

- [ ] Perfil pelo working set ([como escolher](perfis.md#como-escolher))
- [ ] Host preparado ([host.md](host.md)): NVMe, sysctl, THP off,
      `docker info -f '{{.DockerRootDir}}'` no NVMe
- [ ] YAML com as três partes: `PG_*`, `tmpfs` em `/dev/shm`, limite de memória
- [ ] Senha longa e aleatória; porta em `0.0.0.0` por default —
      restringir com `BIND_IP`/firewall/VPN ([host.md](host.md#rede))
- [ ] Senhas em `.env` fora do git (ou secret)
- [ ] `bdh verify postgres` (sai != 0 se `/dev/shm` divergir)
- [ ] Backups: snapshot do provedor + pgBackRest ([backup/](../backup/))

## Ver também

- [troubleshooting.md](troubleshooting.md)
- [perfis.md](perfis.md)
- [host.md](host.md)
