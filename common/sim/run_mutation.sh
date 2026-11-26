#!/usr/bin/env bash
# Mutation sanity check: VHDL'e bilerek 5 küçük hata koyar; lockstep her birini yakalamalı.
set -e
cd "$(dirname "$0")"
rm -rf build/mut; mkdir -p build/mut
python3 - <<'PY'
import shutil
muts={
 'M1_cpha_ignored':('p1','spi_exec_p1.vhd',"sclk_int <= cpol xor cpha xor ntx_rx;","sclk_int <= cpol xor ntx_rx;"),
 'M2_last_transfer_off_by_one':('async','spi_exec.vhd',"if transfer_counter = unsigned(cmd_d1(7 downto 0)) then","if transfer_counter + 1 = unsigned(cmd_d1(7 downto 0)) then"),
 'M3_sdi_delay_index':('async','spi_exec_shiftreg.vhd',"trigger_rx_s <= trigger_rx_d(SDI_D + 1);","trigger_rx_s <= trigger_rx_d(SDI_D);"),
 'M4_sleep_bug_fixed':('p1','spi_exec_p1.vhd',"to_integer(unsigned(cmd_d1(7 downto 0))) + 1 else '0';","to_integer(unsigned(cmd_d1(7 downto 0))) else '0';"),
 'M5_cs_activate_mask':('async','spi_exec.vhd',"cs_activate <= (not all_ones) and cs_gen;","cs_activate <= cs_gen;"),
}
for name,(d,f,a,b) in muts.items():
    root='build/mut/'+name
    shutil.copytree('../rtl/p1',root+'/p1'); shutil.copytree('../rtl/async',root+'/async')
    p=f'{root}/{d}/{f}'; s=open(p,encoding='utf-8').read(); assert s.count(a)==1, name
    open(p,'w',encoding='utf-8').write(s.replace(a,b))
PY
for m in $(ls build/mut); do
  for c in "16 1 1 0 2 2 1" "32 8 2 3 3 1 0"; do
    r=$(MUT=1 ./run_lockstep.sh $c 7 200000 build/mut/$m/p1 build/mut/$m/async 2>&1 | grep -E "MUTATION" )
    echo "$m [$c] $r"
  done
done
