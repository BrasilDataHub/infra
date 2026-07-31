# opensearch

Motor de busca da BrasilDataHub. Imagem `ghcr.io/brasildatahub/opensearch`, com
os analisadores de português comercial brasileiro, a lista de sinônimos e o
exporter de métricas embutidos.

## Por que ele existe

O dossiê de 23/07/2026 recomendou **manter** o Meilisearch e definiu seis
condições objetivas de invalidação. Quatro se confirmaram na medição de 28/07:

| Condição | Limite | Medido | |
|---|---|---|---|
| C1 · disco do índice acima de 2,2× do orçado | ≤ 121 GB | **167 GB** | ✅ |
| C2 · p95 com filtros a frio | ≤ 500 ms | **687 ms** | ✅ |
| C3 · reindexação mensal | ≤ 8 h | **> 56 h, sem concluir** | ✅ |
| C4 · produto exigir agregações analíticas | — | requisito | ✅ |

E há a prova de quem consome o servidor, sem instrumentar nada: em 80 h de
uptime o host leu **45,9 TB** do disco e o Postgres respondeu por 3,28 TB.
Sobram **42,6 TB — 93%** — com tamanho médio de requisição de leitura de 67 KB,
que é assinatura de `mmap` com readahead: o LMDB do Meilisearch.

## Onde ele roda, e por que não pode ser no outro host

No **`bdh-data`**, ao lado do PostgreSQL. O mínimo viável são 13,1 GiB
(heap + direct + metaspace + threads + page cache do índice); o `bdh-apps` tem
7,987 GiB **totais**, dos quais 7,292 já estão comprometidos. Não é questão de
apertar: falta mais do que existe.

```
bdh-data (31 GiB)
  kernel, docker, sshd, exporters ....  1,5 GiB
  PostgreSQL .........................  14,0 GiB   (perfil compartilhada-14gb)
  OpenSearch .........................   8,0 GiB   (perfil compartilhada-8gb)
  ------------------------------------------------
  page cache livre ...................   7,5 GiB   ✔
```

Os 7,5 GiB livres são o número que importa, e não o limite do container: o
`mmap` do Lucene **não conta no RSS do cgroup** — conta como page cache
reclamável. É ali que os 5,3 GB quentes do índice ficam residentes.

## O sysctl, que não é opcional

```bash
sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-opensearch.conf
```

Sem ele o container **sobe e morre** no bootstrap check, com uma mensagem que
fala de `vm.max_map_count` e não de OpenSearch. O `setup.sh` não tinha
etapa de sysctl até este roadmap (item 27).

## Deploy

```bash
curl -fsSL .../opensearch/profiles/compartilhada-8gb.env -o .env
docker compose up -d
docker compose logs -f opensearch
```

Criar o índice a partir do mapping versionado:

```bash
curl -X PUT localhost:9200/busca_estabelecimento_v1 \
  -H 'Content-Type: application/json' \
  --data-binary @index/busca_estabelecimento.json
```

> O nome físico termina com a versão/`load_id`; a aplicação consulta um
> **alias**, nunca o índice diretamente. Quem cria e move o alias é o
> `search-indexer-service` — ver
> [alias versionado](https://github.com/BrasilDataHub/baseempresarial-services/blob/main/services/search-indexer/docs/alias-versionado.md).

### Variáveis de ambiente

O perfil [`profiles/compartilhada-8gb.env`](profiles/compartilhada-8gb.env)
traz o dimensionamento — heap, breakers, watermarks e limites do container. O
que **não** está nele:

| Variável | Default | Descrição |
|---|---|---|
| `OS_CLUSTER_NAME` | `bdh` | nome do cluster |
| `OS_NODE_NAME` | `opensearch` | nome do nó. Aparece nos alertas e no `_cat/nodes` — **defina com o hostname real**: o default é neutro justamente porque um nome errado aqui não quebra nada em runtime e só aparece durante um incidente, apontando o plantão para o servidor errado |
| `OS_VOLUME` | `bdh_os_data` | volume dos índices |
| `OS_SNAPSHOT_VOLUME` | `bdh_os_snapshots` | volume do repositório de snapshot. Separado do de dados: um snapshot no mesmo volume não protege de nada |
| `OPENSEARCH_PORT` | `9200` | porta publicada no host |
| `BIND_IP` | `0.0.0.0` | interface de publicação |

E as que **estão** no perfil, mas cujo valor é uma decisão e não um número:

| Variável | Valor no perfil | Por quê |
|---|---|---|
| `OS_JAVA_OPTS` | `-Xms4g -Xmx4g -XX:MaxDirectMemorySize=1g` | `Xms == Xmx` sempre: heap que cresce fragmenta e o GC paga por isso. 4 GiB contra um on-heap projetado de < 700 MiB em regime |
| `OS_BREAKER_FIELDDATA_LIMIT` | `0%` | **de propósito.** O mapping usa `doc_values` em tudo que é agregado; qualquer uso de fielddata é erro de consulta, e o breaker o transforma em erro visível em vez de OOM |
| `OS_WATERMARK_LOW` / `_HIGH` / `_FLOOD` | 75% / 85% / 90% | em `flood_stage` **todos** os índices viram read-only, e não voltam sozinhos quando o disco esvazia — exige um `PUT` em `index.blocks.read_only_allow_delete` |

## As três decisões que não têm volta

Alterar qualquer uma delas depois exige **reindexar os 72,32 milhões de
documentos**. O teste de integração as afirma antes de a imagem ser publicada.

| Decisão | Valor | Por quê |
|---|---|---|
| `number_of_shards` | **6** | Paralelismo e divisibilidade, não tamanho: 6 pipelines nos 12 vCPU, e 6 divide bem em 1, 2, 3 e 6 nós |
| `_source` | **desabilitado** | É o que leva o índice de 138 para **8,4 GB**. A hidratação é por PK no Postgres, a 0,122 ms |
| `auto_expand_replicas` | **`0-1`** | Com réplicas fixas em 0 e um nó, o cluster fica YELLOW para sempre e o alerta de saúde perde significado |

## Os analisadores são decisão de produto

**Sem stemmer, deliberadamente.** `light_portuguese` transformaria
`ALIMENTOS → ALIMENT`, que casa com `ALIMENTAR`, `ALIMENTAÇÃO` e `ALIMENTÍCIA`.
`COMERCIO DE ALIMENTOS` já devolve mais de 251 mil linhas: stemming **aumenta o
recall onde não falta recall e destrói a precisão, que é o produto**.

**`br_forma_juridica` como stopword é o que mata os 687 ms.** `LTDA` aparece em
~70% dos 72,32 M documentos — sua postings list é praticamente o índice inteiro.
Removendo-o, `q=COMERCIO DE ALIMENTOS LTDA` custa o mesmo que sem o `LTDA`.

**Sinônimos só em tempo de busca**, com `updateable: true`: editar a lista é um
`POST /busca_estabelecimento/_reload_search_analyzers`, sem reindexar.

> **Nenhum termo da lista de sinônimos pode ser stopword do mesmo analisador.**
> O `synonym_graph` roda depois de `br_stop`, o termo chega vazio, e o
> OpenSearch recusa a **criação do índice** com `Failed to build synonyms`.
> Duas linhas da lista original caíram por isso (`com` e `cia`, ambas
> stopwords); há teste que afirma a regra.

### `index_options` decide se autocomplete existe

`razao_social` e `nome_fantasia` são **os dois campos do autocomplete**, e por
isso ambos precisam de `index_options: positions`. `nome_fantasia` estava em
`freqs` — que descarta as posições dos termos — e o efeito não é degradação, é
recusa:

```
HTTP 400 query_shard_exception
field:[nome_fantasia] was indexed without position data; cannot run PhraseQuery
```

Vale para `match_phrase`, `match_phrase_prefix` e `span_*`. Sem posições, a
única busca possível no campo é `match` com `operator: and`, que casa as
palavras em qualquer ordem e não sabe o que é prefixo: quem digita
`magazine lui` recebe `LUPI MAGAZINE` e `MAGAZINE MAGALICE` — palavras certas,
resultado errado.

`norms: true` no mesmo campo é a segunda metade: sem norms o motor não sabe que
`NATURA` é um nome fantasia inteiro e `BIO NATURA PRODUTOS NATURAIS` é uma
palavra dentro de um nome longo. É 1 byte por documento por campo.

Ambos exigem reindexação, mas isso não custa nada de novo: a carga mensal já
reconstrói o índice do zero a partir do Postgres. Vale entrar **antes** da
próxima carga — nunca depois, porque `_source` está desabilitado e `_reindex`
não tem de onde ler.

## Operação

| Situação | O que fazer |
|---|---|
| `flood_stage` atingido (disco > 90%) | Os índices ficam **read-only e não voltam sozinhos** quando o disco esvazia: `PUT /_all/_settings {"index.blocks.read_only_allow_delete": null}` depois de liberar espaço |
| Janela de carga | Subir `merge.scheduler.max_thread_count` para 4, `refresh_interval` para `-1` e o breaker `parent` para 85%; devolver a 1, `30s` e 70% no fim |
| Divergência de contagem com o Postgres | **Não mova o alias.** O índice N−1 continua servindo, e é por isso que ele é mantido por 7 dias |
| Editar sinônimos | `POST /busca_estabelecimento/_reload_search_analyzers` — sem reindexar |

## Alertas

`../monitoring/prometheus/rules/opensearch.rules.yml` — 10 regras, de zero.
Duas divergências em relação ao que o roadmap antecipava, verificadas num nó
3.3.0 real:

- não existe histograma de latência de busca no plugin de exporter (só
  counters), então o p95 por classe de SLO vem do `blackbox_exporter`;
- não há contador de rejeição por thread pool; o sinal equivalente é a **fila**
  do pool de escrita.

## Testes

```bash
bash opensearch/test/opensearch.test.sh
```

Sobe um nó de verdade, cria o índice com o mapping versionado e exercita os
analisadores com texto real de razão social. 17 asserções.

## Perfis

| Perfil | Máquina-alvo | Limite | Heap | Page cache livre |
|---|---|---|---|---|
| `compartilhada-8gb` | host de 31 GiB **dividido** com o PostgreSQL | 8 GiB | 4 GiB | 7,5 GiB |
| `dedicada-16gb` | host de 15,6 GiB **só** do motor de busca | 10 GiB | 5 GiB | 4,1 GiB |
| `dev-4gb` | **desenvolvimento**: host de ~16 GiB rodando a arquitetura inteira | 4 GiB | 2 GiB | ~1 GiB |

O `setup.sh` escolhe sozinho (`--opensearch-profile auto`, o default), e a
pergunta que ele faz **não é o tamanho da máquina — é com quem o motor divide
o host**. Ao lado de Postgres, Redis ou Meilisearch, `compartilhada-8gb`;
sozinho numa máquina de 14 GiB ou mais, `dedicada-16gb`.

### `dev-4gb` não é escolhido pelo `auto`

O terceiro perfil existe para uma máquina que os outros dois não atendem: a de
desenvolvimento que roda **Postgres, OpenSearch, Redis, PgBouncer e
observabilidade ao mesmo tempo** em ~16 GiB. Nela `compartilhada-8gb` não cabe
— 7 GiB de Postgres mais 8 de OpenSearch já passam da RAM física, e quem decide
o que morre é o OOM-killer.

Ele é **explícito por design**: `--opensearch-profile dev-4gb`. O `auto` não o
considera nem quando é o único que caberia, porque o host pequeno que roda tudo
é exatamente onde o `auto` cairia nele — e 2 GiB de heap num servidor de
verdade não falha na instalação, falha na carga mensal, com
`circuit_breaking_exception` a horas de distância de quem escolheu o perfil.

O que ele preserva de produção: breakers, watermarks, `number_of_shards` 6 e o
mapping inteiro. O que ele **não** preserva, e por isso não serve de referência:

- **latência.** Com ~1 GiB de page cache disputado com o PGDATA, busca fria vai
  ao disco onde produção serve da memória. Medição feita aqui não transfere.
- **tamanho de lote na carga.** O breaker `request` cai para ~800 MiB, e lotes
  de `_bulk` acima de ~10 MB passam a ser rejeitados.

### Por que o perfil errado não é só conservador

Aplicar `compartilhada-8gb` a um host dedicado deixa 10 GiB ociosos **e** faz o
breaker `parent` (70% de 4 GiB = 2,8 GiB) recusar a carga inicial. Medido em
29/07/2026, indexando os 72,3 M de estabelecimentos: em repouso o motor já
ocupava 1,8 GiB de heap, o pico de um lote não cabia no que sobrava, e a
indexação **parou em 2,46 M documentos** — HTTP 429 contínuo, CPU do motor em
0,5%, sem erro nenhum no log do serviço. Só esperando.

### A janela de carga, na ordem que importa

```bash
# ANTES da carga
curl -X PUT "$OS/_cluster/settings" -H 'Content-Type: application/json' \
  -d '{"transient":{"indices.breaker.total.limit":"85%"}}'
curl -X PUT "$OS/<indice>/_settings" -H 'Content-Type: application/json' \
  -d '{"index":{"refresh_interval":"-1","merge.scheduler.max_thread_count":4}}'

# DEPOIS — e isto não é opcional
curl -X PUT "$OS/<indice>/_settings" -H 'Content-Type: application/json' \
  -d '{"index":{"refresh_interval":"30s","merge.scheduler.max_thread_count":1}}'
```

O breaker vai como `transient` de propósito: um restart devolve o valor de
regime sozinho. Já o `refresh_interval` é do índice e **persiste** — um índice
esquecido em `-1` não atualiza para busca nunca mais, e o sintoma chega como
"o site não vê o dado novo", longe daqui.

Efeito medido do breaker em 85%: a indexação passou de **8,6 mil para 30,5 mil
documentos por segundo**.

### O que NÃO vai no perfil

`merge.scheduler`, `refresh_interval` e `translog.*` são settings de **índice**,
e o OpenSearch não os aceita em `opensearch.yml` — que é no que uma variável de
ambiente do container se transforma. Eles vivem em
[`index/busca_estabelecimento.json`](index/busca_estabelecimento.json).

Havia um `OS_MERGE_THREADS=1` no perfil que **nenhum lugar lia**: o compose não
o referencia e o motor não o aceitaria. O valor real sempre veio do mapping; a
variável só dava a impressão de configurar algo.
