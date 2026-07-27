# targets/

Este diretório está **vazio no repositório** de propósito: os alvos são do host,
não da imagem. No servidor ele fica em
`/opt/brasildatahub/services/monitoring/targets/` e é montado read-only no
Prometheus, que o relê a quente — acrescentar um arquivo aqui não exige restart.

Um arquivo por serviço que existe no host:

```json
[{"targets": ["postgres-exporter:9187"]}]
```

| Arquivo | Conteúdo |
|---|---|
| `postgres.json` | `postgres-exporter:9187` |
| `redis.json` | `redis-exporter:9121` |
| `meilisearch.json` | `meilisearch:7700` (endpoint nativo, sem exporter) |
| `node.json` | `node-exporter:9100` |
| `cadvisor.json` | `cadvisor:8080` |

Os endereços são nomes de **serviço** Compose, não de container: na rede
`bdh_metrics` o Docker registra o nome do serviço como alias, então eles não
dependem do nome do projeto Compose.

**Serviço que não existe não deve ter arquivo.** O `prometheus.yml` usa um glob
por job, então a ausência do arquivo deixa o job *sem alvo* — em vez de deixá-lo
`up == 0` para sempre, o que envenenaria o alerta `AlvoForaDoAr`, que é o mais
importante da stack.

O `infra-setup.sh --metrics` escreve estes arquivos conforme os serviços
selecionados. Para conferir o que o Prometheus enxerga:

```bash
bdh metrics
```
