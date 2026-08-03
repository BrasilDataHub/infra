# Preparação do host

O que fica fora do container: disco, kernel, filesystem e rede. Todos os
[perfis](perfis.md) assumem **NVMe local**.

## Pré-voo: validar o disco antes de instalar

```bash
# Latência e IOPS de leitura aleatória 8k (padrão do Postgres).
# No diretório que vai virar o PGDATA, banco parado.
fio --name=pgtest --directory=/data --size=4G --bs=8k --rw=randread \
    --ioengine=libaio --iodepth=32 --direct=1 --runtime=60 --time_based \
    --group_reporting
```

Alvos NVMe local: **> 100k IOPS**, **p99 < 1 ms**. Block storage de rede fica
cerca de uma ordem de grandeza abaixo.

```bash
pg_test_fsync -f /data/fsynctest
```

Alvo: **< 100 µs** por operação em `fdatasync`.

Se o disco não atender: `PG_RANDOM_PAGE_COST` 1.5–2.0,
`PG_EFFECTIVE_IO_CONCURRENCY` ~100; trate os números dos perfis como otimistas.

## Kernel

```bash
# /etc/sysctl.d/30-postgres.conf
vm.swappiness = 1
vm.dirty_background_bytes = 268435456    # 256 MB
vm.dirty_bytes = 1073741824              # 1 GB
```

- `vm.swappiness = 1` — o Postgres gerencia o próprio cache; paginar
  `shared_buffers` para swap é pior.
- `vm.dirty_*` em **bytes**, não ratio — defaults percentuais acumulam dezenas
  de GB de páginas sujas e travam a escrita no checkpoint.

Aplicar: `sysctl --system`.

**THP desligado** (não confundir com huge pages explícitas):

```bash
# no boot (GRUB ou tuned)
transparent_hugepage=never
cat /sys/kernel/mm/transparent_hugepage/enabled   # [never]
```

**Scheduler de I/O** para NVMe:

```bash
echo none > /sys/block/nvme0n1/queue/scheduler
# udev: ACTION=="add|change", KERNEL=="nvme*", ATTR{queue/scheduler}="none"
```

## Huge pages

A partir de `shared_buffers` ≥ 16 GB (perfis 64/128 GB). A imagem emite
`huge_pages = try` (cai para páginas normais se o host não reservou).

Folga de ~5% sobre `shared_buffers`:

```bash
# shared_buffers = 24GB, páginas 2 MB: (24 * 1024 / 2) * 1.05 ≈ 12902
echo 'vm.nr_hugepages = 12902' >> /etc/sysctl.d/30-postgres.conf
sysctl --system
grep Huge /proc/meminfo
```

```sql
SHOW huge_pages_status;   -- 'on' quando em uso
```

Memória em hugepages **não fica disponível** para o resto do sistema — some ao
orçamento do Postgres, não ao dos vizinhos.

## Filesystem e layout

- **XFS ou ext4** com `noatime`
- **RAID1** de dois NVMe em servidor dedicado
- Folga para `max_wal_size` × 2 além do tamanho da base

```
/etc/fstab
UUID=…  /data  xfs  defaults,noatime  0 2
```

### Volumes nomeados

Padrão da org: volume nomeado, driver `local`
([motivo](../../README.md#dados-em-volumes-nomeados)).

| Serviço | Volume | Dentro do container | Override |
|---|---|---|---|
| PostgreSQL | `bdh_pg_data` | `/var/lib/postgresql/data` | `PG_VOLUME` |
| Redis | `bdh_redis_data` | `/data` | `REDIS_VOLUME` |
| Meilisearch | `bdh_meili_data` | `/meili_data` | `MEILI_VOLUME` |

```bash
docker volume ls | grep bdh_
docker volume inspect bdh_pg_data -f '{{.Mountpoint}}'
```

Entrypoints do Postgres e Redis ajustam dono e degradam para uid 999; Meilisearch
roda como root (default da imagem oficial).

> ⚠️ `docker compose down -v` **apaga** o volume. Use `down` sem `-v`.

#### Confirme que o Docker está no NVMe

```bash
docker info -f '{{.DockerRootDir}}'      # normalmente /var/lib/docker
df -h /var/lib/docker                    # tem de ser o NVMe local
lsblk -o NAME,ROTA,SIZE,MOUNTPOINT       # ROTA=0 → SSD/NVMe
```

#### Quando o NVMe não é o disco do Docker

**1. Mover o data-root** (tudo de uma vez):

```json
/* /etc/docker/daemon.json — Docker parado */
{ "data-root": "/mnt/nvme/docker" }
```

**2. Backing por serviço** (`docker-compose.override.yml`):

```yaml
volumes:
  pg_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/nvme/postgres     # precisa EXISTIR
```

O volume continua `bdh_pg_data`. É o que o
[`setup.sh`](../../README.md#setup-automatizado-de-vps) gera com `--volumes bind`.

```bash
docker volume inspect bdh_pg_data -f '{{.Options.device}}'
```

Sensibilidade por serviço: Postgres (fsync + IOPS aleatório); Meilisearch
(LMDB/`mmap` — disco local obrigatório); Redis (só AOF 1×/s e rewrite).

## Limites de processo

Com `max_connections` 200–300 e paralelismo alto:

```ini
# /etc/systemd/system/docker.service.d/limits.conf
[Service]
LimitNOFILE=65536
LimitNPROC=65536
```

## Rede

Default: portas em `0.0.0.0` (`BIND_IP` aberto). Com porta pública, a senha é a
única barreira. Redis sem TLS; Postgres com TLS possível mas não habilitado por
default. `setup.sh` gera senhas de 32 bytes.

| Como | Efeito |
|---|---|
| `BIND_IP=10.0.0.5` | publica só na interface privada |
| firewall por origem | libera só as máquinas de app — ver ressalva |
| VPN/túnel (WireGuard) | nada exposto |

### `ufw` não filtra portas publicadas pelo Docker

```bash
ufw allow from 10.0.0.0/8 to any port 5432 proto tcp   # NÃO restringe o container
```

O pacote entra por `FORWARD → DOCKER-USER → DOCKER`; ufw só mexe em `INPUT`.
Restrição real na chain **`DOCKER-USER`**, porta **interna** (pós-DNAT):

```bash
iptables -I DOCKER-USER -p tcp --dport 5432 -j DROP
iptables -I DOCKER-USER -p tcp --dport 5432 -s 10.0.0.0/8 -j RETURN
iptables -I DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
```

Persistir em `/etc/ufw/after.rules` (bloco `*filter`) — o
[`setup.sh`](../../README.md#setup-automatizado-de-vps) faz com `--allow-from`.

- Remover do arquivo **não** remove do kernel: `iptables -F DOCKER-USER` antes
  de reaplicar.
- Regras acima são IPv4. Docker bridge sem IPv6 por default; se habilitar IPv6,
  replique em `ip6tables`.

Alternativa mais simples: `BIND_IP` numa interface privada.

## Checklist

- [ ] `fio` e `pg_test_fsync` dentro dos alvos
- [ ] `vm.swappiness`, `vm.dirty_*` aplicados
- [ ] THP em `never`
- [ ] Scheduler `none` (udev)
- [ ] Hugepages (perfis 64/128 GB) somadas ao orçamento do Postgres
- [ ] XFS/ext4 `noatime`, folga para `max_wal_size × 2`
- [ ] `DockerRootDir` no NVMe
- [ ] RAID1 em servidor dedicado
- [ ] `LimitNOFILE` ajustado
- [ ] Senhas longas; `BIND_IP`/firewall/VPN se restringir

```sql
SHOW huge_pages_status;    -- 'on' se reservadas
```
