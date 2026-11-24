#!/usr/bin/env bash
# Lockstep: orijinal ADI Verilog  <->  spi_exec_p1 (birebir, sync)  <->  spi_exec (async)
#
#   ./run_lockstep.sh DW CS SDI DELAY CFG DIV SDO_DEF SEED CYCLES [P1_DIR] [AS_DIR]
#   örnek (AD7923): ./run_lockstep.sh 16 1 1 0 2 2 1 1 200000
#
# VHDL sürümleri, verilen generic'lerle ghdl --synth ile Verilog netlist'e çevrilir.
# P1_DIR / AS_DIR: mutation testleri için farklı RTL klasörü verilebilir.
set -e
cd "$(dirname "$0")"
DW=$1; CS=$2; SDI=$3; DLY=$4; CFG=$5; DIV=$6; SDOD=$7; SEED=$8; CYC=$9
P1=${10:-../rtl/p1}; AS=${11:-../rtl/async}; MUT=${MUT:-0}
ADI=${ADI_DIR:-../vendor/adi}
DLYB=$(python3 -c "print(format($DLY,'02b'))")
B=build/ls_${DW}_${CS}_${SDI}_${DLY}_${CFG}_${DIV}_${SDOD}_$$
mkdir -p $B
G="-gNUM_OF_CS=$CS -gDEFAULT_SPI_CFG=$CFG -gDEFAULT_CLK_DIV=$DIV -gDATA_WIDTH=$DW -gNUM_OF_SDI=$SDI -gSDO_DEFAULT=$SDOD -gSDI_DELAY=$DLYB"
ghdl -a --std=08 --workdir=$B $P1/spi_exec_p1_shiftreg.vhd $P1/spi_exec_p1.vhd
ghdl -a --std=08 --workdir=$B $AS/spi_exec_shiftreg.vhd $AS/spi_exec.vhd
ghdl --synth --std=08 --workdir=$B $G --out=verilog spi_exec_p1 > $B/p1_net.v
ghdl --synth --std=08 --workdir=$B $G --out=verilog spi_exec    > $B/as_net.v
iverilog -g2012 -o $B/ls.vvp -s tb_lockstep \
  -Ptb_lockstep.NUM_OF_CS=$CS -Ptb_lockstep.DATA_WIDTH=$DW -Ptb_lockstep.DEFAULT_SPI_CFG=$CFG \
  -Ptb_lockstep.DEFAULT_CLK_DIV=$DIV -Ptb_lockstep.NUM_OF_SDI=$SDI -Ptb_lockstep.SDO_DEFAULT=$SDOD \
  -Ptb_lockstep.SDI_DELAY=$DLY -Ptb_lockstep.SEED=$SEED -Ptb_lockstep.CYCLES=$CYC -Ptb_lockstep.MUT=$MUT -Ptb_lockstep.RST_MODE=${RST_MODE:-0} \
  ../tb/tb_lockstep.v $B/p1_net.v $B/as_net.v $ADI/spi_engine_execution.v $ADI/spi_engine_execution_shiftreg.v
vvp -n $B/ls.vvp
rm -rf $B
