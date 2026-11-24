# ad7923_top + spi_exec (VHDL-2008, async reset) + AD7923 modeli: Questa akışı
# Tasarım tamamen VHDL; yalnız testbench ve AD7923 modeli Verilog.
# Resmi doğrulama sonucu bu script'ten alınır.
#
# Komut satırı:  cd sim ; vsim -c -do run_questa_ad7923_drv.do
# GUI:           cd sim ; vsim -do run_questa_ad7923_drv.do
# DOUT gecikmesi köşeleri: aşağıdaki T_DOUT değerini 12.0 / 25.0 / 40.0 yapın.
#
# Not: testbench +define+QUESTA ile derlenir; iç sinyallere SignalSpy
# ($init_signal_spy / $signal_force) ile erişir, bu yüzden +acc gerekir.

quietly set T_DOUT 25.0
quietly set RTL    ../rtl
quietly set TB     ../tb
quietly set LIB    work_ad7923_vhdl

if {[file exists $LIB]} { vdel -lib $LIB -all }
vlib $LIB
vmap work $LIB

# 1) SPI core (VHDL çevirisi, async reset)
vcom -2008 -work work $RTL/async/spi_exec_shiftreg.vhd
vcom -2008 -work work $RTL/async/spi_exec.vhd

# 2) Driver ve top (VHDL-2008)
vcom -2008 -work work $RTL/drv/ad7923_drv.vhd
vcom -2008 -work work $RTL/drv/ad7923_ch_regs.vhd
vcom -2008 -work work $RTL/drv/ad7923_top.vhd

# 3) AD7923 modeli ve testbench (Verilog / SystemVerilog sözdizimi)
vlog -sv -work work +define+QUESTA $TB/ad7923_model.v $TB/tb_ad7923_drv.v

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
}

run -all
