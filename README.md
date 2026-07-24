# infra — infraestrutura de serviços da BrasilDataHub

Fonte de verdade **versionada** da configuração dos serviços de dados da
organização [BrasilDataHub](https://github.com/BrasilDataHub). As imagens
são **genéricas por desenho**: nada é atrelado a um projeto específico —
baseempresarial, baseescolar, basehospitalar e futuros projetos consomem as
mesmas imagens, cada um com seu deploy (envs, volumes, limites) no Dokploy.

## Imagens publicadas (GHCR)

| Imagem | Conteúdo |
|---|---|
| `ghcr.io/brasildatahub/postgres:17-{atual,dedicada-64,dedicada-128}` | PostgreSQL 17.10 com `postgresql.conf` por perfil de máquina, initdb com extensões e role de leitura |
| `ghcr.io/brasildatahub/redis:7` | Redis 7.4 com conf embutida (512 MB, volatile-lru, AOF) |
| `ghcr.io/brasildatahub/meilisearch:1.34` | wrapper pinado do Meilisearch v1.34 |

Publicação automática pela CI (`.github/workflows/build-publish.yml`) a cada
push na `main`. O Dokploy consome a imagem pronta pelo campo **Docker Image**
de cada serviço.

## Fronteiras

| Repositório | Dono de |
|---|---|
| **`infra` (este)** | imagens, `postgresql.conf`/`redis.conf`/envs, extensões disponíveis, limites de recursos, backup físico |
| ETL de cada projeto (ex.: `rfb-cnpj-etl`) | schema, DDL, índices, views materializadas |
| aplicação de cada projeto (ex.: `website`) | código; acesso somente leitura ao banco |

## Serviços

- [`postgres/`](postgres/README.md) — perfis de tuning (`atual` para host
  compartilhado de 8 GB; `dedicada-64`/`dedicada-128` para instâncias
  dedicadas em NVMe), initdb, estratégia de backup PITR (pgBackRest).
- [`redis/`](redis/README.md) — cache/fila (Horizon), 512 MB, AOF.
- [`meilisearch/`](meilisearch/README.md) — busca; perfis de env `atual`
  (1 GiB) e `pos-migracao` (indexação de grandes volumes).

A implantação é sempre tarefa humana — para o baseempresarial, ver
`TAREFAS-FABIO.md` (F4/F7/F10).
