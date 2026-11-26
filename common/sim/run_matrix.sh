#!/usr/bin/env bash
# Konfigürasyon matrisi x seed'ler. Kullanım: ./run_matrix.sh CYCLES "SEEDS"
cd "$(dirname "$0")"
CYC=${1:-1000000}; SEEDS=${2:-"1 2 3"}
CONFIGS=(
"16 1 1 0 2 2 1"   # A: AD7923 (DW=16, CS=1, mode 2, div=2, SDO_DEFAULT=1)
"8 4 1 1 0 0 1"    # B
"32 8 2 3 3 1 0"   # C
"24 2 1 2 1 0 1"   # D
"16 8 1 0 4 3 0"   # E: three_wire
"8 1 2 0 2 0 0"    # F
"32 1 1 1 6 2 1"   # G: CPOL + three_wire
"24 4 2 0 7 0 0"   # H: mode 3 + three_wire
)
mkdir -p log
for c in "${CONFIGS[@]}"; do for s in $SEEDS; do
  n=$(echo "$c $s" | tr ' ' '_')
  echo "./run_lockstep.sh $c $s $CYC > log/ls_m${RST_MODE:-0}_$n.txt 2>&1"
done; done | xargs -P $(nproc) -I{} bash -c "{}"
grep -h "SONUC" log/ls_m${RST_MODE:-0}_*.txt | sort | uniq -c
