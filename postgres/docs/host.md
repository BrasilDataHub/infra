# Preparação do host — o que fica fora do container

Os [perfis](perfis.md) dimensionam o que roda **dentro** do container. Este
documento cobre o que o Postgres não controla e que decide boa parte do
desempenho real: disco, kernel, filesystem e rede.

Todos os perfis assumem **NVMe local**. Se o pré-voo abaixo não bater, o catálogo
não se aplica sem ressalvas.

- [Pré-voo: validar o disco antes de instalar](#pré-voo-validar-o-disco-antes-de-instalar)
- [Kernel](#kernel)
- [Huge pages](#huge-pages)
- [Filesystem e layout do PGDATA](#filesystem-e-layout-do-pgdata)
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

## Filesystem e layout do PGDATA

- **XFS ou ext4**, montados com `noatime`. XFS lida melhor com arquivos grandes e
  paralelismo de escrita; ext4 é igualmente aceitável.
- **`noatime` no fstab** — sem ele, toda leitura vira também uma escrita de
  metadado.
- **PGDATA em bind mount de diretório local** (`/data/pgdata`), nunca em volume
  de rede e nunca num volume Docker gerenciado num disco diferente do NVMe.
- **RAID1 de dois NVMe** em servidores dedicados. NVMe de consumo falha, e o PITR
  (ver [`../backup/`](../backup/README.md)) não elimina a janela de perda entre o
  último WAL arquivado e o incidente.
- Reserve espaço para `max_wal_size` × 2 além do tamanho da base: nos perfis
  grandes isso são dezenas de GB só de WAL.

```
/etc/fstab
UUID=…  /data  xfs  defaults,noatime  0 2
```

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

- Exponha o 5432 **apenas** na rede privada — no compose, faça o bind no IP
  privado (`"${PRIVATE_IP}:5432:5432"`), nunca em `0.0.0.0`.
- Firewall liberando o 5432 só para os IPs privados das máquinas de aplicação.
- Se os vizinhos (Redis, Meilisearch) estiverem em outra máquina, a rede privada
  entre elas passa a estar no caminho crítico de cada request — prefira o mesmo
  datacenter/zona.

## Checklist

Antes de subir o container:

- [ ] `fio` e `pg_test_fsync` dentro dos alvos de NVMe local
- [ ] `vm.swappiness`, `vm.dirty_background_bytes` e `vm.dirty_bytes` aplicados
- [ ] THP em `never`
- [ ] Scheduler de I/O em `none` e persistido via udev
- [ ] Hugepages reservadas (perfis 64/128 GB) e somadas ao orçamento do Postgres
- [ ] `/data` em XFS/ext4 com `noatime`, com folga para `max_wal_size × 2`
- [ ] RAID1 em servidor dedicado
- [ ] `LimitNOFILE` ajustado
- [ ] 5432 apenas na rede privada

Depois de subir, confirme o que dependia do host:

```sql
SHOW huge_pages_status;    -- 'on' se as hugepages foram reservadas
```
