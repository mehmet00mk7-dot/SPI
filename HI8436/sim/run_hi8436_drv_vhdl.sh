#!/usr/bin/env bash
# hi8436_top (VHDL: hi8436_drv + common spi_exec) + HI-8436 modeli: senaryo testleri T01-T23
#   GHDL ile analiz, ghdl --synth ile Verilog netlist, Icarus ile simülasyon.
#   ./run_hi8436_drv_vhdl.sh [T_SO] [DATA_WIDTH] [RTL_DIR] [UNUSED_STORE] [HAS_MR]
#     T_SO        : model SCK düşen -> SO gecikmesi, ns (timing köşesi; varsayılan 15.0)
#     DATA_WIDTH  : core kelime genişliği (varsayılan 8; paylaşılan core köşesi 16/32)
#     RTL_DIR     : driver/top kaynak klasörü (mutation / negatif kontrol için; varsayılan ../rtl)
#     UNUSED_STORE: model kullanılmayan register bitlerini saklar mı (0/1, DS-3)
#     HAS_MR      : DUT HAS_MR generic'i (1 = true, 0 = false; varsayılan 1)
# İkinci DUT (T14) VERIFY_EVERY = 8 ile ayrıca sentezlenir, modül adlarına _v eklenir.
# Başarıda "SONUC: BASARILI" ve exit 0; aksi halde exit 1.
set -e
cd "$(dirname "$0")"
TSO=${1:-15.0}; DW=${2:-8}; RTL=${3:-../rtl}; US=${4:-0}; MR=${5:-1}
MRB=$([ "$MR" = "1" ] && echo true || echo false)
CORE=../../common/rtl/async
B=$(mktemp -d build_XXXXXX)
trap 'rm -rf $B' EXIT
ghdl -a --std=08 --workdir=$B $CORE/spi_exec_shiftreg.vhd $CORE/spi_exec.vhd \
  $RTL/hi8436_drv.vhd $RTL/hi8436_top.vhd
ghdl --synth --std=08 --workdir=$B -gDATA_WIDTH=$DW -gHAS_MR=$MRB --out=verilog hi8436_top > $B/net.v
ghdl --synth --std=08 --workdir=$B -gDATA_WIDTH=$DW -gHAS_MR=$MRB -gVERIFY_EVERY=8 --out=verilog hi8436_top > $B/net_v.v
python3 -I - $B/net_v.v <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
for m in set(re.findall(r'^module\s+(\w+)',s,re.M)):
    s=re.sub(r'\b'+m+r'\b', m+'_v', s)
open(p,'w').write(s)
PY
iverilog -g2012 -o $B/tb.vvp -s tb_hi8436_drv -Ptb_hi8436_drv.T_SO=$TSO -Ptb_hi8436_drv.DW=$DW \
  -Ptb_hi8436_drv.UNUSED_STORE=$US -Ptb_hi8436_drv.HAS_MR=$MR ../tb/tb_hi8436_drv.v $B/net.v $B/net_v.v ../tb/hi8436_model.v
vvp -n $B/tb.vvp | tee $B/out.txt
grep -q "SONUC: BASARILI" $B/out.txt
