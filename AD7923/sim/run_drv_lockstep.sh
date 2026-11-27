#!/usr/bin/env bash
# Driver lockstep: eski driver (tb/sync_ref, sync reset)  <->  yeni driver (rtl, async reset)
#   İkisi de core olarak common/rtl/async/spi_exec kullanır; her biri kendi AD7923 modeline bağlı.
#
#   ./run_drv_lockstep.sh SEED CYCLES [DRV_DIR]
#   örnek: ./run_drv_lockstep.sh 1 2000000
#   DRV_DIR: mutation testi için değiştirilmiş driver klasörü (varsayılan ../rtl). MUT=1 ile.
#
# Her iki top ghdl --synth ile ayrı Verilog netlist'e çevrilir; referans netlist'teki
# ortak (core) modül adlarına _R eklenir (iki netlist aynı Icarus koşusunda).
set -e
cd "$(dirname "$0")"
SEED=${1:-1}; CYC=${2:-2000000}; DRV=${3:-../rtl}; MUT=${MUT:-0}
B=build/dls_${SEED}_$$
# Ortak SPI master core (spi_exec, async reset): repo kökünde common/rtl/async
CORE=../../common/rtl/async
mkdir -p $B
ghdl -a --std=08 --workdir=$B $CORE/spi_exec_shiftreg.vhd $CORE/spi_exec.vhd
ghdl -a --std=08 --workdir=$B ../tb/sync_ref/ad7923_drv_sref.vhd ../tb/sync_ref/ad7923_ch_regs_sref.vhd \
  ../tb/sync_ref/ad7923_top_sref.vhd
ghdl -a --std=08 --workdir=$B $DRV/ad7923_drv.vhd $DRV/ad7923_ch_regs.vhd $DRV/ad7923_top.vhd
ghdl --synth --std=08 --workdir=$B --out=verilog ad7923_top_sref > $B/ref_net.v
ghdl --synth --std=08 --workdir=$B --out=verilog ad7923_top      > $B/dut_net.v
python3 -I - $B/ref_net.v $B/dut_net.v <<'PY'
import re,sys
ref,dut=sys.argv[1],sys.argv[2]
s=open(ref).read()
dm=set(re.findall(r'^module\s+(\w+)',open(dut).read(),re.M))
for m in set(re.findall(r'^module\s+(\w+)',s,re.M)) & dm:
    s=re.sub(r'\b'+m+r'\b', m+'_R', s)
open(ref,'w').write(s)
PY
iverilog -g2012 -o $B/dls.vvp -s tb_drv_lockstep \
  -Ptb_drv_lockstep.SEED=$SEED -Ptb_drv_lockstep.CYCLES=$CYC -Ptb_drv_lockstep.MUT=$MUT \
  ../tb/tb_drv_lockstep.v $B/ref_net.v $B/dut_net.v ../tb/ad7923_model.v
vvp -n $B/dls.vvp
rm -rf $B
