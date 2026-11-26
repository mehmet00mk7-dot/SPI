#!/usr/bin/env bash
# ANALIZ.md ölçümleri: önerilen paketlerin spi_exec ile zamanlaması ve MISO penceresi.
#   ./run_olcum.sh            (CS_T = 0 ve 1, SO_DLY taraması)
# Core'a dokunmaz; netlist geçici klasörde üretilir.
set -e
cd "$(dirname "$0")"
C=../../../common/rtl/async
B=$(mktemp -d)
ghdl -a --std=08 --workdir=$B $C/spi_exec_shiftreg.vhd $C/spi_exec.vhd
ghdl --synth --std=08 --workdir=$B -gNUM_OF_CS=1 -gDATA_WIDTH=8 -gDEFAULT_CLK_DIV=2 -gSDI_DELAY=00 \
  --out=verilog spi_exec > $B/net8.v
for t in 0 1; do
  iverilog -g2012 -o $B/m.vvp -Ptb_meas.CS_T=$t tb_meas.v $B/net8.v
  vvp -n $B/m.vvp | grep -vE "finish|SCK=x"
done
echo "MISO penceresi (CS_T=1): SO_DLY = SCK düşen kenarı -> SO değişimi"
for d in 0 10 20 30 35 39 40 45 50 60; do
  iverilog -g2012 -o $B/m.vvp -Ptb_meas.CS_T=1 -Ptb_meas.SO_DLY=$d.0 tb_meas.v $B/net8.v
  echo "  SO_DLY=$d ns -> $(vvp -n $B/m.vvp | grep RESULT)"
done
rm -rf $B
