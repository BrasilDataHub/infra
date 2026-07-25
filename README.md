# Infraestrutura de serviços da BrasilDataHub

Configuração **versionada** dos serviços de dados da organização
[BrasilDataHub](https://github.com/BrasilDataHub). As imagens são genéricas
por desenho: qualquer projeto da org (baseempresarial, baseescolar,
basehospitalar) consome as mesmas imagens; o que é específico de cada
projeto (envs, volumes, limites) vive no deploy.

## Serviços

| Serviço | Imagem | Documentação |
|---|---|---|
| PostgreSQL | `ghcr.io/brasildatahub/postgres:17` — imagem única, tuning por envs `PG_*`, perfis **dedicados** de 8 a 128 GB, todos com NVMe local ([guia](postgres/docs/perfis.md), [preparação do host](postgres/docs/host.md)) | [`postgres/`](postgres/) |
| Redis | `ghcr.io/brasildatahub/redis:7` — volatile-lru, AOF, perfis `cache-256mb`–`cache-2gb` | [`redis/`](redis/) |
| Meilisearch | `ghcr.io/brasildatahub/meilisearch:1.34` — wrapper pinado, perfis `busca-512mb`–`busca-16gb` | [`meilisearch/`](meilisearch/) |

Cada pasta tem seu README com as variáveis de configuração, os perfis por
máquina e o passo a passo de implantação no Dokploy.

Quando mais de um destes serviços dividir o mesmo host, dimensione a máquina
pela [fórmula de coexistência](postgres/docs/perfis.md#fórmula-de-reserva).

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
