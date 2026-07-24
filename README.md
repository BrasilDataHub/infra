# infra — configuração de instância do BaseEmpresarial

Fonte de verdade **versionada** da configuração dos serviços de dados que
hoje rodam crus no Dokploy (CCX13 de 8 GB, sem conf nem limites de recurso,
com o OOM-killer arbitrando). Cada pasta gera artefatos (imagem Docker ou
conf + compose) que o Dokploy consome — implantação é sempre tarefa humana
(`TAREFAS-FABIO.md`).

## Fronteiras

| Repositório | Dono de |
|---|---|
| `rfb-cnpj-etl` | schema, DDL, índices, views materializadas |
| **`infra` (este)** | imagens, `postgresql.conf`/`redis.conf`/envs, extensões disponíveis, limites de recursos, backup físico |
| `website` | aplicação (somente leitura no banco) |

## Serviços

- [`postgres/`](postgres/README.md) — imagem custom `postgres:17.10` em três
  perfis (`atual`, `dedicada-64`, `dedicada-128`), initdb com extensões e
  role de leitura, estratégia de backup PITR (pgBackRest).
- [`redis/`](redis/README.md) — cache/fila (Horizon), 512 MB, AOF.
- [`meilisearch/`](meilisearch/README.md) — busca, perfis `atual` (1 GiB) e
  `pos-migracao` (indexação dos 72M de documentos).

## CI

`.github/workflows/build-publish.yml` builda e publica as imagens no GHCR a
cada push na `main`. O Dokploy consome a imagem pronta pelo campo
**Docker Image** de cada serviço.
