#!/usr/bin/env bash
# Yapısal kontrol (D): ad7923_top'u ghdl --synth ile netlist'e çevirir, bütün flop'ların
# "posedge clk or posedge <rst_n'den türeyen>" biçiminde olduğunu kontrol eder.
#   ./run_flop_check.sh [DRV_DIR]      (varsayılan ../rtl/drv)
set -e
cd "$(dirname "$0")"
DRV=${1:-../rtl/drv}
B=build/flopchk_$$; mkdir -p $B
ghdl -a --std=08 --workdir=$B ../rtl/async/spi_exec_shiftreg.vhd ../rtl/async/spi_exec.vhd \
  $DRV/ad7923_drv.vhd $DRV/ad7923_ch_regs.vhd $DRV/ad7923_top.vhd
ghdl --synth --std=08 --workdir=$B --out=verilog ad7923_top > $B/ad7923_top_net.v
echo "always blokları (sensitivity, adet):"
grep -oE "always @\([^)]*\)" $B/ad7923_top_net.v | sed -E 's/n[0-9]+_o/<net>/' | sort | uniq -c
set +e
python3 -I check_flops.py $B/ad7923_top_net.v ad7923_top; rc=$?
rm -rf $B
exit $rc
