#!/usr/bin/env bash
# Testes do shm-guard.sh. Rodar: bash postgres/test/shm-guard.test.sh
#
# Não precisa de Docker: o tamanho de /dev/shm é injetado via
# SHM_GUARD_FAKE_BYTES, então a lógica de decisão é exercitada direto.
set -uo pipefail

GUARD="$(cd "$(dirname "$0")/.." && pwd)/shm-guard.sh"
PASS=0; FAIL=0

# esperado_workers: número, ou "exit1" quando o start deve abortar
check() {
    local nome="$1" shm="$2" work_mem="$3" mult="$4" per_gather="$5" mode="$6" esperado="$7"
    local out rc efetivo

    out="$(
        SHM_GUARD_FAKE_BYTES="$shm" \
        PG_WORK_MEM="$work_mem" \
        PG_HASH_MEM_MULTIPLIER="$mult" \
        PG_MAX_PARALLEL_WORKERS_PER_GATHER="$per_gather" \
        PG_SHM_PREFLIGHT="$mode" \
        bash -c 'set -euo pipefail; source "$0" >/dev/null 2>&1; echo "$PG_MAX_PARALLEL_WORKERS_PER_GATHER"' "$GUARD" 2>/dev/null
    )"
    rc=$?

    if [ "$esperado" = "exit1" ]; then
        if [ "$rc" -ne 0 ]; then
            echo "  ✓ $nome — abortou o start (rc=$rc)"; PASS=$((PASS+1))
        else
            echo "  ✗ $nome — esperava abortar, mas subiu com per_gather=$out"; FAIL=$((FAIL+1))
        fi
        return
    fi

    efetivo="$(echo "$out" | tail -1)"
    if [ "$efetivo" = "$esperado" ]; then
        echo "  ✓ $nome — per_gather=$efetivo"; PASS=$((PASS+1))
    else
        echo "  ✗ $nome — esperava per_gather=$esperado, obteve '$efetivo' (rc=$rc)"; FAIL=$((FAIL+1))
    fi
}

MB=$((1024*1024)); GB=$((1024*1024*1024))

echo "shm-guard — cenários de decisão"

# O incidente de 25/07/2026: perfil dedicada-16gb com /dev/shm default do Docker.
# Pico estimado: 5 × 32MB × 2.0 × 2 = 640 MB contra 64 MB -> tem de zerar.
check "incidente 2026-07 (64MB, perfil 16gb)"  $((64*MB))   32MB 2.0 4 adapt 0
check "  o mesmo, mode=fail"                    $((64*MB))   32MB 2.0 4 fail  exit1
check "  o mesmo, mode=warn (não mexe)"         $((64*MB))   32MB 2.0 4 warn  4
check "  o mesmo, mode=off (não mexe)"          $((64*MB))   32MB 2.0 4 off   4

# Com o shm_size correto do perfil, o paralelismo é preservado integralmente.
check "perfil 16gb com shm 2gb (correto)"       $((2*GB))    32MB 2.0 4 adapt 4
check "perfil 8gb  com shm 1gb (correto)"       $((1*GB))    16MB 2.0 2 adapt 2
check "perfil 64gb com shm 4gb (correto)"       $((4*GB))    64MB 3.0 4 adapt 4
check "perfil 128gb com shm 8gb (correto)"      $((8*GB))    96MB 3.0 6 adapt 6

# Degradação parcial: cabe algum paralelismo, mas não o do perfil.
# 512MB usável=435MB; w=2 -> 3×64×2=384MB cabe; w=3 -> 512MB não cabe.
check "degradação parcial (512MB)"              $((512*MB))  32MB 2.0 4 adapt 2

# Perfil 8gb no shm default: 3 × 32MB × 2 = 192MB > 54MB usável -> zera.
check "perfil 8gb com 64MB (máquina antiga)"    $((64*MB))   16MB 2.0 2 adapt 0

# Robustez: sem medição confiável, não interferir.
check "df indisponível (0 bytes)"               0            32MB 2.0 4 adapt 4
# Sem paralelismo configurado não há Parallel Hash — nada a decidir.
check "per_gather=0 já desligado"               $((64*MB))   32MB 2.0 0 adapt 0
# Unidades e multiplicador fracionário são interpretados corretamente.
check "work_mem em GB"                          $((8*GB))     1GB 1.5 4 adapt 1
check "work_mem sem unidade (=kB)"              $((2*GB))   32768 2.0 4 adapt 4

echo
echo "  $PASS passaram, $FAIL falharam"
[ "$FAIL" -eq 0 ]
