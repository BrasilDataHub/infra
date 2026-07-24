# infra/redis — cache + fila (Horizon)

Imagem `redis:7.4-alpine` com `redis.conf` versionado embutido. Papel:
cache da aplicação Laravel e fila do Horizon — 512 MB bastam.

## Decisões de configuração

- **`maxmemory 512mb` + limite de container 512 MB** — hoje o Redis roda sem
  teto no host de 8 GB.
- **`maxmemory-policy volatile-lru`** — despeja só chaves **com TTL** (cache).
  As chaves de fila/Horizon não têm TTL e nunca são despejadas; por isso a
  política é segura para cache+fila na mesma instância. `allkeys-lru`
  poderia descartar jobs pendentes; `noeviction` faria writes de cache
  falharem no limite.
- **`appendonly yes` (AOF, fsync a cada segundo)** — jobs enfileirados
  sobrevivem a restart.
- **Senha** via env `REDIS_PASSWORD` (a conf não lê env; o CMD anexa
  `--requirepass`).

## Implantação no Dokploy (tarefa F4)

1. No serviço `redis` do projeto `baseempresarial`, trocar a imagem para
   `ghcr.io/<owner>/baseempresarial-redis:7`.
2. Definir env `REDIS_PASSWORD` (a mesma que o website/Horizon usam).
3. Conferir volume de dados montado em `/data`.
4. Limite de memória do serviço: **512 MB**.
5. Redeploy e validar:

   ```bash
   redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory        # 536870912
   redis-cli -a $REDIS_PASSWORD CONFIG GET maxmemory-policy # volatile-lru
   redis-cli -a $REDIS_PASSWORD CONFIG GET appendonly       # yes
   ```

## Validação local

```bash
docker build -t baseempresarial-redis:7 .
docker run -d --name redis-test -e REDIS_PASSWORD=test baseempresarial-redis:7
docker exec redis-test redis-cli -a test CONFIG GET maxmemory-policy
```
