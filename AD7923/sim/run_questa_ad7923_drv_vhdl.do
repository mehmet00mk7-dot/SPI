# ad7923_top + spi_exec (VHDL-2008, async reset) + AD7923 modeli: Questa akışı
# Tasarım tamamen VHDL; yalnız testbench ve AD7923 modeli Verilog.
# Resmi doğrulama sonucu bu script'ten alınır.
#
# Driver (ad7923_drv, ad7923_ch_regs, ad7923_top) async reset'tir.
#   1) tb_ad7923_drv   : T01-T19 (mevcut) + T20-T22 (async reset: frame ortası, clock
#                        dururken, 1 clock'luk reset) -> 22 test
#   2) tb_drv_lockstep : eski sync driver (tb/sync_ref, *_sref) <-> yeni async driver,
#                        her clock bütün çıkışlar. Yalnız batch modda ve RUN_LOCKSTEP = 1 ise.
#                        LS_SEEDS / LS_CYCLES ile ayarlanır.
#
# Çalıştırma: çalışma dizini mutlaka SPI/AD7923/sim olmalı. Script ../rtl, ../tb ve
# ../../common/rtl/async yollarını kullanır (reponun tamamı gerekir, yalnız AD7923/ yetmez).
#   ModelSim / Questa Transcript penceresinden (program açıkken):
#       cd <yol>/SPI/AD7923/sim
#       do run_questa_ad7923_drv_vhdl.do
#     DİKKAT: Transcript'te "vsim -do ..." YAZMAYIN. Program içinde vsim "tasarım yükle"
#     demektir; tasarım adı verilmeyince "No design specified" hatası verir.
#   İşletim sistemi terminalinden (cmd / PowerShell / bash, program kapalıyken):
#       cd <yol>/SPI/AD7923/sim
#       vsim -c -do run_questa_ad7923_drv_vhdl.do      (GUI'siz, lockstep dahil)
#       vsim -do run_questa_ad7923_drv_vhdl.do         (GUI, yalnız tb_ad7923_drv)
#   Klasör yolunda Türkçe karakter / boşluk olmamalı (ör. Masaüstü, OneDrive): ModelSim
#   kütüphane dosyalarını okuyamaz ("Failed to open design unit file ... in read mode").
# DOUT gecikmesi köşeleri: aşağıdaki T_DOUT değerini 12.0 / 25.0 / 40.0 yapın.
#
# Not: testbench +define+QUESTA ile derlenir; iç sinyallere SignalSpy
# ($init_signal_spy / $signal_force) ile erişir, bu yüzden +acc gerekir.

quietly set T_DOUT 25.0
quietly set RTL    ../rtl
quietly set CORE   ../../common/rtl/async
quietly set TB     ../tb
quietly set LIB    work_ad7923_vhdl
quietly set RUN_LOCKSTEP 1
quietly set LS_SEEDS  {1 2 3}
quietly set LS_CYCLES 2000000

if {[file exists $LIB]} { vdel -lib $LIB -all }
vlib $LIB
vmap work $LIB

# 1) SPI core (VHDL çevirisi, async reset; ortak: common/rtl/async)
vcom -2008 -work work $CORE/spi_exec_shiftreg.vhd
vcom -2008 -work work $CORE/spi_exec.vhd

# 2) Driver ve top (VHDL-2008)
vcom -2008 -work work $RTL/ad7923_drv.vhd
vcom -2008 -work work $RTL/ad7923_ch_regs.vhd
vcom -2008 -work work $RTL/ad7923_top.vhd

# 2b) Referans: async geçişinden önceki sync reset driver (yalnız lockstep için)
vcom -2008 -work work $TB/sync_ref/ad7923_drv_sref.vhd
vcom -2008 -work work $TB/sync_ref/ad7923_ch_regs_sref.vhd
vcom -2008 -work work $TB/sync_ref/ad7923_top_sref.vhd

# 3) AD7923 modeli ve testbench'ler (Verilog / SystemVerilog sözdizimi)
vlog -sv -work work +define+QUESTA $TB/ad7923_model.v $TB/tb_ad7923_drv.v $TB/tb_drv_lockstep.v

# 4) Simülasyon
vsim -onfinish stop -voptargs=+acc -gT_DOUT=$T_DOUT work.tb_ad7923_drv

if {![batch_mode]} {
  add wave -group top /tb_ad7923_drv/clk /tb_ad7923_drv/rst_n /tb_ad7923_drv/start \
    /tb_ad7923_drv/stop /tb_ad7923_drv/continuous /tb_ad7923_drv/ch_mask \
    /tb_ad7923_drv/busy /tb_ad7923_drv/err /tb_ad7923_drv/data_valid \
    /tb_ad7923_drv/data_ch /tb_ad7923_drv/data \
    /tb_ad7923_drv/ch0_valid /tb_ad7923_drv/ch1_valid /tb_ad7923_drv/ch2_valid \
    /tb_ad7923_drv/ch3_valid /tb_ad7923_drv/scan_done /tb_ad7923_drv/ch0_data \
    /tb_ad7923_drv/ch1_data /tb_ad7923_drv/ch2_data /tb_ad7923_drv/ch3_data
  add wave -group spi /tb_ad7923_drv/spi_cs_n /tb_ad7923_drv/spi_sclk \
    /tb_ad7923_drv/spi_mosi /tb_ad7923_drv/spi_miso
  add wave -group drv /tb_ad7923_drv/u_dut/u_drv/state /tb_ad7923_drv/u_dut/u_drv/pk_st \
    /tb_ad7923_drv/u_dut/u_drv/pk_idx /tb_ad7923_drv/u_dut/u_drv/cur_ch \
    /tb_ad7923_drv/u_dut/u_drv/chip_sel /tb_ad7923_drv/u_dut/u_drv/chip_sel_vld \
    /tb_ad7923_drv/u_dut/u_drv/err_cnt /tb_ad7923_drv/u_dut/cmd \
    /tb_ad7923_drv/u_dut/cmd_valid /tb_ad7923_drv/u_dut/cmd_ready \
    /tb_ad7923_drv/u_dut/sdi_valid /tb_ad7923_drv/u_dut/sync_valid \
    /tb_ad7923_drv/u_dut/core_rst
  add wave -group reset /tb_ad7923_drv/clk_en /tb_ad7923_drv/exp_abort_win /tb_ad7923_drv/n_exp_abort
}

run -all

# 5) Driver lockstep (sync referans <-> async driver), yalnız batch modda
if {[batch_mode] && $RUN_LOCKSTEP} {
  foreach s $LS_SEEDS {
    quit -sim
    vsim -onfinish stop -voptargs=+acc -gSEED=$s -gCYCLES=$LS_CYCLES work.tb_drv_lockstep
    run -all
  }
}
