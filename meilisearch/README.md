# meilisearch — imagem Meilisearch da organização

Imagem `ghcr.io/brasildatahub/meilisearch` — wrapper **pinado** de
`getmeili/meilisearch:v1.34` (mesma minor da produção) para manter todos os
serviços de infra sob o namespace da org. Toda a configuração do Meilisearch
é por variável de ambiente, versionada aqui em perfis (`env.*`).

## Perfis por orçamento de memória

Os perfis são definidos pelo tamanho dos índices e pelo orçamento de RAM do
serviço — independentes de projeto e de fornecedor:

| Perfil | MAX_INDEXING_MEMORY | Threads | Limite de container | Quando usar |
|---|---|---|---|---|
| [`busca-512mb`](env.busca-512mb) | 256MiB | 1 | 512M | projetos pequenos (ex.: Base Escolar, ~170 mil docs); índices de MB a centenas de MB |
| [`busca-1gb`](env.busca-1gb) | 1GiB | 1 | 1G | default; host compartilhado ou índices de poucos GB (instância atual do Base Empresarial) |
| [`busca-4gb`](env.busca-4gb) | 2GiB | 2 | 4G na indexação; ~2G em regime | índices médios: milhões de documentos |
| [`busca-16gb`](env.busca-16gb) | 8GiB | 4 | ~16G durante indexação | índices grandes: dezenas de milhões de docs (Base Empresarial pós-migração: 72M establishments + 26M partners, 15–25 GB) |

Nomes antigos (referenciados em documentos do baseempresarial):
`env.atual` → `busca-1gb`; `env.pos-migracao` → `busca-16gb`.

**Regra de dimensionamento** (vale para qualquer perfil):
`MEILI_MAX_INDEXING_MEMORY` ≈ metade da RAM disponível para o serviço;
limite de container ≈ 2× esse valor **durante a indexação** (o Meili usa
memória além do teto de indexação para o próprio processo e mmap do índice).
Em regime (sem indexar), o limite pode cair para ~1,5× o índice quente.

**Quando migrar de perfil:** indexação abortando por OOM ou demorando por
swap/backpressure; ou o índice crescendo além do que o limite de regime
comporta. Migrar de perfil é trocar o `env.*` e o limite de memória no
deploy — nenhum rebuild.

**Motivação histórica do teto:** a config de produção do baseempresarial
permitia `MEILI_MAX_INDEXING_MEMORY` de **6 GiB** num host de 8 GB dividido
com Postgres e Redis — sentença de OOM. Todo perfil limita explicitamente.

## Implantação no Dokploy

1. No serviço `meilisearch` do projeto: fixar a imagem
   `ghcr.io/brasildatahub/meilisearch:1.34`.
2. Aplicar as envs do `env.<perfil>` escolhido (colar no painel de
   Environment), mais `MEILI_MASTER_KEY` (secreta — nunca commitada).
3. Conferir o volume de dados montado em `/meili_data`.
4. Limite de memória do serviço: o da tabela de perfis.
5. Redeploy e validar:

   ```bash
   curl -s http://localhost:7700/health          # {"status":"available"}
   curl -s -H "Authorization: Bearer $MEILI_MASTER_KEY" http://localhost:7700/stats
   ```

### Indexação grande (ex.: Base Empresarial — tarefa F10)

1. Aplicar `busca-16gb` ajustado à máquina (regra de dimensionamento acima).
2. Subir o limite de memória do serviço para ~2× o
   `MEILI_MAX_INDEXING_MEMORY` enquanto a reindexação roda.
3. Rodar a reindexação blue/green do `search-indexer-service` (AG15).
4. Após estabilizar, reduzir o limite para ~1,5× o tamanho do índice quente.

## Validação local

```bash
# antes da primeira publicação na CI, builde o wrapper localmente:
docker build -t ghcr.io/brasildatahub/meilisearch:1.34 .

MEILI_MASTER_KEY=local-test PROFILE=busca-512mb docker compose up -d
curl -s http://localhost:7700/health
```

> O compose local não expõe porta por padrão no Dokploy; para testar fora
> dele, adicione `ports: ["7700:7700"]` num override.
