# Preparação do host — o que fica fora do container

Os [perfis](perfis.md) dimensionam o que roda **dentro** do container. Este
documento cobre o que o Postgres não controla e que decide boa parte do
desempenho real: disco, kernel, filesystem e rede.

Todos os perfis assumem **NVMe local**. Se o pré-voo abaixo não bater, o catálogo
não se aplica sem ressalvas.

- [Pré-voo: validar o disco antes de instalar](#pré-voo-validar-o-disco-antes-de-instalar)
- [Kernel](#kernel)
- [Huge pages](#huge-pages)
- [Filesystem e layout dos dados](#filesystem-e-layout-dos-dados)
- [Limites de processo](#limites-de-processo)
- [Rede](#rede)
- [Checklist](#checklist)

## Pré-voo: validar o disco antes de instalar

Vários planos "cloud" entregam block storage de rede como disco do sistema sem
dizer isso com clareza. Meça antes de assumir. Os dois testes abaixo levam
poucos minutos e evitam descobrir o problema com o banco já em produção.

```bash
# Latência e IOPS de leitura aleatória em blocos de 8k (o padrão do Postgres).
# Rode no diretório que vai virar o PGDATA, com o banco ainda parado.
fio --name=pgtest --directory=/data --size=4G --bs=8k --rw=randread \
    --ioengine=libaio --iodepth=32 --direct=1 --runtime=60 --time_based \
    --group_reporting
```

Alvos para NVMe local: **> 100k IOPS** e **p99 < 1 ms**. Block storage de rede
costuma ficar uma ordem de grandeza abaixo, com p99 em dezenas de ms.

```bash
# Custo de um fsync — é o que limita a taxa de commit do Postgres.
pg_test_fsync -f /data/fsynctest
```

Alvo: **< 100 µs por operação** em `fdatasync`. Muito acima disso, o gargalo de
escrita será o disco, não a configuração.

Se o disco não atender e não houver alternativa, suba `PG_RANDOM_PAGE_COST` para
1.5–2.0, baixe `PG_EFFECTIVE_IO_CONCURRENCY` para ~100 e trate os números de
latência dos perfis como otimistas.

## Kernel

```bash
# /etc/sysctl.d/30-postgres.conf
vm.swappiness = 1
vm.dirty_background_bytes = 268435456    # 256 MB
vm.dirty_bytes = 1073741824              # 1 GB
```

- **`vm.swappiness = 1`** — o Postgres gerencia o próprio cache; deixar o kernel
  paginar `shared_buffers` para o swap é sempre pior do que ele decidir o que
  descartar.
- **`vm.dirty_*` em bytes, não em ratio.** Os defaults em percentual (10%/20% da
  RAM) permitem dezenas de GB de páginas sujas acumuladas numa máquina grande; o
  flush em bloco no fim do checkpoint trava a escrita por segundos. Limitar em
  bytes espalha a escrita e mantém a latência previsível.

Aplicar com `sysctl --system`.

**Transparent Huge Pages (THP) devem ficar desligadas** — a desfragmentação
síncrona causa picos de latência imprevisíveis. Não confundir com as huge pages
explícitas da seção seguinte, que são desejáveis.

```bash
# no boot (via GRUB ou tuned)
transparent_hugepage=never
# verificação
cat /sys/kernel/mm/transparent_hugepage/enabled   # [never]
```

**Scheduler de I/O.** Para NVMe, a fila do kernel só atrapalha:

```bash
echo none > /sys/block/nvme0n1/queue/scheduler
# persistir via udev:
# ACTION=="add|change", KERNEL=="nvme*", ATTR{queue/scheduler}="none"
```

## Huge pages

Vale a partir de `shared_buffers` ≥ 16 GB (perfis de 64 GB e 128 GB): reduz a
pressão sobre o TLB de forma mensurável. A imagem já emite `huge_pages = try`,
que cai silenciosamente para páginas normais se o host não reservou nada.

Dimensione com folga de ~5% sobre `shared_buffers` (o Postgres precisa de um
pouco mais que o buffer pool na região compartilhada):

```bash
# exemplo para shared_buffers = 24GB, páginas de 2 MB:
# (24 * 1024 / 2) * 1.05 ≈ 12902
echo 'vm.nr_hugepages = 12902' >> /etc/sysctl.d/30-postgres.conf
sysctl --system
grep Huge /proc/meminfo
```

Depois de reservar, confirme que o Postgres realmente as está usando —
`huge_pages = try` não avisa quando falha:

```sql
SHOW huge_pages_status;   -- 'on' quando efetivamente em uso
```

A memória reservada em hugepages **não fica disponível** para o resto do sistema,
então some-a ao orçamento do Postgres, nunca ao dos vizinhos.

## Filesystem e layout dos dados

- **XFS ou ext4**, montados com `noatime`. XFS lida melhor com arquivos grandes e
  paralelismo de escrita; ext4 é igualmente aceitável.
- **`noatime` no fstab** — sem ele, toda leitura vira também uma escrita de
  metadado.
- **RAID1 de dois NVMe** em servidores dedicados. NVMe de consumo falha, e o PITR
  (ver [`../backup/`](../backup/README.md)) não elimina a janela de perda entre o
  último WAL arquivado e o incidente.
- Reserve espaço para `max_wal_size` × 2 além do tamanho da base: nos perfis
  grandes isso são dezenas de GB só de WAL.

```
/etc/fstab
UUID=…  /data  xfs  defaults,noatime  0 2
```

### Volumes nomeados

Os três serviços da org usam o **mesmo padrão**: volume nomeado com o driver
`local`, o default do Docker ([justificativa](../../README.md#dados-em-volumes-nomeados)).
Nada a criar antes de subir — nem diretório, nem dono, nem permissão.

| Serviço | Volume | Dentro do container | Override |
|---|---|---|---|
| PostgreSQL | `bdh_pg_data` | `/var/lib/postgresql/data` | `PG_VOLUME` |
| Redis | `bdh_redis_data` | `/data` | `REDIS_VOLUME` |
| Meilisearch | `bdh_meili_data` | `/meili_data` | `MEILI_VOLUME` |

```bash
docker volume ls | grep bdh_
docker volume inspect bdh_pg_data -f '{{.Mountpoint}}'   # /var/lib/docker/volumes/bdh_pg_data/_data
```

Os entrypoints do Postgres e do Redis ajustam o dono no start e degradam o
processo para o uid 999 (`postgres` e `redis`, não root); o Meilisearch roda como
root, que é o default da imagem oficial.

> ⚠️ `docker compose down -v` **apaga** o volume. Use `down` sem `-v`.

#### Confirme que o Docker está no NVMe

Volume nomeado vive sob o *data-root* do Docker. Como o padrão não fixa um
caminho no disco certo, essa checagem passa a ser parte da preparação do host:

```bash
docker info -f '{{.DockerRootDir}}'      # normalmente /var/lib/docker
df -h /var/lib/docker                    # tem de ser o NVMe local
lsblk -o NAME,ROTA,SIZE,MOUNTPOINT       # ROTA=0 → SSD/NVMe
```

#### Quando o NVMe não é o disco do Docker

Duas saídas, e a escolha depende do que você quer mover:

**1. Mover o data-root do Docker** — leva tudo (imagens, containers, todos os
volumes) para o outro disco de uma vez. É o mais simples numa máquina dedicada a
dados:

```json
/* /etc/docker/daemon.json — com o Docker parado */
{ "data-root": "/mnt/nvme/docker" }
```

**2. Manter o volume nomeado com backing num diretório** — granular, por serviço,
sem tocar no daemon. Um `docker-compose.override.yml` ao lado do compose:

```yaml
volumes:
  pg_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/nvme/postgres     # precisa EXISTIR: o Docker não cria
```

O volume continua se chamando `bdh_pg_data`, então backup, `bdh status` e a
documentação seguem valendo. É exatamente o que o
[`setup.sh`](../../README.md#setup-automatizado-de-vps) gera no modo
`--volumes bind`.

> Para conferir o backing, olhe `Options`, não `Mountpoint` — este último segue
> mostrando o caminho sob `/var/lib/docker/volumes` mesmo quando os dados estão
> em outro lugar:
> ```bash
> docker volume inspect bdh_pg_data -f '{{.Options.device}}'
> ```

Onde o disco realmente importa por serviço:

- **Postgres** — latência de `fsync` no commit e IOPS de leitura aleatória; é o
  que o [pré-voo](#pré-voo-validar-o-disco-antes-de-instalar) mede.
- **Meilisearch** — o índice é LMDB acessado por `mmap`: precisa de disco local
  (`mmap` sobre rede é patológico) e de page cache livre no host.
- **Redis** — dados em memória; o disco só entra no `fsync` do AOF (1×/s) e no
  rewrite. É o menos sensível dos três, mas o rewrite compete por IO com os
  vizinhos.

## Limites de processo

Com `max_connections` de 200–300 e paralelismo alto, os limites default do
systemd ficam apertados:

```ini
# /etc/systemd/system/docker.service.d/limits.conf
[Service]
LimitNOFILE=65536
LimitNPROC=65536
```

## Rede

O padrão do repositório é **publicar as portas em `0.0.0.0`** (`BIND_IP` com
default aberto), para que qualquer máquina — inclusive fora da rede privada —
consiga conectar. É uma escolha de conveniência operacional, e tem
consequências que vale conhecer:

- com a porta pública, **a senha é a única barreira**: as portas 5432 e 6379 são
  varridas continuamente na internet;
- o **Redis não faz TLS**: fora de rede confiável, a senha e os dados trafegam em
  claro. O Postgres suporta TLS, mas a imagem não o habilita por default;
- senhas precisam ser longas e aleatórias — o `setup.sh` gera 32 bytes.

Três formas de reduzir a exposição, quando desejado:

| Como | Efeito |
|---|---|
| `BIND_IP=10.0.0.5` no `.env` | publica só na interface privada — simples e efetivo |
| firewall por origem | libera só as máquinas de aplicação, **mas leia a ressalva abaixo** |
| VPN/túnel (WireGuard) entre as máquinas | nada exposto; melhor opção fora do mesmo datacenter |

### `ufw` não filtra portas publicadas pelo Docker

Esta é a armadilha mais perigosa desta página, porque falha em silêncio:

```bash
ufw allow from 10.0.0.0/8 to any port 5432 proto tcp   # NÃO restringe o container
```

O pacote destinado a um container entra por `FORWARD → DOCKER-USER → DOCKER`,
enquanto o ufw só instala regras em `INPUT`. Resultado: a porta continua
acessível de qualquer origem e o `ufw status` mostra uma regra que dá a impressão
contrária. Verificado em Debian 12 + Docker 29.

A restrição real vive na chain **`DOCKER-USER`**, usando a **porta interna** do
container (o DNAT já aconteceu quando o filtro roda):

```bash
# libera só a rede da aplicação e derruba o resto — porta INTERNA (5432)
iptables -I DOCKER-USER -p tcp --dport 5432 -j DROP
iptables -I DOCKER-USER -p tcp --dport 5432 -s 10.0.0.0/8 -j RETURN
iptables -I DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
```

Para persistir no boot, coloque as mesmas regras num bloco `*filter` no fim de
`/etc/ufw/after.rules` (o ufw as reaplica no `reload` e no boot) — é o que o
[`setup.sh`](../../README.md#setup-automatizado-de-vps) faz com
`--allow-from`. Duas notas:

- **remover as regras do arquivo não as remove do kernel**: faça
  `iptables -F DOCKER-USER` antes de reaplicar;
- as regras acima são IPv4. Como o Docker vem sem IPv6 nas redes bridge
  (`docker network inspect bridge -f '{{.EnableIPv6}}'` → `false`), o
  `docker-proxy` escuta só em `0.0.0.0` e não há caminho IPv6 a filtrar. Se você
  habilitar IPv6 no Docker, replique as regras em `ip6tables`.

Se essa complexidade não é bem-vinda, prefira `BIND_IP` numa interface privada:
o Docker respeita o IP do bind, e nada chega de fora.

Independentemente disso: se os vizinhos (Redis, Meilisearch) estiverem em outra
máquina, a rede entre elas fica no caminho crítico de cada request — prefira o
mesmo datacenter/zona e a rede privada do provedor.

## Checklist

Antes de subir o container:

- [ ] `fio` e `pg_test_fsync` dentro dos alvos de NVMe local
- [ ] `vm.swappiness`, `vm.dirty_background_bytes` e `vm.dirty_bytes` aplicados
- [ ] THP em `never`
- [ ] Scheduler de I/O em `none` e persistido via udev
- [ ] Hugepages reservadas (perfis 64/128 GB) e somadas ao orçamento do Postgres
- [ ] Filesystem em XFS/ext4 com `noatime`, com folga para `max_wal_size × 2`
- [ ] **`docker info -f '{{.DockerRootDir}}'` no NVMe** — é onde os volumes vivem
- [ ] RAID1 em servidor dedicado
- [ ] `LimitNOFILE` ajustado
- [ ] Senhas longas e aleatórias (as portas são públicas por default) e, se
      quiser restringir, `BIND_IP`/firewall/VPN definidos

Depois de subir, confirme o que dependia do host:

```sql
SHOW huge_pages_status;    -- 'on' se as hugepages foram reservadas
```
