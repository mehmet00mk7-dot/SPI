#!/usr/bin/env bash
# "Yalnız yorum değişti" kontrolü: rtl/drv ve rtl/async VHDL dosyalarını verilen git
# revizyonuyla karşılaştırır.
#   1) check_comment_only.py: yorumsuz token dizisi ve kod satırları aynı mı
#   2) ghdl --synth netlist'i (ad7923_top), kaynak satır yorumları atılınca aynı mı
#   ./run_comment_check.sh [REV]      (varsayılan HEAD)
set -e
cd "$(dirname "$0")"
REV=${1:-HEAD}
B=build/cmtchk_$$; mkdir -p $B/old
FILES="rtl/async/spi_exec_shiftreg.vhd rtl/async/spi_exec.vhd rtl/drv/ad7923_drv.vhd rtl/drv/ad7923_ch_regs.vhd rtl/drv/ad7923_top.vhd"
ARGS=""
for f in $FILES; do
  mkdir -p $B/old/$(dirname $f); git show $REV:$f > $B/old/$f
  ARGS="$ARGS $B/old/$f ../$f"
done
set +e
python3 -I check_comment_only.py $ARGS; rc=$?
set -e
for v in old new; do
  R=$([ $v = old ] && echo $B/old || echo ..); mkdir -p $B/w_$v
  ghdl -a --std=08 --workdir=$B/w_$v $(for f in $FILES; do echo $R/$f; done)
  ghdl --synth --std=08 --workdir=$B/w_$v --out=verilog ad7923_top | sed -E 's#/\*[^*]*\*/##g' | grep -v '^\s*$' > $B/net_$v.v
done
if diff -q $B/net_old.v $B/net_new.v > /dev/null; then
  echo "NETLIST (ad7923_top, kaynak satir yorumlari haric): AYNI  $(sha256sum < $B/net_new.v | cut -c1-16)"
else
  echo "NETLIST: FARKLI"; rc=1
fi
rm -rf $B
exit $rc
