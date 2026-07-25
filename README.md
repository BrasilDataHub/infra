# infra — infraestrutura de serviços da BrasilDataHub

Configuração **versionada** dos serviços de dados da organização
[BrasilDataHub](https://github.com/BrasilDataHub). As imagens são genéricas
por desenho: qualquer projeto da org (baseempresarial, baseescolar,
basehospitalar, ...) consome as mesmas imagens; o que é específico de cada
projeto (envs, volumes, limites) vive no deploy.

## Serviços

| Serviço | Imagem | Documentação |
|---|---|---|
| PostgreSQL | `ghcr.io/brasildatahub/postgres:17` — imagem única, tuning por envs `PG_*`, perfis de 8 a 128 GB ([guia](postgres/docs/perfis.md)) | [`postgres/`](postgres/) |
| Redis | `ghcr.io/brasildatahub/redis:7` — 512 MB, volatile-lru, AOF | [`redis/`](redis/) |
| Meilisearch | `ghcr.io/brasildatahub/meilisearch:1.34` — wrapper pinado, perfis de env | [`meilisearch/`](meilisearch/) |

Cada pasta tem seu README com as variáveis de configuração, os cenários por
máquina e o passo a passo de implantação no Dokploy.

## Publicação

As imagens são **públicas** no GHCR (pull sem autenticação); este
repositório permanece privado. A CI
(`.github/workflows/build-publish.yml`) builda e publica a cada push na
`main` que toque a pasta do serviço.

```bash
docker pull ghcr.io/brasildatahub/postgres:17
docker pull ghcr.io/brasildatahub/redis:7
docker pull ghcr.io/brasildatahub/meilisearch:1.34
```
