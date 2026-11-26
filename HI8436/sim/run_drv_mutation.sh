#!/usr/bin/env bash
# Mutation sanity check (varsayılan generic'ler, INIT_EVERY_START = false): RTL'in (rtl/ kopyası) içine bilerek küçük hatalar konur; senaryo
# testleri (tb_hi8436_drv) her birini yakalamalı (SONUC: BASARISIZ). rtl/'ye dokunulmaz:
# kopya üzerinde çalışılır, koşu sonunda kopya silinir.
# Ayrıca negatif kontrol N1: driver ve top'taki bütün clocked process'ler SYNC reset'e
# çevrilir; reset testleri (T20-T22) kalmalı ve flop kontrolü başarısız olmalı.
#   ./run_drv_mutation.sh [T_SO]      (varsayılan 35.0, yavaş timing köşesi)
set -e
cd "$(dirname "$0")"
TSO=${1:-35.0}
M=$(mktemp -d mut_XXXXXX)
[ -n "$KEEP" ] || trap 'rm -rf $M' EXIT
python3 -I - $M <<'PY'
import shutil, sys, re
root = sys.argv[1]
D = 'hi8436_drv.vhd'; T = 'hi8436_top.vhd'
muts = {
 # M1: F8 byte sırası ters (DB0 -> sense[31:24])
 'M1_f8_byte_sirasi': [(D, "rx_sh   <= rx_sh(23 downto 0) & sdi_data(7 downto 0);",
                           "rx_sh   <= sdi_data(7 downto 0) & rx_sh(31 downto 8);")],
 # M2: 2 byte'lık yazmada DB1/DB0 yer değiştirmiş (GOCENHYS / SOCENHYS)
 'M2_esik_byte_sirasi': [(D, "sq1    <= pk_d1;      -- 2 byte'lık yazma: önce DB1 (s.7 Tbl 6, s.5 Fig 6)\n                  sq2    <= pk_d0;",
                             "sq1    <= pk_d0;\n                  sq2    <= pk_d1;")],
 # M3: settle timer clear kaybı (yazmadan hemen sonra F8)
 'M3_settle_clear_kaybi': [(D, "      if pk_ok = '1' and pk_rd = '0' then\n        stl_cnt <= 0;\n      elsif stl_cnt < SETTLE_CLKS - 1 then",
                               "      if stl_cnt < SETTLE_CLKS - 1 then")],
 # M4: sense_chg önceki değere göre değil (xor unutulmuş)
 'M4_sense_chg_xor_yok': [(D, "sense_chg_r <= rx_sh xor sense_r;", "sense_chg_r <= rx_sh;")],
 # M5: async reset değeri: mr_n reset'te '0'
 'M5_mr_n_reset_degeri': [(D, "      mr_n_r     <= '1';\n      core_rst_r <= '0';\n      rst_cnt    <= 0;",
                              "      mr_n_r     <= '0';\n      core_rst_r <= '0';\n      rst_cnt    <= 0;")],
 # M6: CONFIG mode CPHA = 1 (Mode 1)
 'M6_cpha_1': [(D, 'constant C_SPI_MODE0   : std_logic_vector(7 downto 0) := x"00";',
                   'constant C_SPI_MODE0   : std_logic_vector(7 downto 0) := x"01";')],
 # M7: geri okumada son register (TMDATA) karşılaştırılmıyor
 'M7_geri_okuma_atlanan': [(D, "if frm_pend = '1' and rx_sh(15 downto 0) /= rb_exp then",
                               "if frm_pend = '1' and idx /= 4 and rx_sh(15 downto 0) /= rb_exp then")],
 # M8: eksik sdi kelimesi kontrolü yok
 'M8_sdi_eksik_kontrol_yok': [(D, "sdi_miss  <= '1' when frm_done = '1' and exp_cnt /= 0 else '0';",
                                  "sdi_miss  <= '0';")],
 # M9: period gecikme telafisi yanlış (launch aralığı 10 ns kayar)
 'M9_period_telafi': [(D, "constant C_PER_LAT : integer := 4;", "constant C_PER_LAT : integer := 3;")],
 # M10: yapısal hatadan sonra init_done temizlenmiyor (sonraki start tam init yapmaz)
 'M10_yapisal_init_done': [(D, "        init_done  <= '0';\n        frm_pend   <= '0';\n        mr_n_r     <= '1';",
                               "        frm_pend   <= '0';\n        mr_n_r     <= '1';")],
 # M11: ayar karşılaştırması bir alanı atlıyor (so_hyst)
 'M11_ayar_karsilastirma': [(D, "d_so <= '1' when so_center /= sh_soc or so_hyst /= sh_soh else '0';",
                                "d_so <= '1' when so_center /= sh_soc else '0';")],
}
for name, edits in muts.items():
    d = f'{root}/{name}'; shutil.copytree('../rtl', d)
    for f, a, b in edits:
        p = f'{d}/{f}'; s = open(p, encoding='utf-8').read()
        assert s.count(a) == 1, (name, a[:50]); open(p, 'w', encoding='utf-8').write(s.replace(a, b))
# N1: sync reset kopyası (bütün clocked process'ler)
d = f'{root}/N1_sync_reset'; shutil.copytree('../rtl', d)
for f in (D, T):
    p = f'{d}/{f}'; s = open(p, encoding='utf-8').read()
    n = s.count("process (clk, rst_n)")
    s = s.replace("process (clk, rst_n)", "process (clk)")
    s = re.sub(r"(?m)^    if rst_n = '0' then$", "    if rising_edge(clk) then\n    if rst_n = '0' then", s)
    s = re.sub(r"(?m)^    elsif rising_edge\(clk\) then$", "    else", s)
    s = re.sub(r"(\n    end if;\n)(  end process)", r"\1    end if;\n\2", s)
    assert s.count("process (clk)") == n and n > 0
    open(p, 'w', encoding='utf-8').write(s)
PY
for m in $(ls $M); do
  ( ./run_hi8436_drv_vhdl.sh $TSO 8 $M/$m > $M/$m.log 2>&1; echo "rc=$?" >> $M/$m.log ) &
done
wait
./run_flop_check.sh $M/N1_sync_reset > $M/N1_flop.log 2>&1 || true
rc=0
for m in $(ls -d $M/*/ | xargs -n1 basename); do
  f=$(grep -E "^ *FAIL" $M/$m.log | sed -E 's/^ *FAIL +([TG][0-9]*).*/\1/' | tr '\n' ' ')
  v=$(grep -oE "timing ihlali=[0-9]+" $M/$m.log | head -1)
  if grep -q "SONUC: BASARILI" $M/$m.log; then r="KACIRILDI"; rc=1; else r="YAKALANDI"; fi
  echo "$m: MUTATION $r | kalan testler: ${f:--} | $v"
  if [ "$m" = "N1_sync_reset" ]; then
    for t in T20 T21 T22; do echo "$f" | grep -q "$t" || { echo "   NEGATIF KONTROL: $t sync reset kopyada GECTI"; rc=1; }; done
    echo "   N1 flop kontrolu: $(grep -E 'YAPISAL KONTROL|Düz' $M/N1_flop.log | sed 's/ -> .*//' | tr '\n' ' ')"
    grep -q "YAPISAL KONTROL: BASARISIZ" $M/N1_flop.log || rc=1
  fi
done
[ -n "$KEEP" ] && echo "loglar: $M"
sha256sum ../rtl/*.vhd
[ $rc -eq 0 ] && echo "SONUC: BASARILI (butun mutation'lar yakalandi, negatif kontrol dogru)" || echo "SONUC: BASARISIZ"
exit $rc
