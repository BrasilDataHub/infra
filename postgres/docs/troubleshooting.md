# Troubleshooting — `ghcr.io/brasildatahub/postgres:17`

Sintomas observados em produção, com como confirmar e como corrigir.

Diagnóstico de 30 segundos — compara o que o deploy *declarou* com o que o
container *tem*:

```bash
C=<container>
docker exec $C df -h /dev/shm                                   # bate com o perfil?
docker logs $C 2>&1 | grep shm-guard                            # o guard reclamou?
docker inspect $C --format 'Memory={{.HostConfig.Memory}}'      # 0 = sem limite
docker exec $C psql -U postgres -d <db> -c \
  "SELECT name,setting FROM pg_settings WHERE name IN
   ('shared_buffers','work_mem','max_parallel_workers_per_gather');"
```

---

## 1. `could not resize shared memory segment`

```
ERROR:  could not resize shared memory segment "/PostgreSQL.3316007114"
        to 16814080 bytes: No space left on device
```

Em Python: `psycopg2.errors.DiskFull`. Aparece **horas depois do deploy**, na
primeira query paralela pesada — não no start.

**Não é o disco.** É o `tmpfs` de `/dev/shm`, em 64 MB.

**Confirmar:** `docker exec <c> df -h /dev/shm` — `64M` é o default do Docker.

**Causa.** Com `dynamic_shared_memory_type = posix`, as hash tables de Parallel
Hash Join e as filas de tuplas dos workers saem de `/dev/shm`. O pico é:

```
(max_parallel_workers_per_gather + 1) × work_mem × hash_mem_multiplier × nós de hash
```

No `dedicada-16gb`, dois Parallel Hash Join aninhados pedem
`5 × 32MB × 2.0 × 2 = 640 MB` — dez vezes o disponível.

**Por que quebrou justo ao migrar para uma máquina maior?** Porque o pico cresce
com o perfil e o `/dev/shm` não: de `(2+1) × 16MB × 2.0 = 96 MB` no
`dedicada-8gb` para `320 MB` por hash table no `dedicada-16gb`. Subir de máquina
**aumenta** a chance do erro. Foi o que aconteceu na Base Empresarial em
25/07/2026, com um serviço criado pela seção Databases do Dokploy — onde o
`shm_size` do compose é descartado sem aviso.

**Correção:** aplicar o `/dev/shm` do perfil com o mount `tmpfs` da
[receita de deploy](deploy.md#a-receita) — funciona em Compose e em Swarm. Em
serviço Swarm já no ar, sem recriar o stack:

```bash
docker service update \
  --mount-add type=tmpfs,destination=/dev/shm,tmpfs-size=2147483648 <servico>
```

**Mitigação sem restart** (quando não se pode reiniciar agora):

```sql
ALTER DATABASE <db> SET max_parallel_workers_per_gather = 0;
-- rode a carga pesada
ALTER DATABASE <db> RESET max_parallel_workers_per_gather;
```

Sem paralelismo não há Parallel Hash: a hash table vai para a memória privada do
backend, com spill para arquivos temporários. Mais lento, mas não quebra.

**Prevenção:** desde 2026-07 a imagem mede o `/dev/shm` no start
([`shm-guard.sh`](../shm-guard.sh)) e, por default, reduz o paralelismo até
caber. Em produção crítica, `PG_SHM_PREFLIGHT=fail` impede que um deploy mal
configurado entre no ar.

---

## 2. O container morre ou reinicia sozinho (OOM)

**Sintoma:** `Restarting`, `Exited (137)`, `dmesg | grep -i oom` no host.

**Confirmar:**
```bash
docker inspect <c> --format '{{.State.ExitCode}} {{.State.OOMKilled}}'
```

**Causa:** limite de memória incompatível com o bloco de envs —
`shared_buffers` e limite de container viajam juntos. Os valores estão na
[tabela de recursos](perfis.md#recursos-do-container) (≈87% do orçamento).

Duas armadilhas:

- **`Memory=0`** (sem limite): o Postgres pode pressionar o host inteiro e
  derrubar Redis/Meilisearch vizinhos. Comum quando o serviço é criado pela UI
  de um painel.
- **Kubernetes com `emptyDir` em memória:** o `/dev/shm` conta contra o limite;
  dimensione como `perfil + /dev/shm`.

---

## 3. O Postgres não sobe depois de mudar envs

**Sintoma:** loop de restart, com erro de sintaxe apontando uma linha do
`postgresql.conf` (`docker logs <c> 2>&1 | tail -30`).

**Causa:** env `PG_*` com valor inválido — `PG_WORK_MEM=32 MB` (com espaço),
`PG_JIT=true` em vez de `on`. Envs vazias já são tratadas pelos defaults
`${VAR:-...}` do [`generate-config.sh`](../generate-config.sh).

**Confirmar e corrigir:**

```bash
docker exec <c> grep -n <parametro> /etc/postgresql/postgresql.conf
```
```sql
SELECT sourceline, name, setting, applied, error
  FROM pg_file_settings WHERE NOT applied OR error IS NOT NULL;   -- deve vir vazio
```

Rode essa query depois de todo deploy — ela denuncia uma env inválida antes que
vire comportamento estranho semanas depois.

---

## 4. `max_parallel_workers_per_gather` menor do que o perfil pede

Não é bug: é o `shm-guard` degradando o paralelismo por `/dev/shm` insuficiente
(`PG_SHM_PREFLIGHT=adapt`, o default). Confirme com
`docker logs <c> 2>&1 | grep shm-guard` e corrija pelo [item 1](#1-could-not-resize-shared-memory-segment).
Com o `/dev/shm` correto, o valor do perfil volta no próximo start.

---

## 5. Um redeploy desfez a configuração

**Sintoma:** funcionava; depois de um deploy pelo painel, `/dev/shm` voltou a
64 MB ou o limite de memória sumiu.

**Causa:** ajustes por `docker service update` vivem **no serviço**, não na
definição que o painel guarda. Dokploy (e Coolify em modo Swarm) recriam o
serviço a partir da UI a cada redeploy.

**Correção durável:** ter o serviço como **Compose stack**, com o mount `tmpfs`
e o limite no YAML — ou, melhor, sair do painel
([deploy.md](deploy.md#se-for-obrigatório-usar-dokploy-ou-coolify)).

---

## 6. Queries derramando em disco (`temp files`)

**Sintoma:** `temporary file: path ..., size ...` no log (a imagem loga a partir
de 10 MB).

```sql
SELECT queryid, calls, temp_blks_written FROM pg_stat_statements
 WHERE temp_blks_written > 0 ORDER BY temp_blks_written DESC LIMIT 10;
```

**Causa:** `work_mem` insuficiente. Derramamento ocasional é normal e barato;
constante nas mesmas queries indica perfil apertado.

**Correção:** `work_mem` é ajustável a quente (reload). Antes de subir
globalmente, considere `SET work_mem` só na sessão analítica — o valor vale
**por operação**, então subir para todas as conexões multiplica o consumo.

> Ao subir `work_mem` ou `hash_mem_multiplier`, **recalcule o `/dev/shm`**: o
> pico de Parallel Hash cresce junto ([item 1](#1-could-not-resize-shared-memory-segment)).

---

## 7. O perfil foi aplicado pela metade

**Sintoma:** as envs `PG_*` estão certas em `pg_settings`, mas o comportamento
não corresponde ao perfil.

**Causa:** o bloco de envs foi colado e os **recursos do container**
(`/dev/shm`, limite de memória) ficaram para trás. É o modo de falha mais comum
desta imagem.

**Confirmar:** os 4 comandos da
[verificação pós-deploy](deploy.md#verificação-pós-deploy).

---

## 8. `huge_pages` sem efeito

`huge_pages = try` cai silenciosamente para páginas normais se o host não
reservou hugepages. Confirme com `SHOW huge_pages_status;` e reserve conforme
[host.md](host.md#huge-pages). Só compensa a partir de `shared_buffers` ≥ 16 GB.

---

## Ver também

- [deploy.md](deploy.md) — a receita e a verificação pós-deploy
- [perfis.md](perfis.md) — parâmetros e justificativas
- [host.md](host.md) — preparação da máquina
