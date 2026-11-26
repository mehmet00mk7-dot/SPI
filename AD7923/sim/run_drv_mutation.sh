#!/usr/bin/env bash
# Driver lockstep mutation sanity check: async driver'a (rtl/drv kopyası) bilerek küçük
# hatalar konur; tb_drv_lockstep her birini yakalamalı. rtl/drv'ye dokunulmaz (kopya
# üzerinde çalışılır, koşu sonunda kopya silinir = hata geri alınmış olur).
#   ./run_drv_mutation.sh [CYCLES] [SEED]
set -e
cd "$(dirname "$0")"
CYC=${1:-400000}; SEED=${2:-1}
rm -rf build/dmut; mkdir -p build/dmut
python3 -I - <<'PY'
import shutil
muts={
 # 1) Reset değeri yanlış: pwr_done reset'te '1' -> reset sonrası power-up (dummy frame) atlanır
 'D1_pwr_done_reset_degeri':('ad7923_drv.vhd',
     "\n      pwr_done     <= '0';\n      stop_pend",
     "\n      pwr_done     <= '1';\n      stop_pend"),
 # 2) Eksik reset: data_r async reset listesinden düşmüş (reset'te eski değerini korur)
 'D2_data_r_reset_eksik':('ad7923_drv.vhd',
     "      data_r       <= (others => '0');\n      data_last_r  <= '0';\n      rx_err_p     <= '0';\n    elsif",
     "      data_last_r  <= '0';\n      rx_err_p     <= '0';\n    elsif"),
 # 3) Soft clear kaybı: "rst_n = '0' or frm_launch = '1'" ayrılırken frm_launch clear'ı unutulmuş
 'D3_cyc_soft_clear_kayip':('ad7923_drv.vhd',
     "      if frm_launch = '1' then\n        cyc_cnt <= 0;\n      elsif cyc_cnt < CYCLE_CLKS - 1 then",
     "      if cyc_cnt < CYCLE_CLKS - 1 then"),
 # 4) Kanal register'ı: reset'te scan_done_r '1' (ch_regs reset değeri hatası)
 'D4_ch_regs_scan_done_reset':('ad7923_ch_regs.vhd',
     "      ch_valid_r  <= (others => '0');\n      scan_done_r <= '0';\n    elsif",
     "      ch_valid_r  <= (others => '0');\n      scan_done_r <= '1';\n    elsif"),
}
for name,(f,a,b) in muts.items():
    root='build/dmut/'+name
    shutil.copytree('../rtl/drv',root)
    p=f'{root}/{f}'; s=open(p,encoding='utf-8').read(); assert s.count(a)==1, name
    open(p,'w',encoding='utf-8').write(s.replace(a,b))
PY
for m in $(ls build/dmut); do
  echo "$(MUT=1 ./run_drv_lockstep.sh $SEED $CYC build/dmut/$m > build/dmut/$m.log 2>&1; true)" >/dev/null &
done
wait
for m in $(ls -d build/dmut/*/ | xargs -n1 basename); do
  r=$(grep -E "MUTATION" build/dmut/$m.log)
  echo "$m $r"
  # ilk fark: clock, zaman, farklı alanlar (ref / dut)
  awk '/FARK: clock|ASYNC RESET HATASI/{n++} n==1' build/dmut/$m.log | grep -v "alan " | sed 's/^ */      /'
done
rm -rf build/dmut
sha256sum ../rtl/drv/*.vhd
