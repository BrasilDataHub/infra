# Por que Docker Compose — decisão de estratégia de deploy

**Data:** 2026-07-25 · **Escopo:** Postgres (prioritário), Redis e Meilisearch.

Registro da decisão: *como* implantar as imagens deste repositório em máquinas
dedicadas a banco. O *como fazer* está em [deploy.md](deploy.md); aqui está o
porquê, para quem precisar rever a escolha depois.

## Resumo

**Docker Compose direto no host, versionado neste repositório.** Se um painel
for obrigatório, usá-lo em modo **Compose stack** — nunca em modo banco
gerenciado. Redis e Meilisearch podem permanecer onde estão.

> **Nota de 2026-07-26 — armazenamento.** Este documento defendeu bind mounts
> como forma de garantir o NVMe local. A decisão foi revista: como todas as
> instâncias da org rodam em NVMe, inclusive no disco de sistema, bind mount e
> volume nomeado têm a mesma performance, e o padrão passou a ser **volume
> nomeado com driver `local`** — menos configuração customizada, driver default
> do Docker ([justificativa](../../README.md#dados-em-volumes-nomeados)). O
> controle que o bind dava virou uma checagem explícita do data-root
> ([host.md](host.md#confirme-que-o-docker-está-no-nvme)). Nada disso muda a
> conclusão sobre Compose vs. painel abaixo.

---

## O que está em jogo

As envs `PG_*` — 49 parâmetros que geram o `postgresql.conf` — chegam íntegras
em **qualquer** plataforma. Nenhuma delas é sobrescrita por Dokploy, Coolify ou
Compose. **O risco nunca esteve nas envs.**

Está nas superfícies que *não* são env: `/dev/shm`, limite de memória, o volume
de dados e a publicação da porta. São quatro de sete, e é nelas que as
plataformas divergem.

Redis e Meilisearch não têm a superfície `/dev/shm` — dependem só de envs e do
limite de memória, bem suportados em toda parte.

## O incidente de 25/07/2026

Migração do Postgres da Base Empresarial de um host de 8 GB para um de 32 GB.
Envs do perfil aplicadas e conferidas em `pg_settings`. 6h43 de ETL depois, na
última etapa:

```
psycopg2.errors.DiskFull: could not resize shared memory segment ...
```

Cadeia causal:

1. `dynamic_shared_memory_type = posix` põe as hash tables de Parallel Hash Join
   em `/dev/shm`, que em container tem 64 MB por default.
2. O perfil pede 1–8 GB, declarado no compose do repositório desde sempre.
3. **O Dokploy orquestra via Swarm, e o `ContainerSpec` do Swarm não tem campo
   `shm_size`** — a linha é descartada sem erro nem aviso.
4. O serviço fora criado pela seção **Databases**, que não expõe `/dev/shm` nem
   mount `tmpfs`.
5. O pico exigido cresce com o perfil: subir de máquina *aumentou* a demanda de
   `/dev/shm` (~6,7×) enquanto o disponível seguiu em 64 MB.

**Causa raiz: a plataforma.** A configuração correta estava versionada e teria
funcionado em `docker compose up`. O que a perdeu foi a tradução para Swarm.
Não é um bug do Dokploy — é uma limitação do Swarm que ele herda e não sinaliza
—, e havia um caminho correto dentro do próprio painel (Compose stack com mount
`tmpfs`). A operação caiu na armadilha por usar o modo gerenciado.

Agravante: `docker inspect` **não** reflete o `/dev/shm` real quando ele vem de
um mount `tmpfs`. A verificação óbvia mente; só `df -h /dev/shm` dentro do
container diz a verdade.

### A classe do problema, não o bug

O `shm-guard` (na imagem desde 2026-07) cobre esse sintoma em qualquer
plataforma. **Não cobre os outros da mesma família**, todos documentados em
[troubleshooting.md](troubleshooting.md):

- `Memory=0` quando o serviço é criado pela UI — Postgres sem limite de memória;
- **`BIND_IP` ignorado**: em Swarm o bind numa interface específica não é
  respeitado (verificado — `docker stack config` avisa `service will listen on
  '0.0.0.0'`), então quem quis restringir a interface não conseguiu;
- redeploy pelo painel descartando ajustes feitos por `docker service update`;
- data-root do Docker fora do NVMe, o que joga o volume de dados no disco errado
  sem que nada no compose denuncie ([host.md](host.md#confirme-que-o-docker-está-no-nvme)).

O denominador comum: **a camada de deploy traduz a intenção declarada, e a
tradução pode perder informação em silêncio.**

---

## Comparação

Cenário: máquina dedicada a banco, 1–3 containers, sem cluster, sem rolling
update (um banco com volume único não tem para onde rolar).

| Critério | Compose | Dokploy (Swarm) | Coolify | `docker run` |
|---|---|---|---|---|
| Envs `PG_*` | ✅ íntegras | ✅ íntegras | ✅ íntegras | ✅ íntegras |
| `/dev/shm` | ✅ nativo | ❌ `shm_size` descartado; exige mount `tmpfs` | ⚠️ ok em standalone, descartado em Swarm | ✅ `--shm-size` |
| Limite de memória | ✅ verificado¹ | ⚠️ `Memory=0` se criado pela UI | ⚠️ idem | ✅ `--memory` |
| Bind numa interface (`BIND_IP`) | ✅ | ❌ ignorado em Swarm | ⚠️ depende do modo | ✅ |
| Fonte da verdade | ✅ o git | ❌ o banco do painel | ⚠️ o banco do painel | ❌ a linha de comando |
| Sobrevive a redeploy | ✅ o arquivo é o deploy | ⚠️ só o que a UI guarda | ⚠️ idem | ❌ nada declarativo |
| Operação (restart/log) | ✅ CLI | ✅ painel | ✅ painel | ⚠️ crua |
| Overhead | ✅ um YAML | ⚠️ painel + Swarm + Traefik no host do banco | ⚠️ painel no host do banco | ❌ config tácita |

¹ verificado nesta análise (Docker 29.4.0, Compose v5.1.2): `docker compose up`
aplica `deploy.resources.limits.memory` e o mount `tmpfs` em `/dev/shm`
corretamente; `docker stack config` preserva o mount `tmpfs`.

Sobre backup e monitoramento, que costumam ser o argumento a favor do painel:
para um banco de 116 GB com PITR, o que importa é **pgBackRest + snapshot do
provedor**, operados no host ([backup/](../backup/)). O backup gerenciado do
painel não substitui isso — então o argumento quase não se aplica aqui.

---

## Recomendação

**Postgres → Compose direto**, pelos motivos em ordem de peso:

1. `/dev/shm`, limite e bind de porta funcionam nativamente — a parte frágil do
   perfil deixa de depender de receita de plataforma.
2. O git volta a ser a fonte da verdade. O incidente não foi só sobre
   `/dev/shm`: foi sobre a configuração correta estar versionada e não ser a
   que rodava.
3. O painel não entrega, neste host, aquilo para que foi feito: sem build, sem
   HTTP, sem TLS, sem rolling update. Cobra complexidade sem pagar
   funcionalidade.
4. Redeploy deixa de ser um evento de risco — não há definição paralela.

**Se sair do painel não for viável:** recurso do tipo **Compose stack** com o
YAML de [deploy.md](deploy.md#a-receita) (mount `tmpfs`, limite de memória,
porta não publicada), nunca a seção Databases. Resolve o `/dev/shm` e versiona a
configuração; mantém o risco de drift, então a verificação pós-deploy continua
obrigatória a cada redeploy.

**Redis e Meilisearch → manter onde estão.** Não têm a superfície `/dev/shm`;
migrar compra consistência, não correção. Vale confirmar que o limite de
memória está aplicado (`HostConfig.Memory` ≠ 0) — o Redis é sensível: com AOF
ligado, o rewrite forka e pode dobrar a memória do processo. Quando dividirem
host com o Postgres, movem-se junto com ele, sob a
[fórmula de reserva](perfis.md#fórmula-de-reserva).

---

## Próximos passos de validação

1. **Reproduzir em laboratório.** Com `tmpfs.size` reduzido para 64 MB e envs de
   um perfil maior ([`docker-compose.local.yml`](../docker-compose.local.yml)),
   confirmar que o guard degrada em vez de deixar quebrar — e que, com o
   `/dev/shm` correto, ele não interfere no paralelismo do perfil.
2. **Ensaiar num host de staging.** Subir o compose do perfil-alvo, rodar a
   [verificação pós-deploy](deploy.md#verificação-pós-deploy) e testar o que o
   painel fazia por baixo: reboot do host com `restart: unless-stopped`, driver
   e rotação de log, healthcheck refletindo o estado real.
3. **Fechar as lacunas antes de migrar:** backup (pgBackRest + snapshot),
   acesso SSH e runbook curto, destino dos logs, segredos em `.env` restrito ou
   Docker secret. ✅ *Observabilidade: resolvida —* `postgres_exporter`,
   Prometheus e Grafana estão em [`../../monitoring/`](../../monitoring/), com a
   role de leitura e os coletores documentados em [metricas.md](metricas.md).
   Ligue numa instalação existente com `infra-setup.sh --metrics-only`, que não
   recria o container do banco.
4. **Migrar produção com janela:** backup verificado por restauração → parar o
   serviço no painel **sem remover o volume** → subir o compose apontando para o
   mesmo diretório de dados → verificação pós-deploy → rodar a etapa de ETL que
   quebrou em 25/07 como teste de aceitação → manter o serviço antigo parado
   (não removido) como rollback por uma janela acordada.

---

## Ver também

- [deploy.md](deploy.md) — a receita, as ressalvas de painel e a verificação
- [troubleshooting.md](troubleshooting.md) — os modos de falha observados
- [perfis.md](perfis.md) — os perfis e seus parâmetros
