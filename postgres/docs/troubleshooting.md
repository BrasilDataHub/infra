# Troubleshooting — `ghcr.io/brasildatahub/postgres:17`

Diagnóstico rápido:

```bash
C=<container>
docker exec $C df -h /dev/shm                                   # bate com o perfil?
docker logs $C 2>&1 | grep shm-guard                            # o guard reclamou?
docker inspect $C --format 'Memory={{.HostConfig.Memory}}'      # 0 = sem limite
docker exec $C psql -U postgres -d <db> -c \
  "SELECT name,setting FROM pg_settings WHERE name IN
   ('shared_buffers','work_mem','max_parallel_workers_per_gather');"
```

## 1. `could not resize shared memory segment`

```
ERROR:  could not resize shared memory segment "/PostgreSQL.…"
        to … bytes: No space left on device
```

Em Python: `psycopg2.errors.DiskFull`. Aparece na primeira query paralela pesada,
não no start.

**Não é o disco** — é `/dev/shm` em 64 MB (default Docker).

**Confirmar:** `docker exec <c> df -h /dev/shm` → `64M`.

**Causa:** com `dynamic_shared_memory_type = posix`, Parallel Hash Join e filas
de workers usam `/dev/shm`. Pico:

```
(max_parallel_workers_per_gather + 1) × work_mem × hash_mem_multiplier × nós de hash
```

Ex.: `dedicada-16gb`, dois Parallel Hash aninhados:
`5 × 32MB × 2.0 × 2 = 640 MB`. Pico cresce com o perfil; `/dev/shm` default não.
Swarm descarta `shm_size` — use mount `tmpfs`.

**Correção:** [receita](deploy.md#receita). Em Swarm já no ar:

```bash
docker service update \
  --mount-add type=tmpfs,destination=/dev/shm,tmpfs-size=2147483648 <servico>
```

**Mitigação sem restart:**

```sql
ALTER DATABASE <db> SET max_parallel_workers_per_gather = 0;
-- carga pesada
ALTER DATABASE <db> RESET max_parallel_workers_per_gather;
```

Sem paralelismo a hash table vai à memória privada do backend (spill em temp).

**Prevenção:** `shm-guard.sh` no start; `PG_SHM_PREFLIGHT=fail` em produção
crítica impede deploy mal configurado.

## 2. Container morre / reinicia (OOM)

**Sintoma:** `Restarting`, `Exited (137)`, `dmesg | grep -i oom`.

```bash
docker inspect <c> --format '{{.State.ExitCode}} {{.State.OOMKilled}}'
```

**Causa:** limite incompatível com envs — ver
[recursos do container](perfis.md#recursos-do-container) (≈87% do orçamento).

- **`Memory=0`:** sem limite; Postgres pressiona o host (comum em UI de painel).
- **K8s `emptyDir` memória:** `/dev/shm` conta no limite → `perfil + /dev/shm`.

## 3. Postgres não sobe após mudar envs

Loop de restart; erro de sintaxe no `postgresql.conf`
(`docker logs <c> 2>&1 | tail -30`).

Env inválida: `PG_WORK_MEM=32 MB` (espaço), `PG_JIT=true` (use `on`).

```bash
docker exec <c> grep -n <parametro> /etc/postgresql/postgresql.conf
```
```sql
SELECT sourceline, name, setting, applied, error
  FROM pg_file_settings WHERE NOT applied OR error IS NOT NULL;
```

## 4. `max_parallel_workers_per_gather` menor que o perfil

`shm-guard` degradando (`PG_SHM_PREFLIGHT=adapt`). Confirme
`docker logs <c> 2>&1 | grep shm-guard` e corrija pelo [item 1](#1-could-not-resize-shared-memory-segment).

## 5. Redeploy desfez a configuração

`/dev/shm` voltou a 64 MB ou limite sumiu. Ajustes por `docker service update`
vivem no serviço, não na UI. Correção: **Compose stack** com `tmpfs` + limite no
YAML, ou Compose direto ([deploy.md](deploy.md#dokploy--coolify)).

## 6. Queries em disco (`temp files`)

`temporary file: path ..., size ...` no log (a partir de 10 MB).

```sql
SELECT queryid, calls, temp_blks_written FROM pg_stat_statements
 WHERE temp_blks_written > 0 ORDER BY temp_blks_written DESC LIMIT 10;
```

`work_mem` insuficiente — ocasional é normal; constante = perfil apertado.
Ajuste a quente (reload). Preferir `SET work_mem` na sessão analítica.
Ao subir `work_mem` / `hash_mem_multiplier`, **recalcule `/dev/shm`**.

## 7. Perfil pela metade

Envs certas em `pg_settings`, comportamento errado: faltaram recursos do
container (`/dev/shm`, limite). Confirme a
[verificação pós-deploy](deploy.md#verificação-pós-deploy).

## 8. `huge_pages` sem efeito

`huge_pages = try` cai silenciosamente. `SHOW huge_pages_status;` e reserve
conforme [host.md](host.md#huge-pages). Só compensa com `shared_buffers` ≥ 16 GB.

## Ver também

- [deploy.md](deploy.md)
- [perfis.md](perfis.md)
- [host.md](host.md)
