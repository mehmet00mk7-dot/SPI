#!/usr/bin/env bash
# "Yalnız yorum değişti" kontrolü: rtl/drv ve common/rtl/async VHDL dosyalarını verilen git
# revizyonuyla karşılaştırır.
#   1) check_comment_only.py: yorumsuz token dizisi ve kod satırları aynı mı
#   2) ghdl --synth netlist'i (ad7923_top), kaynak satır yorumları atılınca aynı mı
#   ./run_comment_check.sh [REV]      (varsayılan HEAD)
set -e
cd "$(dirname "$0")"
REV=${1:-HEAD}
B=build/cmtchk_$$; mkdir -p $B/old
# Dosyalar repo köküne göre güncel yerleriyle. Core (rtl/async) common/ altında.
FILES="common/rtl/async/spi_exec_shiftreg.vhd common/rtl/async/spi_exec.vhd AD7923/rtl/drv/ad7923_drv.vhd AD7923/rtl/drv/ad7923_ch_regs.vhd AD7923/rtl/drv/ad7923_top.vhd"
ROOT=$(git rev-parse --show-toplevel)
ARGS=""; OLDL=""; NEWL=""
# Eski revizyonlarda dosyalar başka yerdeydi: önce güncel yol, sonra AD7923/<rtl/..>
# (common/ öncesi), en son repo kökü <rtl/..> (AD7923/ öncesi) denenir.
for f in $FILES; do
  r=${f#common/}; r=${r#AD7923/}
  mkdir -p $B/old/$(dirname $r)
  git show "$REV:$f" > $B/old/$r 2>/dev/null || git show "$REV:AD7923/$r" > $B/old/$r 2>/dev/null \
    || git show "$REV:$r" > $B/old/$r
  ARGS="$ARGS $B/old/$r $ROOT/$f"; OLDL="$OLDL $B/old/$r"; NEWL="$NEWL $ROOT/$f"
done
set +e
python3 -I check_comment_only.py $ARGS; rc=$?
set -e
for v in old new; do
  L=$([ $v = old ] && echo "$OLDL" || echo "$NEWL"); mkdir -p $B/w_$v
  ghdl -a --std=08 --workdir=$B/w_$v $L
  ghdl --synth --std=08 --workdir=$B/w_$v --out=verilog ad7923_top | sed -E 's#/\*[^*]*\*/##g' | grep -v '^\s*$' > $B/net_$v.v
done
if diff -q $B/net_old.v $B/net_new.v > /dev/null; then
  echo "NETLIST (ad7923_top, kaynak satir yorumlari haric): AYNI  $(sha256sum < $B/net_new.v | cut -c1-16)"
else
  echo "NETLIST: FARKLI"; rc=1
fi
rm -rf $B
exit $rc
