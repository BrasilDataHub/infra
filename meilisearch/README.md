# meilisearch

## Papel

Módulo provisionável de busca textual via Meilisearch. Imagem `ghcr.io/brasildatahub/meilisearch` — wrapper pinado de `getmeili/meilisearch:v1.34`.

No BaseEmpresarial o motor de busca é o OpenSearch ([`opensearch/`](../opensearch/README.md)). Este módulo continua disponível via `setup.sh --services ...,meilisearch` para outros projetos da org.

Toda a configuração é por variável de ambiente; os perfis são arquivos `.env` em [`profiles/`](profiles/).

## Componentes / imagem

- Imagem: `ghcr.io/brasildatahub/meilisearch` (`getmeili/meilisearch:v1.34`)
- Compose: [`docker-compose.yml`](docker-compose.yml)
- Overlay de métricas: [`docker-compose.metrics.yml`](docker-compose.metrics.yml)
- Script de chave de scrape: [`metrics-key.sh`](metrics-key.sh)
- Volume: `bdh_meili_data` → `/meili_data` (LMDB via `mmap`; requer NVMe local)

## Perfis e configuração

| Perfil | MAX_INDEXING_MEMORY | Threads | Limite de container | Quando usar |
|---|---|---|---|---|
| `busca-512mb` | 256MiB | 1 | 512M | projetos pequenos (~170 mil docs); índices de MB a centenas de MB |
| `busca-1gb` | 1GiB | 1 | 1G | default; índices de poucos GB |
| `busca-4gb` | 2GiB | 2 | 4G na indexação; ~2G em regime | milhões de documentos |
| `busca-16gb` | 8GiB | 4 | ~16G durante indexação | dezenas de milhões de docs |

| Perfil | Arquivo |
|---|---|
| `busca-512mb` | [`profiles/busca-512mb.env`](profiles/busca-512mb.env) |
| `busca-1gb` | [`profiles/busca-1gb.env`](profiles/busca-1gb.env) |
| `busca-4gb` | [`profiles/busca-4gb.env`](profiles/busca-4gb.env) |
| `busca-16gb` | [`profiles/busca-16gb.env`](profiles/busca-16gb.env) |

Um perfil por deploy. Defaults no compose: `MEILI_ENV=production`, `MEILI_NO_ANALYTICS`, `MEILI_DB_PATH`.

Dimensionamento: `MEILI_MAX_INDEXING_MEMORY` ≈ metade da RAM do serviço; limite de container ≈ 2× durante indexação; em regime ≈ 1,5× o índice quente.

Migrar de perfil: trocar o `.env` e recriar o container — sem rebuild.

Indexação grande (ex. perfil `busca-16gb`):

1. Aplicar o perfil e ajustar à máquina.
2. Subir limite de memória para ~2× `MEILI_MAX_INDEXING_MEMORY` durante a reindexação.
3. Rodar reindexação blue/green do indexador do projeto.
4. Após estabilizar, reduzir limite para ~1,5× o índice quente.

Se dividir o host com Postgres, dimensionar pela [fórmula de coexistência](../postgres/docs/perfis.md#fórmula-de-reserva).

## Deploy / operação

```bash
BASE=https://raw.githubusercontent.com/BrasilDataHub/plataforma/main/meilisearch
curl -fsSL "$BASE/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$BASE/profiles/busca-1gb.env" -o .env

cat >> .env <<'EOF'
MEILI_MASTER_KEY=chave-secreta-de-no-minimo-16-bytes
# opcionais: BIND_IP, MEILI_PORT, MEILI_VOLUME
EOF
chmod 600 .env

docker compose up -d

docker inspect <container> --format 'Memory={{.HostConfig.Memory}}'   # ≠ 0
curl -s http://localhost:7700/health          # {"status":"available"}
curl -s -H "Authorization: Bearer $MEILI_MASTER_KEY" http://localhost:7700/stats
```

Em painel (Dokploy/Coolify): Compose stack com o mesmo YAML. Porta default `0.0.0.0:7700`; restringir com `BIND_IP` ou firewall. `docker compose down -v` apaga o volume.

Métricas (único overlay do repositório que altera o serviço base — muda env e recria o container; aplicar fora de janela de ETL):

```bash
docker compose -f docker-compose.yml -f docker-compose.metrics.yml up -d
MEILI_MASTER_KEY=... bash metrics-key.sh http://127.0.0.1:7700
```

`metrics-key.sh` cria chave escopada `metrics.get` (uid fixo; idempotente). `setup.sh --metrics` grava em `services/monitoring/secrets/meili-metrics.key`.

Validação local:

```bash
docker build -t ghcr.io/brasildatahub/meilisearch:1.34 .
MEILI_MASTER_KEY=local-test MEILI_MAX_INDEXING_MEMORY=256MiB docker compose up -d
curl -s http://localhost:7700/health
```

O compose de referência não publica porta; para teste local, override com `ports: ["7700:7700"]`.

## Variáveis e segredos

| Variável | Obrigatória | Descrição |
|---|---|---|
| `MEILI_MASTER_KEY` | sim (produção) | mínimo **16 bytes** com `MEILI_ENV=production`; nunca no git |
| `MEILI_MAX_INDEXING_MEMORY` | via perfil | teto de memória de indexação |
| `MEILI_EXPERIMENTAL_ENABLE_METRICS` | via overlay | liga `/metrics` (feature experimental; pin `v1.34`) |
| `BIND_IP`, `MEILI_PORT`, `MEILI_VOLUME` | não | publicação e volume |

`/metrics` exige ação `metrics.get` — não usar a master key no scrape.

## Restrições

- Índice em volume de rede degrada patologicamente (`mmap`/LMDB) — data-root do Docker no NVMe.
- Recriar o container ao ligar métricas interrompe indexação em andamento.
- Nomes de métrica podem mudar entre minors (feature experimental).
- Com coexistência Postgres + Meili, indexação despeja page cache do banco.

## Links

- [`../opensearch/README.md`](../opensearch/README.md)
- [Fórmula de coexistência](../postgres/docs/perfis.md#fórmula-de-reserva)
- [Layout de volumes](../postgres/docs/host.md#volumes-nomeados)
- [Rede](../postgres/docs/host.md#rede)
- [`../README.md`](../README.md) — `setup.sh`
