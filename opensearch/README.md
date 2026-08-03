# opensearch

## Papel

Motor de busca da BrasilDataHub. Imagem `ghcr.io/brasildatahub/opensearch` com analisadores de português comercial brasileiro, lista de sinônimos e plugin de métricas embutidos.

Roda no host de dados (`bdh-data`), ao lado do PostgreSQL. O mínimo viável é ~13,1 GiB (heap + direct + metaspace + threads + page cache do índice).

## Componentes / imagem

- Imagem: `ghcr.io/brasildatahub/opensearch`
- Mapping versionado: [`index/busca_estabelecimento.json`](index/busca_estabelecimento.json)
- Alertas: [`../monitoring/prometheus/rules/opensearch.rules.yml`](../monitoring/prometheus/rules/opensearch.rules.yml) (10 regras)
- Alias versionado gerenciado pelo `search-indexer-service` — a aplicação consulta o **alias**, nunca o índice físico

Orçamento típico no `bdh-data` (31 GiB) com perfil `compartilhada-8gb`:

```
bdh-data (31 GiB)
  kernel, docker, sshd, exporters ....  1,5 GiB
  PostgreSQL .........................  14,0 GiB   (perfil compartilhada-14gb)
  OpenSearch .........................   8,0 GiB   (perfil compartilhada-8gb)
  page cache livre ...................   7,5 GiB
```

O `mmap` do Lucene não conta no RSS do cgroup — conta como page cache reclamável.

## Perfis e configuração

| Perfil | Máquina-alvo | Limite | Heap | Page cache livre |
|---|---|---|---|---|
| `compartilhada-8gb` | host de 31 GiB **dividido** com o PostgreSQL | 8 GiB | 4 GiB | 7,5 GiB |
| `dedicada-16gb` | host de 15,6 GiB **só** do motor | 10 GiB | 5 GiB | 4,1 GiB |
| `dev-4gb` | desenvolvimento: arquitetura inteira em ~16 GiB | 4 GiB | 2 GiB | ~1 GiB |

O `setup.sh` escolhe com `--opensearch-profile auto` (default): ao lado de Postgres/Redis/Meilisearch → `compartilhada-8gb`; sozinho em máquina ≥ 14 GiB → `dedicada-16gb`.

`dev-4gb` é **sempre explícito** (`--opensearch-profile dev-4gb`). O `auto` não o escolhe. Preserva breakers, watermarks, `number_of_shards` 6 e o mapping; não serve de referência de latência nem de tamanho de lote de carga.

Decisões do mapping (alterar exige reindexar ~72,32 M documentos):

| Decisão | Valor |
|---|---|
| `number_of_shards` | **6** |
| `_source` | **desabilitado** (hidratação por PK no Postgres) |
| `auto_expand_replicas` | **`0-1`** |

Analisadores:

- Sem stemmer (`light_portuguese` destruiria precisão em nomes comerciais).
- `br_forma_juridica` como stopword (ex.: `LTDA` em ~70% dos documentos).
- Sinônimos só em tempo de busca (`updateable: true`); reload sem reindexar.
- Nenhum termo da lista de sinônimos pode ser stopword do mesmo analisador — o `synonym_graph` roda depois de `br_stop` e a criação do índice falha.
- `razao_social` e `nome_fantasia` usam `index_options: positions` e `norms: true` (autocomplete / phrase queries).

`merge.scheduler`, `refresh_interval` e `translog.*` são settings de **índice** em [`index/busca_estabelecimento.json`](index/busca_estabelecimento.json) — não vão em `opensearch.yml`/env do container.

## Deploy / operação

Sysctl obrigatório (sem ele o container sobe e morre no bootstrap check):

```bash
sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-opensearch.conf
```

```bash
curl -fsSL .../opensearch/profiles/compartilhada-8gb.env -o .env
docker compose up -d
docker compose logs -f opensearch
```

Criar o índice:

```bash
curl -X PUT localhost:9200/busca_estabelecimento_v1 \
  -H 'Content-Type: application/json' \
  --data-binary @index/busca_estabelecimento.json
```

Janela de carga:

```bash
# ANTES
curl -X PUT "$OS/_cluster/settings" -H 'Content-Type: application/json' \
  -d '{"transient":{"indices.breaker.total.limit":"85%"}}'
curl -X PUT "$OS/<indice>/_settings" -H 'Content-Type: application/json' \
  -d '{"index":{"refresh_interval":"-1","merge.scheduler.max_thread_count":4}}'

# DEPOIS (obrigatório — refresh_interval persiste)
curl -X PUT "$OS/<indice>/_settings" -H 'Content-Type: application/json' \
  -d '{"index":{"refresh_interval":"30s","merge.scheduler.max_thread_count":1}}'
```

| Situação | Ação |
|---|---|
| `flood_stage` (disco > 90%) | Índices ficam read-only e **não** voltam sozinhos: após liberar espaço, `PUT /_all/_settings {"index.blocks.read_only_allow_delete": null}` |
| Divergência de contagem com Postgres | **Não mova o alias.** Índice N−1 permanece por 7 dias |
| Editar sinônimos | `POST /busca_estabelecimento/_reload_search_analyzers` |
| Perfil `dev-4gb` na carga | `OPENSEARCH_BULK_SIZE=1500` + `refresh_interval: -1` (default 5000 dispara breaker parent) |

Após carga em `dev-4gb`, antes de validar SLO: devolver `refresh_interval`/`breaker`, `_refresh`, aquecer page cache dos segmentos, então `opensearch publicar --load-id AAAAMM --somente-validar`.

```bash
bash opensearch/test/opensearch.test.sh
```

Sobe um nó, cria o índice com o mapping e exercita analisadores (17 asserções).

Latência p95 por classe de SLO vem do `blackbox_exporter` (plugin de exporter não expõe histograma de latência). Sinal de saturação de escrita: fila do thread pool (não há contador de rejeição).

## Variáveis e segredos

Perfil [`profiles/compartilhada-8gb.env`](profiles/compartilhada-8gb.env) traz heap, breakers, watermarks e limites do container.

| Variável | Default | Descrição |
|---|---|---|
| `OS_CLUSTER_NAME` | `bdh` | nome do cluster |
| `OS_NODE_NAME` | `opensearch` | nome do nó (usar hostname real) |
| `OS_VOLUME` | `bdh_os_data` | volume dos índices |
| `OS_SNAPSHOT_VOLUME` | `bdh_os_snapshots` | volume de snapshots (separado do de dados) |
| `OPENSEARCH_PORT` | `9200` | porta no host |
| `BIND_IP` | `0.0.0.0` | interface de publicação |

No perfil (valores de decisão):

| Variável | Valor | Nota |
|---|---|---|
| `OS_JAVA_OPTS` | `-Xms4g -Xmx4g -XX:MaxDirectMemorySize=1g` | `Xms == Xmx` sempre |
| `OS_BREAKER_FIELDDATA_LIMIT` | `0%` | mapping usa `doc_values`; fielddata = erro de consulta |
| `OS_WATERMARK_LOW` / `_HIGH` / `_FLOOD` | 75% / 85% / 90% | em flood todos os índices viram read-only |

## Restrições

- Não cabe no `bdh-apps` (~8 GiB totais já comprometidos).
- Aplicar `compartilhada-8gb` em host dedicado deixa RAM ociosa e o breaker `parent` (70% de 4 GiB) pode recusar carga inicial.
- Índice esquecido com `refresh_interval: -1` não atualiza para busca.
- Latência medida em `dev-4gb` não transfere para produção (~1 GiB vs 7,5 GiB de page cache).
- Com `_source` desabilitado, `_reindex` não tem de onde ler — mudanças de mapping entram na próxima carga completa.

## Links

- [`index/busca_estabelecimento.json`](index/busca_estabelecimento.json)
- [Alias versionado (search-indexer)](https://github.com/BrasilDataHub/baseempresarial-services/blob/main/services/search-indexer/docs/alias-versionado.md)
- [`../monitoring/prometheus/rules/opensearch.rules.yml`](../monitoring/prometheus/rules/opensearch.rules.yml)
- [`../meilisearch/README.md`](../meilisearch/README.md) — módulo alternativo, não usado no BaseEmpresarial
