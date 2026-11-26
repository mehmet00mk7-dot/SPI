// ============================================================================
// tb_drv_lockstep.v  -  Eski (sync reset) <-> yeni (async reset) AD7923 driver lockstep
//
//   u_ref : ad7923_top_sref  (tb/sync_ref: async geçişinden önceki driver, sync reset)
//   u_dut : ad7923_top       (rtl: async reset driver)
//   İkisi de aynı core'u (common/rtl/async/spi_exec) kullanır; her birinin KENDİ AD7923 modeli var.
//
// Uyarım (iki tasarıma aynı):
//   * Kontrol girişleri (start, stop, continuous, ch_mask, period_us, range_sel,
//     coding_sel) rastgele ama yasal; posedge + 1 ns'de değişir.
//   * Rastgele rst_n pulse'ı: sync assert (posedge + 1 ns), >= 8 clock, sync deassert.
//   * Hata enjeksiyonu (err / ERR_LIMIT / core_rst kapsaması için), iki tarafa aynı:
//       - frame bozma: MISO frame boyunca 1 (format hatası) veya 0 (adres hatası),
//         ara sıra art arda birçok frame (ERR_LIMIT -> driver durur)
//       - SYNC timeout: sync_valid force 0 (-> core_rst)
//       - FIFO underflow: sdi_valid 1 clk force 1
//       - SYNC id hatası: sync force
//
// Karşılaştırma: her clock'un negedge'inde (çıkışlar posedge'de değişir) BÜTÜN top
// çıkışları ve driver <-> core arayüzü (cmd, cmd_valid, sdo_data, sdo_valid, core_rst,
// core_resetn, sync, sync_valid, sdi_valid, sdi_data, cmd_ready) !== ile karşılaştırılır.
// Tek atlanan aralık: rst_n'nin düştüğü an -> rst_n = 0 iken gelen ilk posedge
// (sync referans reset'i henüz görmedi). Bu aralıkta async DUT'un çıkışlarının
// reset değerinde olduğu ayrıca kontrol edilir. Reset sırasında (ilk posedge'den
// sonra) ve reset kalktığı clock'tan itibaren her clock karşılaştırılır.
//
// Parametreler: SEED, CYCLES, MUT (1: mutation koşusu; fark beklenir).
// Çalıştırma: sim/run_drv_lockstep.sh SEED CYCLES [DRV_DIR]
// ============================================================================
`timescale 1ns/100ps

module tb_drv_lockstep;

  parameter integer SEED   = 1;
  parameter integer CYCLES = 2000000;
  parameter integer MUT    = 0;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg        rst_n = 1'b0, start = 1'b0, stop = 1'b0, continuous = 1'b0;
  reg        range_sel = 1'b1, coding_sel = 1'b1;
  reg [3:0]  ch_mask   = 4'hF;
  reg [15:0] period_us = 16'd0;

  // ------------------------------------------------------------ iki tasarım
  wire        r_data_valid, r_busy, r_err, r_scan_done, r_sclk, r_mosi, r_cs_n, r_miso;
  wire [1:0]  r_data_ch;
  wire [11:0] r_data, r_ch0, r_ch1, r_ch2, r_ch3;
  wire        r_v0, r_v1, r_v2, r_v3;
  wire        d_data_valid, d_busy, d_err, d_scan_done, d_sclk, d_mosi, d_cs_n, d_miso;
  wire [1:0]  d_data_ch;
  wire [11:0] d_data, d_ch0, d_ch1, d_ch2, d_ch3;
  wire        d_v0, d_v1, d_v2, d_v3;

  ad7923_top_sref u_ref (
    .clk(clk), .rst_n(rst_n), .start(start), .stop(stop), .continuous(continuous),
    .ch_mask(ch_mask), .period_us(period_us), .range_sel(range_sel), .coding_sel(coding_sel),
    .data_valid(r_data_valid), .data_ch(r_data_ch), .data(r_data), .busy(r_busy), .err(r_err),
    .ch0_data(r_ch0), .ch1_data(r_ch1), .ch2_data(r_ch2), .ch3_data(r_ch3),
    .ch0_valid(r_v0), .ch1_valid(r_v1), .ch2_valid(r_v2), .ch3_valid(r_v3),
    .scan_done(r_scan_done), .spi_sclk(r_sclk), .spi_mosi(r_mosi), .spi_cs_n(r_cs_n), .spi_miso(r_miso));

  ad7923_top u_dut (
    .clk(clk), .rst_n(rst_n), .start(start), .stop(stop), .continuous(continuous),
    .ch_mask(ch_mask), .period_us(period_us), .range_sel(range_sel), .coding_sel(coding_sel),
    .data_valid(d_data_valid), .data_ch(d_data_ch), .data(d_data), .busy(d_busy), .err(d_err),
    .ch0_data(d_ch0), .ch1_data(d_ch1), .ch2_data(d_ch2), .ch3_data(d_ch3),
    .ch0_valid(d_v0), .ch1_valid(d_v1), .ch2_valid(d_v2), .ch3_valid(d_v3),
    .scan_done(d_scan_done), .spi_sclk(d_sclk), .spi_mosi(d_mosi), .spi_cs_n(d_cs_n), .spi_miso(d_miso));

  // her tasarımın kendi AD7923 modeli
  tri1 r_dout, d_dout;
  ad7923_model #(.ID(2'd0), .T_DOUT(25.0)) m_ref (.cs_n(r_cs_n), .sclk(r_sclk), .din(r_mosi), .dout(r_dout));
  ad7923_model #(.ID(2'd0), .T_DOUT(25.0)) m_dut (.cs_n(d_cs_n), .sclk(d_sclk), .din(d_mosi), .dout(d_dout));

  // frame bozma (iki tarafa aynı): 0 = yok, 1 = MISO 1 (format), 2 = MISO 0 (adres)
  reg [1:0] corrupt = 2'd0;
  integer   burst_left = 0;      // art arda bozulacak frame sayısı (ERR_LIMIT kapsaması)
  assign r_miso = (corrupt == 2'd1) ? 1'b1 : (corrupt == 2'd2) ? 1'b0 : r_dout;
  assign d_miso = (corrupt == 2'd1) ? 1'b1 : (corrupt == 2'd2) ? 1'b0 : d_dout;

  // ------------------------------------------------ iç sinyallere erişim
  // Icarus: hierarchical referans. Questa (+define+QUESTA): VHDL içine Verilog
  // hierarchical referans / force olmadığı için SignalSpy ($init_signal_spy, $signal_force).
`ifdef QUESTA
  reg  [15:0] r_cmd = 16'd0, d_cmd = 16'd0;
  reg  r_cmd_valid = 1'd0, d_cmd_valid = 1'd0;
  reg  r_cmd_ready = 1'd0, d_cmd_ready = 1'd0;
  reg  [15:0] r_sdo_data = 16'd0, d_sdo_data = 16'd0;
  reg  r_sdo_valid = 1'd0, d_sdo_valid = 1'd0;
  reg  r_sdo_ready = 1'd0, d_sdo_ready = 1'd0;
  reg  r_core_rst = 1'd0, d_core_rst = 1'd0;
  reg  r_core_resetn = 1'd0, d_core_resetn = 1'd0;
  reg  [7:0] r_sync = 8'd0, d_sync = 8'd0;
  reg  r_sync_valid = 1'd0, d_sync_valid = 1'd0;
  reg  r_sdi_valid = 1'd0, d_sdi_valid = 1'd0;
  reg  [15:0] r_sdi_data = 16'd0, d_sdi_data = 16'd0;
  initial begin
    $init_signal_spy("/tb_drv_lockstep/u_ref/cmd", "/tb_drv_lockstep/r_cmd", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/cmd", "/tb_drv_lockstep/d_cmd", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/cmd_valid", "/tb_drv_lockstep/r_cmd_valid", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/cmd_valid", "/tb_drv_lockstep/d_cmd_valid", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/cmd_ready", "/tb_drv_lockstep/r_cmd_ready", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/cmd_ready", "/tb_drv_lockstep/d_cmd_ready", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/sdo_data", "/tb_drv_lockstep/r_sdo_data", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/sdo_data", "/tb_drv_lockstep/d_sdo_data", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/sdo_valid", "/tb_drv_lockstep/r_sdo_valid", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/sdo_valid", "/tb_drv_lockstep/d_sdo_valid", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/sdo_ready", "/tb_drv_lockstep/r_sdo_ready", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/sdo_ready", "/tb_drv_lockstep/d_sdo_ready", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/core_rst", "/tb_drv_lockstep/r_core_rst", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/core_rst", "/tb_drv_lockstep/d_core_rst", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/core_resetn", "/tb_drv_lockstep/r_core_resetn", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/core_resetn", "/tb_drv_lockstep/d_core_resetn", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/sync", "/tb_drv_lockstep/r_sync", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/sync", "/tb_drv_lockstep/d_sync", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/sync_valid", "/tb_drv_lockstep/r_sync_valid", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/sync_valid", "/tb_drv_lockstep/d_sync_valid", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/sdi_valid", "/tb_drv_lockstep/r_sdi_valid", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/sdi_valid", "/tb_drv_lockstep/d_sdi_valid", 0);
    $init_signal_spy("/tb_drv_lockstep/u_ref/sdi_data", "/tb_drv_lockstep/r_sdi_data", 0);
    $init_signal_spy("/tb_drv_lockstep/u_dut/sdi_data", "/tb_drv_lockstep/d_sdi_data", 0);
  end
  task frc_to;      begin $signal_force("/tb_drv_lockstep/u_ref/sync_valid", "0", 0, 3, -1, 0);
                          $signal_force("/tb_drv_lockstep/u_dut/sync_valid", "0", 0, 3, -1, 0); end endtask
  task rel_to;      begin $signal_release("/tb_drv_lockstep/u_ref/sync_valid", 0);
                          $signal_release("/tb_drv_lockstep/u_dut/sync_valid", 0); end endtask
  task frc_unf;     begin $signal_force("/tb_drv_lockstep/u_ref/sdi_valid", "1", 0, 3, -1, 0);
                          $signal_force("/tb_drv_lockstep/u_dut/sdi_valid", "1", 0, 3, -1, 0); end endtask
  task rel_unf;     begin $signal_release("/tb_drv_lockstep/u_ref/sdi_valid", 0);
                          $signal_release("/tb_drv_lockstep/u_dut/sdi_valid", 0); end endtask
  task frc_sid(input [7:0] v);
                    begin $signal_force("/tb_drv_lockstep/u_ref/sync", $sformatf("%b", v), 0, 3, -1, 0);
                          $signal_force("/tb_drv_lockstep/u_dut/sync", $sformatf("%b", v), 0, 3, -1, 0); end endtask
  task rel_sid;     begin $signal_release("/tb_drv_lockstep/u_ref/sync", 0);
                          $signal_release("/tb_drv_lockstep/u_dut/sync", 0); end endtask
`else
  wire [15:0] r_cmd = u_ref.cmd;
  wire r_cmd_valid = u_ref.cmd_valid;
  wire r_cmd_ready = u_ref.cmd_ready;
  wire [15:0] r_sdo_data = u_ref.sdo_data;
  wire r_sdo_valid = u_ref.sdo_valid;
  wire r_sdo_ready = u_ref.sdo_ready;
  wire r_core_rst = u_ref.core_rst;
  wire r_core_resetn = u_ref.core_resetn;
  wire [7:0] r_sync = u_ref.sync;
  wire r_sync_valid = u_ref.sync_valid;
  wire r_sdi_valid = u_ref.sdi_valid;
  wire [15:0] r_sdi_data = u_ref.sdi_data;
  wire [15:0] d_cmd = u_dut.cmd;
  wire d_cmd_valid = u_dut.cmd_valid;
  wire d_cmd_ready = u_dut.cmd_ready;
  wire [15:0] d_sdo_data = u_dut.sdo_data;
  wire d_sdo_valid = u_dut.sdo_valid;
  wire d_sdo_ready = u_dut.sdo_ready;
  wire d_core_rst = u_dut.core_rst;
  wire d_core_resetn = u_dut.core_resetn;
  wire [7:0] d_sync = u_dut.sync;
  wire d_sync_valid = u_dut.sync_valid;
  wire d_sdi_valid = u_dut.sdi_valid;
  wire [15:0] d_sdi_data = u_dut.sdi_data;
  task frc_to;      begin force u_ref.sync_valid = 1'b0; force u_dut.sync_valid = 1'b0; end endtask
  task rel_to;      begin release u_ref.sync_valid; release u_dut.sync_valid; end endtask
  task frc_unf;     begin force u_ref.sdi_valid = 1'b1; force u_dut.sdi_valid = 1'b1; end endtask
  task rel_unf;     begin release u_ref.sdi_valid; release u_dut.sdi_valid; end endtask
  // sabit değerle force (RHS bir kez değerlendirilir)
  task frc_sid(input [7:0] v);
    case (v)
      8'h5A:   begin force u_ref.sync = 8'h5A; force u_dut.sync = 8'h5A; end
      8'hA5:   begin force u_ref.sync = 8'hA5; force u_dut.sync = 8'hA5; end
      8'h3C:   begin force u_ref.sync = 8'h3C; force u_dut.sync = 8'h3C; end
      default: begin force u_ref.sync = 8'hC3; force u_dut.sync = 8'hC3; end
    endcase
  endtask
  task rel_sid;     begin release u_ref.sync; release u_dut.sync; end endtask
`endif

  // ------------------------------------------------------------ karşılaştırılan vektör
  wire [91:0] r_vec = {r_data_valid, r_data_ch, r_data, r_busy, r_err, r_ch0, r_ch1, r_ch2, r_ch3,
                       r_v0, r_v1, r_v2, r_v3, r_scan_done, r_sclk, r_mosi, r_cs_n};
  wire [91:0] d_vec = {d_data_valid, d_data_ch, d_data, d_busy, d_err, d_ch0, d_ch1, d_ch2, d_ch3,
                       d_v0, d_v1, d_v2, d_v3, d_scan_done, d_sclk, d_mosi, d_cs_n};
  // driver <-> core arayüzü (top içindeki net'ler)
  wire [76:0] r_ivec = {r_cmd, r_cmd_valid, r_cmd_ready, r_sdo_data, r_sdo_valid,
                        r_core_rst, r_core_resetn, r_sync, r_sync_valid,
                        r_sdi_valid, r_sdi_data};
  wire [76:0] d_ivec = {d_cmd, d_cmd_valid, d_cmd_ready, d_sdo_data, d_sdo_valid,
                        d_core_rst, d_core_resetn, d_sync, d_sync_valid,
                        d_sdi_valid, d_sdi_data};

  // async DUT'un reset değerleri (atlanan aralıkta beklenen)
  wire d_in_reset = (d_data_valid === 1'b0) && (d_data_ch === 2'd0) && (d_data === 12'd0) &&
                    (d_busy === 1'b0) && (d_err === 1'b0) &&
                    (d_ch0 === 12'd0) && (d_ch1 === 12'd0) && (d_ch2 === 12'd0) && (d_ch3 === 12'd0) &&
                    (d_v0 === 1'b0) && (d_v1 === 1'b0) && (d_v2 === 1'b0) && (d_v3 === 1'b0) &&
                    (d_scan_done === 1'b0) && (d_cs_n === 1'b1) && (d_sclk === 1'b1) &&
                    (d_core_rst === 1'b0) && (d_cmd_valid === 1'b0) && (d_sdo_valid === 1'b0);

  task show_diff;
    begin
      $display("      alan      ref          dut");
      if (r_data_valid !== d_data_valid) $display("      data_valid %b %b", r_data_valid, d_data_valid);
      if (r_data_ch    !== d_data_ch)    $display("      data_ch    %h %h", r_data_ch, d_data_ch);
      if (r_data       !== d_data)       $display("      data       %h %h", r_data, d_data);
      if (r_busy       !== d_busy)       $display("      busy       %b %b", r_busy, d_busy);
      if (r_err        !== d_err)        $display("      err        %b %b", r_err, d_err);
      if (r_ch0 !== d_ch0) $display("      ch0_data   %h %h", r_ch0, d_ch0);
      if (r_ch1 !== d_ch1) $display("      ch1_data   %h %h", r_ch1, d_ch1);
      if (r_ch2 !== d_ch2) $display("      ch2_data   %h %h", r_ch2, d_ch2);
      if (r_ch3 !== d_ch3) $display("      ch3_data   %h %h", r_ch3, d_ch3);
      if ({r_v0, r_v1, r_v2, r_v3} !== {d_v0, d_v1, d_v2, d_v3}) $display("      chN_valid  %b%b%b%b %b%b%b%b", r_v3, r_v2, r_v1, r_v0, d_v3, d_v2, d_v1, d_v0);
      if (r_scan_done !== d_scan_done) $display("      scan_done  %b %b", r_scan_done, d_scan_done);
      if (r_sclk !== d_sclk) $display("      spi_sclk   %b %b", r_sclk, d_sclk);
      if (r_mosi !== d_mosi) $display("      spi_mosi   %b %b", r_mosi, d_mosi);
      if (r_cs_n !== d_cs_n) $display("      spi_cs_n   %b %b", r_cs_n, d_cs_n);
      if (r_cmd       !== d_cmd)       $display("      cmd        %h %h", r_cmd, d_cmd);
      if (r_cmd_valid !== d_cmd_valid) $display("      cmd_valid  %b %b", r_cmd_valid, d_cmd_valid);
      if (r_cmd_ready !== d_cmd_ready) $display("      cmd_ready  %b %b", r_cmd_ready, d_cmd_ready);
      if (r_sdo_data  !== d_sdo_data)  $display("      sdo_data   %h %h", r_sdo_data, d_sdo_data);
      if (r_sdo_valid !== d_sdo_valid) $display("      sdo_valid  %b %b", r_sdo_valid, d_sdo_valid);
      if (r_core_rst  !== d_core_rst)  $display("      core_rst   %b %b", r_core_rst, d_core_rst);
      if (r_core_resetn !== d_core_resetn) $display("      core_resetn %b %b", r_core_resetn, d_core_resetn);
      if (r_sync      !== d_sync)      $display("      sync       %h %h", r_sync, d_sync);
      if (r_sync_valid !== d_sync_valid) $display("      sync_valid %b %b", r_sync_valid, d_sync_valid);
      if (r_sdi_valid !== d_sdi_valid) $display("      sdi_valid  %b %b", r_sdi_valid, d_sdi_valid);
      if (r_sdi_data  !== d_sdi_data)  $display("      sdi_data   %h %h", r_sdi_data, d_sdi_data);
    end
  endtask

  // ------------------------------------------------------------ karşılaştırma
  integer cyc = 0, n_cmp = 0, n_skip = 0, n_diff = 0, n_shown = 0, n_async_chk = 0, n_async_bad = 0;
  integer first_diff_cyc = -1, last_rst_rel_cyc = -1;
  reg     skip = 1'b1;                 // t = 0: rst_n = 0, referans ilk posedge'de reset alır

  always @(negedge rst_n) skip = 1'b1;
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (rst_n === 1'b0) skip <= 1'b0;  // sync referans bu kenarda reset'e girdi
  end

  always @(negedge clk) begin
    if (skip) begin
      n_skip = n_skip + 1;
      if (cyc > 0) begin
        n_async_chk = n_async_chk + 1;
        if (!d_in_reset) begin
          n_async_bad = n_async_bad + 1;
          if (n_shown < 10) begin
            n_shown = n_shown + 1;
            $display("    ASYNC RESET HATASI: clock %0d (t=%0t): rst_n = 0 ama DUT cikislari reset degerinde degil", cyc, $time);
          end
        end
      end
    end else begin
      n_cmp = n_cmp + 1;
      if (r_vec !== d_vec || r_ivec !== d_ivec) begin
        n_diff = n_diff + 1;
        if (first_diff_cyc < 0) first_diff_cyc = cyc;
        if (n_shown < 10) begin
          n_shown = n_shown + 1;
          $display("    FARK: clock %0d (t=%0t ns), rst_n=%b, son reset kalkisindan %0d clock sonra",
                   cyc, $time / 10, rst_n, (last_rst_rel_cyc < 0) ? -1 : cyc - last_rst_rel_cyc);
          show_diff;
        end
      end
    end
  end

  // ------------------------------------------------------------ kapsama sayaçları
  integer c_start_pulse = 0, c_start_acc = 0, c_stop = 0, c_stop_busy = 0, c_cont_tog = 0, c_cont_scan = 0;
  integer c_mask = 0, c_mask_busy = 0, c_mask_zero = 0, c_err = 0, c_core_rst = 0, c_scan_done = 0;
  integer c_dv = 0, c_rst = 0, c_rst_frame = 0, c_period = 0, c_rc = 0;
  integer c_inj_frame = 0, c_inj_burst = 0, c_inj_to = 0, c_inj_unf = 0, c_inj_sid = 0, c_errlim = 0;
  integer c_dummy = 0;

  always @(posedge r_busy)                     c_start_acc = c_start_acc + 1;
  always @(posedge r_err)                      c_err = c_err + 1;
  always @(posedge r_core_rst)             c_core_rst = c_core_rst + 1;
  always @(posedge clk) if (rst_n === 1'b1) begin
    if (r_scan_done === 1'b1) begin
      c_scan_done = c_scan_done + 1;
      if (continuous) c_cont_scan = c_cont_scan + 1;
    end
    if (r_data_valid === 1'b1) c_dv = c_dv + 1;
    if (r_sdo_valid === 1'b1 && r_sdo_ready === 1'b1 && r_sdo_data === 16'hFFFF)
      c_dummy = c_dummy + 1;                                  // power-up dummy kelimesi core'a verildi
  end
  // ERR_LIMIT (bilgi amaçlı, yaklaşık): sürekli modda bozma burst'ü sırasında err = 1 iken busy düştü
  reg r_busy_d = 1'b0;
  always @(posedge clk) begin
    if (r_busy_d && !r_busy && r_err && rst_n && burst_left > 0 && continuous) c_errlim = c_errlim + 1;
    r_busy_d <= r_busy;
  end

  // ------------------------------------------------------------ rastgele uyarım
  integer seed = SEED;
  integer rnd, rst_left = 0, start_left = 0;
  integer force_to_left = 0, force_sid_left = 0;
  reg     force_unf = 1'b0;

  function integer urnd(input integer n);   // 0..n-1
    begin
      rnd  = $random(seed);
      urnd = ((rnd < 0) ? -rnd : rnd) % n;
    end
  endfunction

  // frame bozma kararı: her referans frame'inin başında (iki taraf aynı anda düşer)
  always @(negedge r_cs_n) begin
    if (burst_left > 0) begin
      burst_left = burst_left - 1;
      corrupt = 2'd1;
    end else if (urnd(1000) < 2) begin
      burst_left = 20; corrupt = 2'd1; c_inj_burst = c_inj_burst + 1;
    end else if (urnd(100) < 2) begin
      corrupt = (urnd(2) == 0) ? 2'd1 : 2'd2; c_inj_frame = c_inj_frame + 1;
    end else
      corrupt = 2'd0;
  end
  always @(posedge r_cs_n) if (burst_left == 0) corrupt = 2'd0;


  initial begin
    $display("=== tb_drv_lockstep: ad7923_top_sref (sync) <-> ad7923_top (async), SEED=%0d CYCLES=%0d MUT=%0d ===",
             SEED, CYCLES, MUT);
    if ($test$plusargs("VCD")) begin $dumpfile("drv_lockstep.vcd"); $dumpvars(0, tb_drv_lockstep); end
    repeat (10) @(posedge clk); #1 rst_n = 1'b1; last_rst_rel_cyc = cyc;

    while (cyc < CYCLES) begin
      @(posedge clk); #1;
      // --- reset
      if (rst_left > 0) begin
        rst_left = rst_left - 1;
        if (rst_left == 0) begin rst_n = 1'b1; last_rst_rel_cyc = cyc; end
      end else if (urnd(40000) == 0) begin
        rst_n = 1'b0; rst_left = 8 + urnd(40); c_rst = c_rst + 1;
        if (r_cs_n === 1'b0) c_rst_frame = c_rst_frame + 1;
      end
      // --- start (1..3 clock seviye)
      if (start_left > 0) begin
        start_left = start_left - 1; if (start_left == 0) start = 1'b0;
      end else if (urnd(3000) == 0) begin
        start = 1'b1; start_left = 1 + urnd(3); c_start_pulse = c_start_pulse + 1;
      end
      // --- stop (1 clock)
      if (stop) stop = 1'b0;
      else if (urnd(15000) == 0) begin stop = 1'b1; c_stop = c_stop + 1; if (r_busy) c_stop_busy = c_stop_busy + 1; end
      // --- continuous
      if (urnd(12000) == 0) begin continuous = ~continuous; c_cont_tog = c_cont_tog + 1; end
      // --- ch_mask
      if (urnd(8000) == 0) begin
        ch_mask = (urnd(10) == 0) ? 4'h0 : urnd(16);
        c_mask = c_mask + 1; if (r_busy) c_mask_busy = c_mask_busy + 1; if (ch_mask == 4'h0) c_mask_zero = c_mask_zero + 1;
      end
      // --- period_us
      if (urnd(20000) == 0) begin
        case (urnd(4))
          0: period_us = 16'd0;
          1: period_us = urnd(40);
          2: period_us = 16'd100;
          default: period_us = urnd(300);
        endcase
        c_period = c_period + 1;
      end
      // --- range / coding
      if (urnd(5000) == 0) begin range_sel = ~range_sel; c_rc = c_rc + 1; end
      if (urnd(5000) == 0) begin coding_sel = ~coding_sel; c_rc = c_rc + 1; end

      // --- yapısal hata enjeksiyonu (iki tarafa aynı)
      if (force_unf) begin rel_unf; force_unf = 1'b0; end
      if (force_to_left > 0) begin
        force_to_left = force_to_left - 1; if (force_to_left == 0) rel_to;
      end else if (force_sid_left > 0) begin
        force_sid_left = force_sid_left - 1;
        if (force_sid_left == 0) rel_sid;
      end else if (r_busy && rst_n) begin
        case (urnd(150000))
          0: begin frc_to; force_to_left = 1100 + urnd(400); c_inj_to = c_inj_to + 1; end
          1: begin frc_unf; force_unf = 1'b1; c_inj_unf = c_inj_unf + 1; end
          2: begin
               case (urnd(4))   // yanlış SYNC id, iki tarafa aynı
                 0: frc_sid(8'h5A);
                 1: frc_sid(8'hA5);
                 2: frc_sid(8'h3C);
                 default: frc_sid(8'hC3);
               endcase
               force_sid_left = 200 + urnd(200); c_inj_sid = c_inj_sid + 1;
             end
          default: ;
        endcase
      end
    end
    if (force_to_left > 0) rel_to;
    if (force_sid_left > 0) rel_sid;
    #20;

    // ------------------------------------------------------------ rapor
    $display("  kapsama: start pulse=%0d (kabul=%0d) stop=%0d (busy iken %0d) continuous degisim=%0d surekli tarama=%0d",
             c_start_pulse, c_start_acc, c_stop, c_stop_busy, c_cont_tog, c_cont_scan);
    $display("           mask degisim=%0d (busy iken %0d, 0000=%0d) period degisim=%0d range/coding degisim=%0d",
             c_mask, c_mask_busy, c_mask_zero, c_period, c_rc);
    $display("           err=%0d core_rst=%0d scan_done=%0d data_valid=%0d dummy(power-up) frame=%0d ERR_LIMIT durus=%0d",
             c_err, c_core_rst, c_scan_done, c_dv, c_dummy, c_errlim);
    $display("           rst_n pulse=%0d (frame icinde %0d) | enjeksiyon: frame=%0d burst=%0d timeout=%0d underflow=%0d sync_id=%0d",
             c_rst, c_rst_frame, c_inj_frame, c_inj_burst, c_inj_to, c_inj_unf, c_inj_sid);
    m_ref.report; m_dut.report;
    $display("  clock=%0d karsilastirilan=%0d atlanan(reset assert -> ilk posedge)=%0d | FARK=%0d (ilk: clock %0d) | async reset kontrol=%0d hata=%0d",
             cyc, n_cmp, n_skip, n_diff, first_diff_cyc, n_async_chk, n_async_bad);
    if (MUT) begin
      $display("  MUTATION: %0s (fark=%0d, ilk fark clock %0d)", (n_diff > 0 || n_async_bad > 0) ? "  YAKALANDI" : "  KACIRILDI",
               n_diff, first_diff_cyc);
    end else begin
      if (n_diff == 0 && n_async_bad == 0 && n_cmp > CYCLES * 9 / 10 &&
          c_start_acc > 0 && c_stop_busy > 0 && c_cont_scan > 0 && c_mask_busy > 0 &&
          c_err > 0 && c_core_rst > 0 && c_scan_done > 0 && c_rst > 0)
        $display("  SONUC: BASARILI");
      else
        $display("  SONUC: BASARISIZ");
    end
    $finish;
  end

endmodule
