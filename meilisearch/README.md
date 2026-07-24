# meilisearch — imagem Meilisearch da organização

Imagem `ghcr.io/brasildatahub/meilisearch` — wrapper **pinado** de
`getmeili/meilisearch:v1.34` (mesma minor da produção) para manter todos os
serviços de infra sob o namespace da org. Toda a configuração do Meilisearch
é por variável de ambiente, versionada aqui em perfis (`env.*`).

## Perfis

| Perfil | Cenário | MAX_INDEXING_MEMORY | Limite container |
|---|---|---|---|
| `env.atual` | host compartilhado de 8 GB, só índices de territórios (3,6 MB) | 1GiB | 1 GB |
| `env.pos-migracao` | indexação dos 72M de docs (AG15/F10), host pós-migração | 8GiB (ajustar ao host — F5) | ~16 GB durante indexação |

Motivação do perfil `atual`: a config de produção hoje permite
`MEILI_MAX_INDEXING_MEMORY` de **6 GiB** — no host de 8 GB dividido com
Postgres e Redis, é uma sentença de OOM. 1 GiB é folga confortável para os
índices atuais.

O `env.pos-migracao` traz uma regra de bolso (indexing memory ≈ metade da
RAM do serviço; container ≈ 2× durante a indexação); os valores finais
dependem de onde o Meili ficará (decisão F5) — ajustar antes da F10.

## Implantação no Dokploy

### Perfil atual (tarefa F4)

1. No serviço `meilisearch` do projeto `baseempresarial`: manter/fixar a
   imagem `getmeili/meilisearch:v1.34`.
2. Aplicar as envs de `env.atual` (colar no painel de Environment), mais
   `MEILI_MASTER_KEY` (secreta — nunca commitada).
3. Conferir o volume de dados montado em `/meili_data`.
4. Limite de memória do serviço: **1 GB**.
5. Redeploy e validar:

   ```bash
   curl -s http://localhost:7700/health          # {"status":"available"}
   # índices de territórios intactos:
   curl -s -H "Authorization: Bearer $MEILI_MASTER_KEY" http://localhost:7700/stats
   ```

### Perfil pós-migração (tarefa F10)

1. Ajustar `env.pos-migracao` à máquina escolhida na F5.
2. Aplicar as envs + subir o limite de memória do serviço (~2× o
   `MEILI_MAX_INDEXING_MEMORY` enquanto a indexação dos 72M roda).
3. Rodar a reindexação blue/green do `search-indexer-service` (AG15).
4. Após estabilizar, o limite pode voltar a ~1,5× o tamanho do índice quente.

## Validação local

```bash
# antes da primeira publicação na CI, builde o wrapper localmente:
docker build -t ghcr.io/brasildatahub/meilisearch:1.34 .

MEILI_MASTER_KEY=local-test PROFILE=atual docker compose up -d
curl -s http://localhost:7700/health
```

> O compose local não expõe porta por padrão no Dokploy; para testar fora
> dele, adicione `ports: ["7700:7700"]` num override.
