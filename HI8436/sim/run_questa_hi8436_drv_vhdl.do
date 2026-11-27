# hi8436_top (VHDL-2008: hi8436_drv + common/rtl/async/spi_exec) + HI-8436 modeli: Questa akışı
# Tasarım tamamen VHDL; yalnız testbench ve HI-8436 modeli Verilog.
# Resmi doğrulama sonucu bu script'ten alınır (bu ortamda GHDL synth -> Icarus akışı koştu).
#
#   tb_hi8436_drv: T01-T23 + G (genel kontroller). T14 ikinci bir DUT kullanır
#   (hi8436_top, VERIFY_EVERY = 8; mixed-language generic override).
#
# Komut satırı:  cd sim ; vsim -c -do run_questa_hi8436_drv_vhdl.do
# GUI:           cd sim ; vsim -do run_questa_hi8436_drv_vhdl.do
# Timing köşeleri: T_SO = 5.0 ve 35.0 (SCK düşen -> SO, model). Core genişliği köşesi: DW = 16 / 32.
#
# Not: testbench +define+QUESTA ile derlenir; iç sinyallere SignalSpy
# ($init_signal_spy / $signal_force) ile erişir, bu yüzden +acc gerekir.

quietly set T_SO   35.0
quietly set DW     8
quietly set RTL    ../rtl
quietly set CORE   ../../common/rtl/async
quietly set TB     ../tb
quietly set LIB    work_hi8436_vhdl

if {[file exists $LIB]} { vdel -lib $LIB -all }
vlib $LIB
vmap work $LIB

# 1) Ortak SPI core (VHDL çevirisi, async reset)
vcom -2008 -work work $CORE/spi_exec_shiftreg.vhd
vcom -2008 -work work $CORE/spi_exec.vhd

# 2) Driver ve top (VHDL-2008)
vcom -2008 -work work $RTL/hi8436_drv.vhd
vcom -2008 -work work $RTL/hi8436_top.vhd

# 3) HI-8436 modeli ve testbench (Verilog / SystemVerilog sözdizimi)
vlog -sv -work work +define+QUESTA $TB/hi8436_model.v $TB/tb_hi8436_drv.v

# 4) Simülasyon
vsim -onfinish stop -voptargs=+acc -gT_SO=$T_SO -gDW=$DW work.tb_hi8436_drv

if {![batch_mode]} {
  add wave -group top /tb_hi8436_drv/clk /tb_hi8436_drv/rst_n /tb_hi8436_drv/start \
    /tb_hi8436_drv/stop /tb_hi8436_drv/continuous /tb_hi8436_drv/period_us \
    /tb_hi8436_drv/bank_mode /tb_hi8436_drv/st_req /tb_hi8436_drv/busy \
    /tb_hi8436_drv/cfg_done /tb_hi8436_drv/err /tb_hi8436_drv/err_code \
    /tb_hi8436_drv/sense_valid /tb_hi8436_drv/sense /tb_hi8436_drv/sense_chg \
    /tb_hi8436_drv/sense_act /tb_hi8436_drv/st_done /tb_hi8436_drv/st_fail
  add wave -group spi /tb_hi8436_drv/spi_cs_n /tb_hi8436_drv/spi_sclk \
    /tb_hi8436_drv/spi_mosi /tb_hi8436_drv/spi_miso /tb_hi8436_drv/spi_mr_n
  add wave -group drv /tb_hi8436_drv/u_dut/u_drv/state /tb_hi8436_drv/u_dut/u_drv/idx \
    /tb_hi8436_drv/u_dut/u_drv/pk_st /tb_hi8436_drv/u_dut/u_drv/pk_idx \
    /tb_hi8436_drv/u_dut/u_drv/frm_pend /tb_hi8436_drv/u_dut/u_drv/stl_ok \
    /tb_hi8436_drv/u_dut/u_drv/per_ok /tb_hi8436_drv/u_dut/u_drv/rx_sh \
    /tb_hi8436_drv/u_dut/cmd /tb_hi8436_drv/u_dut/cmd_valid /tb_hi8436_drv/u_dut/cmd_ready \
    /tb_hi8436_drv/u_dut/sdi_valid /tb_hi8436_drv/u_dut/sync_valid /tb_hi8436_drv/u_dut/core_rst
  add wave -group model /tb_hi8436_drv/u_hi/ctrl /tb_hi8436_drv/u_hi/psen \
    /tb_hi8436_drv/u_hi/tmdata /tb_hi8436_drv/u_hi/so_reg /tb_hi8436_drv/lvl
}

run -all
