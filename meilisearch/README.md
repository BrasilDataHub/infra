# meilisearch — imagem Meilisearch da organização

Imagem `ghcr.io/brasildatahub/meilisearch` — wrapper **pinado** de
`getmeili/meilisearch:v1.34` (mesma minor da produção) para manter todos os
serviços de infra sob o namespace da org. Toda a configuração do Meilisearch
é por variável de ambiente; os perfis são blocos de env documentados abaixo,
prontos para copiar e colar no deploy.

## Perfis por orçamento de memória

Os perfis são definidos pelo tamanho dos índices e pelo orçamento de RAM do
serviço — independentes de projeto e de fornecedor:

| Perfil | MAX_INDEXING_MEMORY | Threads | Limite de container | Quando usar |
|---|---|---|---|---|
| `busca-512mb` | 256MiB | 1 | 512M | projetos pequenos (ex.: Base Escolar, ~170 mil docs); índices de MB a centenas de MB |
| `busca-1gb` | 1GiB | 1 | 1G | default; índices de poucos GB |
| `busca-4gb` | 2GiB | 2 | 4G na indexação; ~2G em regime | índices médios: milhões de documentos |
| `busca-16gb` | 8GiB | 4 | ~16G durante indexação | índices grandes: dezenas de milhões de docs (Base Empresarial pós-migração: 72M establishments + 26M partners, 15–25 GB) |

Blocos para colar no deploy (as demais envs — `MEILI_ENV=production`,
`MEILI_NO_ANALYTICS`, `MEILI_DB_PATH` — já têm default no compose de
referência; `MEILI_MASTER_KEY` é secreta, nunca commitada):

```env
# busca-512mb (limite de container: 512M)
MEILI_MAX_INDEXING_MEMORY=256MiB
MEILI_MAX_INDEXING_THREADS=1
MEILI_HTTP_PAYLOAD_SIZE_LIMIT=50MB

# busca-1gb (limite de container: 1G) — default do compose; colar é opcional
MEILI_MAX_INDEXING_MEMORY=1GiB
MEILI_MAX_INDEXING_THREADS=1
MEILI_HTTP_PAYLOAD_SIZE_LIMIT=100MB

# busca-4gb (limite de container: 4G na indexação; ~2G em regime)
MEILI_MAX_INDEXING_MEMORY=2GiB
MEILI_MAX_INDEXING_THREADS=2
MEILI_HTTP_PAYLOAD_SIZE_LIMIT=100MB

# busca-16gb (limite de container: ~16G durante indexação)
MEILI_MAX_INDEXING_MEMORY=8GiB
MEILI_MAX_INDEXING_THREADS=4
MEILI_HTTP_PAYLOAD_SIZE_LIMIT=250MB
```

Use o bloco de apenas UM perfil por deploy. Nomes antigos referenciados em
documentos do baseempresarial: `atual` → `busca-1gb`; `pos-migracao` →
`busca-16gb`.

**Regra de dimensionamento** (vale para qualquer perfil):
`MEILI_MAX_INDEXING_MEMORY` ≈ metade da RAM disponível para o serviço;
limite de container ≈ 2× esse valor **durante a indexação** (o Meili usa
memória além do teto de indexação para o próprio processo e mmap do índice).
Em regime (sem indexar), o limite pode cair para ~1,5× o índice quente.

> **A conferir no `busca-16gb`:** a tabela declara ~16G de limite, mas a regra
> de regime (1,5× o índice quente) daria mais que isso se o índice quente for
> próximo dos 15–25 GB totais. Os dois números precisam ser reconciliados com
> medição real do índice em produção. Até lá, a
> [coexistência com o Postgres](../postgres/docs/perfis.md#combinações-prováveis)
> usa os 16G declarados.

**Quando migrar de perfil:** indexação abortando por OOM ou demorando por
swap/backpressure; ou o índice crescendo além do que o limite de regime
comporta. Migrar de perfil é trocar o bloco de envs e o limite de memória no
deploy — nenhum rebuild.

**Motivação histórica do teto:** a config de produção do baseempresarial
permitia `MEILI_MAX_INDEXING_MEMORY` de **6 GiB** num host de 8 GB dividido
com Postgres e Redis — sentença de OOM. Todo perfil limita explicitamente.

## Implantação no Dokploy

1. No serviço `meilisearch` do projeto: fixar a imagem
   `ghcr.io/brasildatahub/meilisearch:1.34`.
2. Colar o bloco do perfil escolhido (acima) no painel de Environment,
   mais `MEILI_MASTER_KEY` (secreta — nunca commitada) e
   `MEILI_ENV=production`.
3. Conferir o volume de dados montado em `/meili_data`.
4. Limite de memória do serviço: o da tabela de perfis.
5. Redeploy e validar:

   ```bash
   curl -s http://localhost:7700/health          # {"status":"available"}
   curl -s -H "Authorization: Bearer $MEILI_MASTER_KEY" http://localhost:7700/stats
   ```

### Indexação grande (ex.: Base Empresarial)

1. Aplicar o bloco `busca-16gb` ajustado à máquina (regra de dimensionamento
   acima).
2. Subir o limite de memória do serviço para ~2× o
   `MEILI_MAX_INDEXING_MEMORY` enquanto a reindexação roda.
3. Rodar a reindexação blue/green do indexador do projeto.
4. Após estabilizar, reduzir o limite para ~1,5× o tamanho do índice quente.

> Se o Meilisearch dividir o host com o Postgres, a indexação despeja o page
> cache do banco — dimensione pela
> [fórmula de coexistência](../postgres/docs/perfis.md#fórmula-de-reserva) e,
> em bases grandes com busca textual, prefira separar os dois em máquinas
> distintas.

## Validação local

```bash
# antes da primeira publicação na CI, builde o wrapper localmente:
docker build -t ghcr.io/brasildatahub/meilisearch:1.34 .

MEILI_MASTER_KEY=local-test MEILI_MAX_INDEXING_MEMORY=256MiB docker compose up -d
curl -s http://localhost:7700/health
```

> O compose local não expõe porta por padrão no Dokploy; para testar fora
> dele, adicione `ports: ["7700:7700"]` num override.
