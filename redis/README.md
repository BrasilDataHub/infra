# redis — imagem Redis da organização

Imagem `ghcr.io/brasildatahub/redis` (base `redis:7.4-alpine`) — o Redis
padrão dos projetos BrasilDataHub. Papel: cache de aplicação Laravel e fila
do Horizon.

É uma **imagem única**: a conf base (`redis.conf`) é embutida e o
dimensionamento vem de envs no start — trocar de perfil é trocar envs no
deploy, nenhum rebuild:

| Env | Default | O que controla |
|---|---|---|
| `REDIS_MAXMEMORY` | `512mb` | teto de memória de dados |
| `REDIS_MAXMEMORY_POLICY` | `volatile-lru` | política de despejo |
| `REDIS_PASSWORD` | — | anexa `--requirepass` (a conf não lê env) |

## Perfis por orçamento de memória

Os perfis são definidos pelo orçamento de memória do serviço, independentes
de projeto e de fornecedor. Cada perfil é um bloco de envs para **copiar e
colar** no deploy (Environment do Dokploy ou `.env` do compose):

| Perfil | maxmemory | Limite de container | Quando usar |
|---|---|---|---|
| `cache-256mb` | 256mb | **512M** | projetos pequenos (ex.: Base Escolar): cache + fila leve |
| `cache-512mb` | 512mb | **1G** | default da imagem; aplicação de produção com cache + Horizon (Base Empresarial) |
| `cache-1gb` | 1gb | **2G** | cache pesado ou várias aplicações (um database lógico por app) |
| `cache-2gb` | 2gb | **3G** | teto do catálogo; acima disso, separe instâncias por projeto |

```env
# cache-256mb (limite de container: 512M)
REDIS_MAXMEMORY=256mb

# cache-512mb (limite de container: 1G) — default da imagem; colar é opcional
REDIS_MAXMEMORY=512mb

# cache-1gb (limite de container: 2G)
REDIS_MAXMEMORY=1gb

# cache-2gb (limite de container: 3G)
REDIS_MAXMEMORY=2gb
```

Em todos os perfis, `REDIS_MAXMEMORY_POLICY` fica no default `volatile-lru`
(ver decisões abaixo); use o bloco de apenas UM perfil por deploy.

Se o Redis dividir o host com o Postgres, é o **limite de container** da tabela
acima (não o `maxmemory`) que entra na
[fórmula de coexistência](../postgres/docs/perfis.md#fórmula-de-reserva).

**Por que o limite de container é ~2× o maxmemory:** com AOF ligado, o
rewrite periódico faz `fork()` e as páginas copy-on-write podem
temporariamente dobrar a memória do processo. Limite de container igual ao
`maxmemory` (como já rodou em produção) arrisca OOM-kill exatamente durante
o rewrite. O headroom encolhe proporcionalmente nos perfis maiores porque o
pico de COW depende da taxa de escrita, não do tamanho total.

**Quando migrar de perfil:** `evicted_keys` crescendo em `INFO stats`
(cache sendo despejado cedo demais) ou `used_memory` estacionado no
`maxmemory`. Se a fila (chaves sem TTL) dominar o uso, o problema não é
perfil de cache — é backlog de jobs; investigue o Horizon antes de subir
memória.

## Decisões de configuração (base fixa da imagem)

- **`volatile-lru`** — despeja só chaves **com TTL** (cache). As chaves de
  fila/Horizon não têm TTL e nunca são despejadas; por isso a política é
  segura para cache+fila na mesma instância. `allkeys-lru` poderia descartar
  jobs pendentes; `noeviction` faria writes de cache falharem no limite.
  Instâncias **só de cache** (sem fila) podem usar `allkeys-lru` via
  `REDIS_MAXMEMORY_POLICY`.
- **`appendonly yes` (AOF, fsync a cada segundo)** — jobs enfileirados
  sobrevivem a restart.

## Implantação no Dokploy

1. No serviço `redis` do projeto, trocar a imagem para
   `ghcr.io/brasildatahub/redis:7`.
2. Colar o bloco do perfil escolhido (tabela acima) no painel de
   Environment, mais `REDIS_PASSWORD` (a mesma que a aplicação/Horizon usam).
3. Conferir volume de dados montado em `/data`.
4. Limite de memória do serviço: o da tabela de perfis (headroom do AOF).
5. Redeploy e validar:

   ```bash
   redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory        # bytes do perfil
   redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory-policy # volatile-lru
   redis-cli -a $REDIS_PASSWORD CONFIG GET appendonly       # yes
   ```

## Validação local

```bash
docker build -t brasildatahub-redis:7 .
docker run -d --name redis-test -e REDIS_MAXMEMORY=256mb \
    -e REDIS_PASSWORD=test brasildatahub-redis:7
docker exec redis-test redis-cli -a test CONFIG GET maxmemory  # 268435456
```
