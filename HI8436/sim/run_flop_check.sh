#!/usr/bin/env bash
# Yapısal kontrol: hi8436_top'u ghdl --synth ile netlist'e çevirir; bütün flop'ların
# "posedge clk or posedge <rst_n'den türeyen>" biçiminde olduğunu kontrol eder
# (düz posedge clk flop = 0, türetilmiş async reset = 0; core'da onaylı p_core_resetn yolu).
#   ./run_flop_check.sh [RTL_DIR] [DATA_WIDTH]      (varsayılan ../rtl, 8)
set -e
cd "$(dirname "$0")"
RTL=${1:-../rtl}; DW=${2:-8}
CORE=../../common/rtl/async
B=$(mktemp -d flopchk_XXXXXX)
trap 'rm -rf $B' EXIT
ghdl -a --std=08 --workdir=$B $CORE/spi_exec_shiftreg.vhd $CORE/spi_exec.vhd \
  $RTL/hi8436_drv.vhd $RTL/hi8436_top.vhd
ghdl --synth --std=08 --workdir=$B -gDATA_WIDTH=$DW --out=verilog hi8436_top > $B/net.v
echo "always blokları (sensitivity, adet):"
grep -oE "always @\([^)]*\)" $B/net.v | sed -E 's/n[0-9]+_o/<net>/' | sort | uniq -c
set +e
python3 -I check_flops.py $B/net.v hi8436_top; rc=$?
[ $rc -eq 0 ] && echo "SONUC: BASARILI" || echo "SONUC: BASARISIZ"
exit $rc
