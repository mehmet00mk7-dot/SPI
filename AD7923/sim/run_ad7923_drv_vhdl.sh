#!/usr/bin/env bash
# ad7923_top + spi_exec (VHDL, async reset) + AD7923 modeli
#   Tamamı VHDL: GHDL ile analiz, ghdl --synth ile Verilog netlist, Icarus ile simülasyon.
#   ./run_ad7923_drv_vhdl.sh [T_DOUT]
set -e
cd "$(dirname "$0")"
TDOUT=${1:-25.0}
B=build/drv_vhdl
# Ortak SPI master core (spi_exec, async reset): repo kökünde common/rtl/async
CORE=../../common/rtl/async
rm -rf $B; mkdir -p $B
ghdl -a --std=08 --workdir=$B $CORE/spi_exec_shiftreg.vhd $CORE/spi_exec.vhd \
  ../rtl/drv/ad7923_drv.vhd ../rtl/drv/ad7923_ch_regs.vhd ../rtl/drv/ad7923_top.vhd
ghdl --synth --std=08 --workdir=$B --out=verilog ad7923_top > $B/ad7923_top_net.v
iverilog -g2012 -o $B/ad7923_drv.vvp -s tb_ad7923_drv -Ptb_ad7923_drv.T_DOUT=$TDOUT \
  ../tb/tb_ad7923_drv.v $B/ad7923_top_net.v ../tb/ad7923_model.v
vvp -n $B/ad7923_drv.vvp
