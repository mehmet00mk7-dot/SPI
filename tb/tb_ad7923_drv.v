// ============================================================================
// tb_ad7923_drv.v  -  ad7923_top (ad7923_drv + ADI spi_engine_execution) testbench'i
//
// DUT yalnız top-level sinyallerle sürülür (start/stop/continuous/ch_mask/...).
// AD7923 davranışı tb/ad7923_model.v ile (datasheet Rev. D + timing kontrolleri).
//
//   u_adc     : normal model (T_DOUT parametresi, varsayılan 25 ns)
//   u_adc_bad : aynı hatta T_DOUT = 8 ns (< t7) model; kalıcı hata senaryosu için
//               MISO'yu bu model sürer (use_bad = 1). İki model aynı CS/SCLK/DIN'i
//               gördüğü için register durumları hep aynıdır.
//   injector  : tek bir frame'de MISO'ya istenen 16 bitlik kelimeyi model
//               zamanlamasıyla basar (format / adres hatası enjeksiyonu).
//
// İç sinyaller (frame süresi ölçümü, SYNC/sdi force) Icarus'ta hierarchical
// referansla, Questa'da (+define+QUESTA) SignalSpy ile erişilir.
//
// Çalıştırma: sim/run_ad7923_drv.sh (GHDL + Icarus) veya
//             sim/run_questa_ad7923_drv.do (Questa)
// ============================================================================
`timescale 1ns/100ps

module tb_ad7923_drv;

  parameter real T_DOUT     = 25.0;
  localparam real T_DOUT_BAD = 8.0;     // t7 = 10 ns min altında: kalıcı veri hatası
  localparam real MIN_CYC    = 5000.0;  // AD7923: CS falling edge'ler arası >= 5 us
  localparam real T_INJ_EN   = 35.0;    // injector: CS düşen -> ilk bit (model T_EN)
  localparam real T_INJ_DOUT = 25.0;    // injector: SCLK düşen -> sonraki bit

  // ---------------------------------------------------------------- DUT
  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg        rst_n = 1'b0, start = 1'b0, stop = 1'b0, continuous = 1'b0;
  reg        range_sel = 1'b1, coding_sel = 1'b1;
  reg [3:0]  ch_mask   = 4'hF;
  reg [15:0] period_us = 16'd0;
  wire       data_valid, busy, err;
  wire [1:0] data_ch;
  wire [11:0] data;
  wire       spi_sclk, spi_mosi, spi_cs_n, spi_miso;
  wire [11:0] ch0_data, ch1_data, ch2_data, ch3_data;
  wire       ch0_valid, ch1_valid, ch2_valid, ch3_valid, scan_done;

  ad7923_top u_dut (
    .clk(clk), .rst_n(rst_n), .start(start), .stop(stop), .continuous(continuous),
    .ch_mask(ch_mask), .period_us(period_us), .range_sel(range_sel), .coding_sel(coding_sel),
    .data_valid(data_valid), .data_ch(data_ch), .data(data), .busy(busy), .err(err),
    .ch0_data(ch0_data), .ch1_data(ch1_data), .ch2_data(ch2_data), .ch3_data(ch3_data),
    .ch0_valid(ch0_valid), .ch1_valid(ch1_valid), .ch2_valid(ch2_valid), .ch3_valid(ch3_valid),
    .scan_done(scan_done),
    .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n), .spi_miso(spi_miso)
  );

  // ------------------------------------------------- modeller ve MISO mux
  tri1 dout_good, dout_bad;            // DOUT yüksek empedansta 1 okunur (pull-up)
  ad7923_model #(.ID(2'd0), .T_DOUT(T_DOUT))     u_adc     (.cs_n(spi_cs_n), .sclk(spi_sclk), .din(spi_mosi), .dout(dout_good));
  ad7923_model #(.ID(2'd0), .T_DOUT(T_DOUT_BAD)) u_adc_bad (.cs_n(spi_cs_n), .sclk(spi_sclk), .din(spi_mosi), .dout(dout_bad));

  reg        use_bad = 1'b0;
  reg        inj_arm = 1'b0, inj_act = 1'b0, inj_bit = 1'b1;
  reg [15:0] inj_word = 16'hFFFF, inj_sh = 16'hFFFF;
  integer    inj_n = 0;
  always @(negedge spi_cs_n)
    if (inj_arm) begin
      inj_arm = 1'b0; inj_act = 1'b1; inj_sh = inj_word; inj_n = 0;
      inj_bit <= #(T_INJ_EN) inj_word[15];
    end
  always @(negedge spi_sclk)
    if (inj_act && spi_cs_n === 1'b0) begin
      inj_n = inj_n + 1;
      if (inj_n < 16) inj_bit <= #(T_INJ_DOUT) inj_sh[15 - inj_n];
    end
  always @(posedge spi_cs_n) inj_act = 1'b0;

  assign spi_miso = inj_act ? inj_bit : (use_bad ? dout_bad : dout_good);

  // ------------------------------------------------ iç sinyallere erişim
`ifdef QUESTA
  reg        s_cmd_valid = 1'b0, s_cmd_ready = 1'b0, s_sync_valid = 1'b0, s_core_rst = 1'b0;
  reg [15:0] s_cmd = 16'h0;
  reg [7:0]  s_sync = 8'h0;
  initial begin
    $init_signal_spy("/tb_ad7923_drv/u_dut/cmd_valid",  "/tb_ad7923_drv/s_cmd_valid",  0);
    $init_signal_spy("/tb_ad7923_drv/u_dut/cmd_ready",  "/tb_ad7923_drv/s_cmd_ready",  0);
    $init_signal_spy("/tb_ad7923_drv/u_dut/cmd",        "/tb_ad7923_drv/s_cmd",        0);
    $init_signal_spy("/tb_ad7923_drv/u_dut/sync_valid", "/tb_ad7923_drv/s_sync_valid", 0);
    $init_signal_spy("/tb_ad7923_drv/u_dut/sync",       "/tb_ad7923_drv/s_sync",       0);
    $init_signal_spy("/tb_ad7923_drv/u_dut/core_rst",   "/tb_ad7923_drv/s_core_rst",   0);
  end
  task force_sync_valid_low;  $signal_force("/tb_ad7923_drv/u_dut/sync_valid", "0", 0, 3, -1, 0); endtask
  task release_sync_valid;    $signal_release("/tb_ad7923_drv/u_dut/sync_valid", 0);              endtask
  task force_sync_id(input [7:0] v); $signal_force("/tb_ad7923_drv/u_dut/sync", $sformatf("%b", v), 0, 3, -1, 0); endtask
  task release_sync_id;       $signal_release("/tb_ad7923_drv/u_dut/sync", 0);                    endtask
  task force_sdi_valid_high;  $signal_force("/tb_ad7923_drv/u_dut/sdi_valid", "1", 0, 3, -1, 0);  endtask
  task release_sdi_valid;     $signal_release("/tb_ad7923_drv/u_dut/sdi_valid", 0);               endtask
`else
  wire        s_cmd_valid  = u_dut.cmd_valid;
  wire        s_cmd_ready  = u_dut.cmd_ready;
  wire [15:0] s_cmd        = u_dut.cmd;
  wire        s_sync_valid = u_dut.sync_valid;
  wire [7:0]  s_sync       = u_dut.sync;
  wire        s_core_rst   = u_dut.core_rst;
  task force_sync_valid_low;  force u_dut.sync_valid = 1'b0; endtask
  task release_sync_valid;    release u_dut.sync_valid;      endtask
  task force_sync_id(input [7:0] v); force u_dut.sync = v;  endtask
  task release_sync_id;       release u_dut.sync;            endtask
  task force_sdi_valid_high;  force u_dut.sdi_valid = 1'b1;  endtask
  task release_sdi_valid;     release u_dut.sdi_valid;       endtask
`endif

  localparam [15:0] CMD_FIRST = 16'h2002;   // paketin ilk komutu (CONFIG clk_div)

  // ---------------------------------------------------------- monitörler
  // CS falling edge aralığı
  realtime t_csf = -1.0e9, d_cs, min_cs_all = 1.0e9, min_cs_t = 1.0e9, t_first_cs = 0.0;
  integer  n_cs = 0;
  always @(negedge spi_cs_n) begin
    if (n_cs == 0) t_first_cs = $realtime;
    if (t_csf > -1.0e8) begin
      d_cs = $realtime - t_csf;
      if (d_cs < min_cs_all) min_cs_all = d_cs;
      if (d_cs < min_cs_t)   min_cs_t   = d_cs;
    end
    t_csf = $realtime;
    n_cs  = n_cs + 1;
  end

  // MOSI (DIN) kelimeleri: AD7923 DIN'i SCLK düşen kenarında okur
  reg [15:0] mo_sh = 16'h0;
  integer    mo_bits = 0, mo_n = 0;
  reg [15:0] mo_log [0:8191];
  always @(negedge spi_cs_n) mo_bits = 0;
  always @(negedge spi_sclk) if (spi_cs_n === 1'b0) begin mo_sh = {mo_sh[14:0], spi_mosi}; mo_bits = mo_bits + 1; end
  always @(posedge spi_cs_n) if (mo_bits == 16) begin mo_log[mo_n] = mo_sh; mo_n = mo_n + 1; end

  // CS low süresi (tam frame'ler)
  realtime cs_low, cs_low_min = 1.0e9, cs_low_max = 0.0;
  always @(posedge spi_cs_n) if (mo_bits == 16 && t_csf > -1.0e8) begin
    cs_low = $realtime - t_csf;
    if (cs_low < cs_low_min) cs_low_min = cs_low;
    if (cs_low > cs_low_max) cs_low_max = cs_low;
  end

  // Frame süresi: ilk komut handshake'i -> SYNC
  realtime t_launch = -1.0, t_last_launch = 0.0, ft, ft_min = 1.0e9, ft_max = 0.0;
  integer  n_ft = 0;
  reg [7:0] last_sync = 8'h0;
  always @(posedge clk) begin
    if (s_cmd_valid === 1'b1 && s_cmd_ready === 1'b1 && s_cmd == CMD_FIRST) begin
      t_launch = $realtime; t_last_launch = $realtime;
    end
    if (s_sync_valid === 1'b1) begin
      last_sync = s_sync;
      if (t_launch >= 0.0) begin
        ft = $realtime - t_launch;
        if (ft < ft_min) ft_min = ft;
        if (ft > ft_max) ft_max = ft;
        n_ft = n_ft + 1;
        t_launch = -1.0;
      end
    end
  end
  always @(negedge rst_n) t_launch = -1.0;

  // Çıkış verisi + kanal register'ları (ad7923_ch_regs) kontrolü
  //   data_valid (clock C) -> chN_valid / chN_data / scan_done (clock C+1)
  //   * chN_valid yalnız data_ch = N verisinden 1 clk sonra, chN_data = o veri
  //   * chN_valid yokken chN_data değişmez
  //   * scan_done yalnız bir veriden 1 clk sonra (dl_sd ile o veriye işaretlenir)
  reg [1:0]  dl_ch [0:8191];
  reg [11:0] dl_d  [0:8191];
  realtime   dl_t  [0:8191];
  reg        dl_sd [0:8191];
  integer    dl_n = 0, e_content = 0, e_seq = 0;
  reg        chk_en = 1'b1;
  reg [7:0]  last_cnt [0:3];
  reg        have_last [0:3];
  reg [7:0]  dif;

  wire [3:0] chv = {ch3_valid, ch2_valid, ch1_valid, ch0_valid};
  function [11:0] chd(input integer n);
    case (n)
      0:       chd = ch0_data;
      1:       chd = ch1_data;
      2:       chd = ch2_data;
      default: chd = ch3_data;
    endcase
  endfunction

  reg        pend_v = 1'b0;
  reg [1:0]  pend_ch = 2'd0;
  reg [11:0] pend_d = 12'd0;
  integer    pend_i = 0, nn;
  reg [11:0] chd_prev [0:3];
  integer    cv_cnt [0:3];
  integer    e_chv = 0, e_chd = 0, e_chchg = 0, e_sd = 0, n_sd = 0;

  always @(posedge clk) begin
    if (rst_n !== 1'b1) begin
      pend_v = 1'b0;
      for (nn = 0; nn < 4; nn = nn + 1) chd_prev[nn] = chd(nn);
    end else begin
      for (nn = 0; nn < 4; nn = nn + 1) begin
        if (chv[nn] === 1'b1) begin
          cv_cnt[nn] = cv_cnt[nn] + 1;
          if (!pend_v || pend_ch != nn) e_chv = e_chv + 1;
          else if (chd(nn) !== pend_d)  e_chd = e_chd + 1;
        end else if (chd(nn) !== chd_prev[nn]) e_chchg = e_chchg + 1;
        chd_prev[nn] = chd(nn);
      end
      if (pend_v && chv[pend_ch] !== 1'b1) e_chv = e_chv + 1;
      if (scan_done === 1'b1) begin
        n_sd = n_sd + 1;
        if (!pend_v) e_sd = e_sd + 1;
        else dl_sd[pend_i] = 1'b1;
      end
      pend_v = (data_valid === 1'b1);
      if (pend_v) begin
        pend_ch = data_ch; pend_d = data; pend_i = dl_n;
        dl_ch[dl_n] = data_ch; dl_d[dl_n] = data; dl_t[dl_n] = $realtime; dl_sd[dl_n] = 1'b0;
        dl_n = dl_n + 1;
        if (chk_en) begin
          // model veri deseni: DB11..0 = {kanal, ID, counter}
          if (data[11:10] != data_ch || data[9:8] != 2'd0) e_content = e_content + 1;
          else begin
            if (have_last[data_ch]) begin
              dif = data[7:0] - last_cnt[data_ch];
              if (dif < 8'd1 || dif > 8'd3) e_seq = e_seq + 1;   // atılan dönüşümler: fark 1..3
            end
            last_cnt[data_ch] = data[7:0]; have_last[data_ch] = 1'b1;
          end
        end
      end
    end
  end

  // busy / err / core_rst kenarları
  realtime t_busy_fall = 0.0, t_err_rise = 0.0, t_crst_rise = 0.0, t_crst_fall = 0.0;
  integer  n_busy_rise = 0, n_core_rst = 0;
  always @(negedge busy)      t_busy_fall = $realtime;
  always @(posedge busy)      n_busy_rise = n_busy_rise + 1;
  always @(posedge err)       t_err_rise  = $realtime;
  always @(posedge s_core_rst) begin t_crst_rise = $realtime; n_core_rst = n_core_rst + 1; end
  always @(negedge s_core_rst) t_crst_fall = $realtime;

  // ------------------------------------------------------------ yardımcılar
  realtime t_start, t_stop, t_rst_rel, t0, t1;
  integer  k, n_pass = 0, n_fail = 0, ok, ok_m, ok_c, ok_s, w_mo, w_dl, w_cs, w_sd, tgt;
  integer  w_cv [0:3];
  reg        exp_s [0:63];
  reg [15:0] exp_w [0:63]; integer exp_n = 0;
  reg [1:0]  exp_c [0:63]; integer expc_n = 0;
  realtime d_min, d_max, d;

  function [15:0] cw(input [1:0] ch, input r, input c);   // control word: WRITE, PM=11
    cw = 16'h8300 | ({14'd0, ch} << 10) | ({15'd0, r} << 5) | ({15'd0, c} << 4);
  endfunction

  task ew(input [15:0] w); begin exp_w[exp_n] = w; exp_n = exp_n + 1; end endtask
  task ec(input [1:0] c);  begin exp_c[expc_n] = c; expc_n = expc_n + 1; end endtask

  task mark;   // pencere başlangıcı
    begin
      w_mo = mo_n; w_dl = dl_n; w_cs = n_cs; min_cs_t = 1.0e9; exp_n = 0; expc_n = 0;
      w_sd = n_sd; for (k = 0; k < 4; k = k + 1) w_cv[k] = cv_cnt[k];
      for (k = 0; k < 4; k = k + 1) have_last[k] = 1'b0;
    end
  endtask

  task cmp_mosi;  // mo_log[w_mo..] == exp_w[0..exp_n-1]
    begin
      ok_m = (mo_n - w_mo == exp_n);
      for (k = 0; k < exp_n; k = k + 1)
        if (w_mo + k >= mo_n || mo_log[w_mo + k] !== exp_w[k]) ok_m = 0;
      if (!ok_m) begin
        $write("      MOSI beklenen:");
        for (k = 0; k < exp_n; k = k + 1) $write(" %h", exp_w[k]);
        $write("\n      MOSI okunan  :");
        for (k = w_mo; k < mo_n; k = k + 1) $write(" %h", mo_log[k]);
        $write("\n");
      end
    end
  endtask

  task cmp_ch;    // dl_ch[w_dl..] == exp_c[0..expc_n-1]
    begin
      ok_c = (dl_n - w_dl == expc_n);
      for (k = 0; k < expc_n; k = k + 1)
        if (w_dl + k >= dl_n || dl_ch[w_dl + k] !== exp_c[k]) ok_c = 0;
      if (!ok_c) begin
        $write("      kanal beklenen:");
        for (k = 0; k < expc_n; k = k + 1) $write(" %0d", exp_c[k]);
        $write("\n      kanal okunan  :");
        for (k = w_dl; k < dl_n; k = k + 1) $write(" %0d", dl_ch[k]);
        $write("\n");
      end
    end
  endtask

  // pencerede scan_done yalnız 'last' kanalının verisiyle gelir, sayısı = tamamlanan tarama
  task chk_sd_last(input [1:0] last);
    integer nl;
    begin
      ok_s = 1; nl = 0;
      for (k = w_dl; k < dl_n; k = k + 1) begin
        if (dl_sd[k] !== (dl_ch[k] == last)) ok_s = 0;
        if (dl_ch[k] == last) nl = nl + 1;
      end
      if (n_sd - w_sd != nl) ok_s = 0;
      if (!ok_s) $display("      scan_done: beklenen %0d (ch%0d ciktilari), gelen %0d", nl, last, n_sd - w_sd);
    end
  endtask
  // pencerede scan_done deseni == exp_s[0..expc_n-1] (exp_c ile paralel)
  task chk_sd_list;
    integer nl;
    begin
      ok_s = (dl_n - w_dl == expc_n); nl = 0;
      for (k = 0; k < expc_n; k = k + 1) begin
        if (w_dl + k >= dl_n || dl_sd[w_dl + k] !== exp_s[k]) ok_s = 0;
        if (exp_s[k]) nl = nl + 1;
      end
      if (n_sd - w_sd != nl) ok_s = 0;
      if (!ok_s) $display("      scan_done deseni uyusmuyor: beklenen %0d, gelen %0d", nl, n_sd - w_sd);
    end
  endtask
  task show_ch;
    $display("    kanal register'lari: ch0..3_valid %0d/%0d/%0d/%0d | scan_done %0d",
             cv_cnt[0] - w_cv[0], cv_cnt[1] - w_cv[1], cv_cnt[2] - w_cv[2], cv_cnt[3] - w_cv[3], n_sd - w_sd);
  endtask
  function regs_zero(input dummy);
    regs_zero = (ch0_data === 12'd0) && (ch1_data === 12'd0) && (ch2_data === 12'd0) && (ch3_data === 12'd0);
  endfunction

  task result(input integer pass, input [8*64:1] name);
    begin
      if (pass) n_pass = n_pass + 1; else n_fail = n_fail + 1;
      $display("  %0s  %0s", pass ? "GECTI" : "KALDI", name);
    end
  endtask

  task pulse_start;
    begin @(posedge clk); #1 start = 1'b1; @(posedge clk); t_start = $realtime; #1 start = 1'b0; end
  endtask
  task pulse_stop;
    begin @(posedge clk); #1 stop = 1'b1; @(posedge clk); t_stop = $realtime; #1 stop = 1'b0; end
  endtask
  task wait_idle(input real max_ns);
    begin t0 = $realtime; @(posedge clk); while (busy !== 1'b0 && $realtime - t0 < max_ns) @(posedge clk); end
  endtask
  task wait_dv_ch(input [1:0] ch);
    begin @(posedge clk); while (!(data_valid === 1'b1 && data_ch == ch)) @(posedge clk); end
  endtask
  task wait_out(input integer n);     // pencere başından n çıkış
    begin while (dl_n < w_dl + n) @(posedge clk); end
  endtask
  task wait_more(input integer n);    // şu andan itibaren n çıkış
    begin tgt = dl_n + n; while (dl_n < tgt) @(posedge clk); end
  endtask
  task after_frame;                   // data_valid'den sonra SYNC dönmüş olsun, sonraki launch'tan önce
    #800;
  endtask
  task stop_in_gap;                   // bir frame bitince, bekleme sırasında stop
    begin wait_more(1); after_frame; pulse_stop; wait_idle(20000.0); end
  endtask

  // ch0 çıkış zaman damgaları arası (ilk aralık hariç: ilk taramada select olabilir)
  task scan_spacing(input integer from);
    realtime tp; integer first, n0;
    begin
      d_min = 1.0e9; d_max = 0.0; first = 1; n0 = 0;
      for (k = from; k < dl_n; k = k + 1)
        if (dl_ch[k] == 2'd0) begin
          if (n0 >= 2) begin d = dl_t[k] - tp; if (d < d_min) d_min = d; if (d > d_max) d_max = d; end
          tp = dl_t[k]; n0 = n0 + 1;
        end
    end
  endtask

  // ------------------------------------------------------------- testler
  integer  cs_a, dl_a, i, errs_before, crst_before, ab_before;
  realtime t_ab_csf, t_ab_rst, t_cs_rel, t_inj_csf, lat;
  reg      busy_snap, err_snap, rz0, rz18;
  reg [11:0] d1_snap, d3_snap;
  integer  n0, n2, i0, i2;

  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("ad7923_drv.vcd");
      $dumpvars(0, tb_ad7923_drv);
    end
    for (k = 0; k < 4; k = k + 1) begin have_last[k] = 1'b0; cv_cnt[k] = 0; end
    $display("=== tb_ad7923_drv: ad7923_top (driver + ADI spi_engine_execution), T_DOUT=%0.1f ns ===", T_DOUT);
    repeat (10) @(posedge clk); #1 rst_n = 1'b1; t_rst_rel = $realtime; repeat (5) @(posedge clk);
    rz0 = regs_zero(0);

    // ===================================================================== T01
    $display("\n--- T01 power-up + tek tarama (mask 1111, continuous=0)");
    mark; ch_mask = 4'hF; continuous = 1'b0; period_us = 16'd0;
    pulse_start; wait_idle(200000.0);
    ew(16'hFFFF); ew(cw(0,1,1)); ew(cw(1,1,1)); ew(cw(2,1,1)); ew(cw(3,1,1)); ew(cw(0,1,1));
    ec(0); ec(1); ec(2); ec(3);
    cmp_mosi; cmp_ch;
    $display("    reset -> ilk CS: %0.2f us | start -> ilk data_valid: %0.2f us | start -> busy dusus: %0.2f us | frame: %0d, cikis: %0d",
             (t_first_cs - t_rst_rel) / 1000.0, (dl_t[w_dl] - t_start) / 1000.0,
             (t_busy_fall - t_start) / 1000.0, n_cs - w_cs, dl_n - w_dl);
    chk_sd_last(3); show_ch;
    $display("    reset sonrasi chN_data = 0: %0s", rz0 ? "evet" : "HAYIR");
    result(ok_m && ok_c && ok_s && rz0 && err === 1'b0 && busy === 1'b0 && n_cs - w_cs == 6, "T01 power-up (dummy + select) + 4 kanal");

    // ===================================================================== T02
    $display("\n--- T02 tek tarama, entegre hazir (select gerekmez)");
    repeat (600) @(posedge clk);
    mark; pulse_start; wait_idle(200000.0);
    ew(cw(1,1,1)); ew(cw(2,1,1)); ew(cw(3,1,1)); ew(cw(0,1,1));
    ec(0); ec(1); ec(2); ec(3);
    cmp_mosi; cmp_ch;
    $display("    start -> busy dusus: %0.2f us | frame: %0d | min CS araligi: %0.2f us",
             (t_busy_fall - t_start) / 1000.0, n_cs - w_cs, min_cs_t / 1000.0);
    chk_sd_last(3); show_ch;
    result(ok_m && ok_c && ok_s && err === 1'b0 && n_cs - w_cs == 4 && min_cs_t >= MIN_CYC, "T02 tek tarama, 4 frame");

    // ===================================================================== T03
    $display("\n--- T03 tek kanal (mask 0100), entegre ch0'da -> kanal secme frame'i");
    ch_mask = 4'b0100;
    mark; pulse_start; wait_idle(200000.0);
    ew(cw(2,1,1)); ew(cw(2,1,1)); ec(2);
    cmp_mosi; cmp_ch; chk_sd_last(2); ok = ok_m && ok_c && ok_s && n_cs - w_cs == 2;
    $display("    1. start: frame %0d (select + olcum), cikis %0d (ch%0d)", n_cs - w_cs, dl_n - w_dl, dl_ch[w_dl]);
    mark; pulse_start; wait_idle(200000.0);
    ew(cw(2,1,1)); ec(2);
    cmp_mosi; cmp_ch; chk_sd_last(2); ok = ok && ok_m && ok_c && ok_s && n_cs - w_cs == 1;
    $display("    2. start: frame %0d (select yok), cikis %0d (ch%0d)", n_cs - w_cs, dl_n - w_dl, dl_ch[w_dl]);
    result(ok && err === 1'b0, "T03 select frame sonucu basilmiyor");

    // ===================================================================== T04
    $display("\n--- T04 surekli mod, period 0, mask 1111 + STOP");
    ch_mask = 4'hF; continuous = 1'b1; period_us = 16'd0;
    mark; pulse_start; wait_out(20);
    for (i = 0; i < 20; i = i + 1) ec(i % 4);
    scan_spacing(w_dl); cmp_ch; ok = ok_c;
    $display("    20 cikis: kanal sirasi %0s | tarama araligi min %0.2f / maks %0.2f us | min CS araligi %0.2f us",
             ok_c ? "dogru" : "YANLIS", d_min / 1000.0, d_max / 1000.0, min_cs_t / 1000.0);
    ok = ok && d_min == 20000.0 && d_max == 20000.0 && min_cs_t >= MIN_CYC;
    // STOP frame içindeyken
    @(negedge spi_cs_n); #200; cs_a = n_cs; dl_a = dl_n;
    pulse_stop; wait_idle(20000.0); lat = t_busy_fall - t_stop;
    $display("    STOP (frame icinde): stop -> busy dusus %0.0f ns | o frame'in verisi basildi: %0d | yeni frame: %0d",
             lat, dl_n - dl_a, n_cs - cs_a);
    ok = ok && dl_n - dl_a == 1 && n_cs == cs_a && lat <= 1320.0 && busy === 1'b0;
    // STOP beklemedeyken
    pulse_start; wait_more(6); wait_more(1); after_frame; cs_a = n_cs; dl_a = dl_n;
    pulse_stop; wait_idle(20000.0); lat = t_busy_fall - t_stop;
    repeat (600) @(posedge clk);
    $display("    STOP (bekleme): stop -> busy dusus %0.0f ns | yeni frame: %0d, yeni cikis: %0d", lat, n_cs - cs_a, dl_n - dl_a);
    ok = ok && n_cs == cs_a && dl_n == dl_a && lat <= 30.0;
    chk_sd_last(3); show_ch;
    result(ok && ok_s && err === 1'b0, "T04 surekli + STOP (<= 1 frame)");

    // ===================================================================== T05
    $display("\n--- T05 surekli mod, period 100 us");
    period_us = 16'd100;
    mark; pulse_start;
    i = 0;
    while (i < 7) begin
      @(posedge clk);
      i = 0; for (k = w_dl; k < dl_n; k = k + 1) if (dl_ch[k] == 2'd0) i = i + 1;
    end
    stop_in_gap; scan_spacing(w_dl);
    $display("    tarama araligi (ch0 -> ch0, 5 aralik): min %0.3f / maks %0.3f us", d_min / 1000.0, d_max / 1000.0);
    chk_sd_last(3); show_ch;
    result(d_min == 100000.0 && d_max == 100000.0 && ok_s && err === 1'b0, "T05 period 100 us");

    // ===================================================================== T06
    $display("\n--- T06 surekli mod, period 10 us (< tarama suresi 20 us)");
    period_us = 16'd10;
    mark; pulse_start; wait_out(40); stop_in_gap; scan_spacing(w_dl);
    $display("    tarama araligi (8 aralik): min %0.3f / maks %0.3f us -> tarama kesilmiyor, is birikmiyor",
             d_min / 1000.0, d_max / 1000.0);
    chk_sd_last(3); show_ch;
    result(d_min == 20000.0 && d_max == 20000.0 && ok_s && err === 1'b0, "T06 period < tarama suresi");

    // ===================================================================== T07
    $display("\n--- T07 calisirken mask degisimi 1111 -> 0101 -> 0100");
    period_us = 16'd0; ch_mask = 4'hF;
    mark; pulse_start; wait_out(8);
    wait_dv_ch(1); #300; mark; ch_mask = 4'b0101;
    wait_out(6); wait_dv_ch(0); #300; ch_mask = 4'b0100;
    wait_out(12); after_frame; pulse_stop; wait_idle(20000.0);
    ec(2); ec(3); ec(0); ec(2); ec(0); ec(2); ec(0); ec(2); ec(2); ec(2); ec(2); ec(2);
    // scan_done: 1111 taramasının sonu (ch3), 0101 taramalarının sonu (ch2), 0100'de her ch2
    exp_s[0] = 0; exp_s[1] = 1; exp_s[2] = 0; exp_s[3] = 1; exp_s[4] = 0; exp_s[5] = 1;
    exp_s[6] = 0; exp_s[7] = 1; exp_s[8] = 1; exp_s[9] = 1; exp_s[10] = 1; exp_s[11] = 1;
    ew(cw(3,1,1)); ew(cw(0,1,1));                                   // 1111 taramasının kalanı
    ew(cw(2,1,1)); ew(cw(0,1,1)); ew(cw(2,1,1)); ew(cw(0,1,1));     // 0101 taramaları
    ew(cw(2,1,1)); ew(cw(0,1,1));
    ew(cw(2,1,1));                                                  // select (ch0 cevrilir, atilir)
    ew(cw(2,1,1)); ew(cw(2,1,1)); ew(cw(2,1,1)); ew(cw(2,1,1));     // 0100 taramaları
    cmp_ch; cmp_mosi;
    $display("    pencere: frame %0d, cikis %0d (fark = %0d select frame) | kanal sirasi %0s",
             n_cs - w_cs, dl_n - w_dl, (n_cs - w_cs) - (dl_n - w_dl), ok_c ? "dogru" : "YANLIS");
    chk_sd_list; show_ch;
    $display("    scan_done deseni (1111 sonu, 0101 x3, 0100 x4): %0s", ok_s ? "dogru" : "YANLIS");
    result(ok_c && ok_m && ok_s && (n_cs - w_cs) - (dl_n - w_dl) == 1 && err === 1'b0, "T07 mask sinirda uygulanir, select 1 kez");

    // ===================================================================== T08
    $display("\n--- T08 surekli modda mask -> 0000");
    ch_mask = 4'hF; repeat (600) @(posedge clk);
    mark; pulse_start; wait_out(6); wait_dv_ch(1); #300; mark; ch_mask = 4'b0000;
    wait_idle(50000.0); repeat (600) @(posedge clk);
    ec(2); ec(3); cmp_ch;
    $display("    degisimden sonra cikis: %0d, frame: %0d | son cikis -> busy dusus: %0.0f ns",
             dl_n - w_dl, n_cs - w_cs, t_busy_fall - dl_t[dl_n - 1]);
    chk_sd_last(3); show_ch;
    result(ok_c && ok_s && n_cs - w_cs == 2 && busy === 1'b0, "T08 mask 0000 -> tarama bitince durur");
    ch_mask = 4'hF;

    // ===================================================================== T09
    $display("\n--- T09 continuous 1 -> 0 calisirken");
    continuous = 1'b1;
    mark; pulse_start; wait_out(6); wait_dv_ch(1); #300; mark; continuous = 1'b0;
    wait_idle(50000.0); repeat (600) @(posedge clk);
    ec(2); ec(3); cmp_ch;
    $display("    degisimden sonra cikis: %0d, frame: %0d (fazladan tarama yok)", dl_n - w_dl, n_cs - w_cs);
    chk_sd_last(3); show_ch;
    result(ok_c && ok_s && n_cs - w_cs == 2 && busy === 1'b0, "T09 calisan tarama biter, durur");

    // ===================================================================== T10
    $display("\n--- T10 busy iken start ve mask 0000 ile start yok sayilir");
    continuous = 1'b1;
    mark; pulse_start; wait_out(4);
    i = n_busy_rise;
    @(negedge spi_cs_n); #300; pulse_start;           // frame içinde
    wait_more(1); after_frame; pulse_start;           // beklemede
    wait_more(1); #2000; pulse_start;
    wait_out(16); stop_in_gap;
    for (k = 0; k < dl_n - w_dl; k = k + 1) ec(k % 4);
    cmp_ch; ok = ok_c;
    for (k = w_mo; k < mo_n; k = k + 1) if (mo_log[k] == 16'hFFFF) ok = 0;
    $display("    busy iken 3 start: kanal sirasi %0s, dummy frame yok, min CS araligi %0.2f us",
             ok_c ? "kesintisiz" : "BOZULDU", min_cs_t / 1000.0);
    ch_mask = 4'b0000; cs_a = n_cs; i = n_busy_rise;
    pulse_start; repeat (300) @(posedge clk);
    $display("    mask 0000 ile start: busy yukselme %0d, frame %0d", n_busy_rise - i, n_cs - cs_a);
    ok = ok && n_busy_rise == i && n_cs == cs_a && min_cs_t >= MIN_CYC;
    ch_mask = 4'hF;
    chk_sd_last(3);
    result(ok && ok_s, "T10 start yok sayma");

    // ===================================================================== T11
    $display("\n--- T11 range_sel / coding_sel degisimi");
    continuous = 1'b1;
    mark; pulse_start; wait_out(6); wait_dv_ch(1); #300; mark; range_sel = 1'b0; coding_sel = 1'b0;
    wait_out(6); after_frame; pulse_stop; wait_idle(20000.0);
    ew(cw(3,0,0)); ew(cw(0,0,0)); ew(cw(1,0,0)); ew(cw(2,0,0)); ew(cw(3,0,0)); ew(cw(0,0,0));
    cmp_mosi;
    $display("    degisimden sonraki ilk control word: %h | model RANGE=%0d CODING=%0d",
             mo_log[w_mo], u_adc.rng, u_adc.cod);
    chk_sd_last(3);
    result(ok_m && ok_s && u_adc.rng == 1'b0 && u_adc.cod == 1'b0, "T11 sonraki frame'de gecerli");
    range_sel = 1'b1; coding_sel = 1'b1;

    // ===================================================================== T12
    $display("\n--- T12 tek frame format hatasi (MISO = 1, ch2 frame'i)");
    continuous = 1'b1; ch_mask = 4'hF;
    pulse_start; ok = (err === 1'b0);
    wait_more(6); wait_dv_ch(1); #300; mark; inj_word = 16'hFFFF; inj_arm = 1'b1;
    @(negedge spi_cs_n); t_inj_csf = $realtime;
    wait_out(4); busy_snap = busy; err_snap = err;
    after_frame; pulse_stop; wait_idle(20000.0);
    ec(0); ec(1); ec(2); ec(3); cmp_ch;
    ew(cw(3,1,1)); ew(cw(0,1,1)); ew(cw(1,1,1)); ew(cw(2,1,1)); ew(cw(3,1,1)); ew(cw(0,1,1));
    cmp_mosi;
    $display("    err=%0d (sticky), busy=%0d (devam) | hatali frame -> sonraki ilk cikis (ch%0d): %0.2f us | frame %0d, cikis %0d",
             err_snap, busy_snap, dl_ch[w_dl], (dl_t[w_dl] - t_inj_csf) / 1000.0, n_cs - w_cs, dl_n - w_dl);
    chk_sd_last(3); show_ch;
    $display("    kesilen taramada scan_done yok, hizalanan taramada 1: %0s", ok_s ? "dogru" : "YANLIS");
    result(ok && ok_c && ok_m && ok_s && err_snap === 1'b1 && busy_snap === 1'b1 && n_cs - w_cs == 6,
           "T12 veri basilmaz, select ile hizalanip devam");

    // ===================================================================== T13
    $display("\n--- T13 tek frame adres hatasi (ch2 beklenirken adres 3)");
    pulse_start; ok = (err === 1'b0);
    $display("    yeni start sonrasi err=%0d (temizlendi)", err);
    wait_more(6); wait_dv_ch(1); #300; mark; inj_word = 16'h3000; inj_arm = 1'b1;
    wait_out(4); busy_snap = busy; err_snap = err;
    after_frame; pulse_stop; wait_idle(20000.0);
    ec(0); ec(1); ec(2); ec(3); cmp_ch;
    $display("    err=%0d, busy=%0d | frame %0d, cikis %0d, kanal sirasi %0s",
             err_snap, busy_snap, n_cs - w_cs, dl_n - w_dl, ok_c ? "dogru" : "YANLIS");
    chk_sd_last(3); show_ch;
    result(ok && ok_c && ok_s && err_snap === 1'b1 && busy_snap === 1'b1 && n_cs - w_cs == 6, "T13 adres hatasi");

    // ===================================================================== T14
    $display("\n--- T14 kalici hata (T_DOUT = 8 ns < t7) -> %0d hatali tarama sonra durur", 4);
    use_bad = 1'b1; chk_en = 1'b0; continuous = 1'b1; ch_mask = 4'hF;
    mark; pulse_start; wait_idle(400000.0);
    ok = (busy === 1'b0) && (err === 1'b1);
    i = 0; for (k = w_dl; k < dl_n; k = k + 1) if (dl_ch[k] == 2'd0) i = i + 1;
    $display("    driver kendiliginden durdu: busy=%0d err=%0d | start -> busy dusus %0.2f us | frame %0d | basilan cikis %0d (hepsi ch0: %0d)",
             busy, err, (t_busy_fall - t_start) / 1000.0, n_cs - w_cs, dl_n - w_dl, i);
    chk_sd_last(3); show_ch;
    $display("    hatali taramalarda scan_done: %0d (beklenen 0)", n_sd - w_sd);
    ok = ok && (dl_n - w_dl == 4) && (i == 4) && ok_s && (n_sd == w_sd);
    use_bad = 1'b0; chk_en = 1'b1; repeat (600) @(posedge clk);
    continuous = 1'b0; mark; pulse_start; wait_idle(200000.0);
    ew(16'hFFFF); ew(cw(0,1,1)); ew(cw(1,1,1)); ew(cw(2,1,1)); ew(cw(3,1,1)); ew(cw(0,1,1));
    ec(0); ec(1); ec(2); ec(3); cmp_mosi; cmp_ch;
    $display("    sonraki start: power-up yeniden (ilk kelime %h), cikis %0d, err=%0d", mo_log[w_mo], dl_n - w_dl, err);
    chk_sd_last(3);
    result(ok && ok_m && ok_c && ok_s && err === 1'b0, "T14 ERR_LIMIT=4 hatali tarama -> durur");

    // ===================================================================== T15
    $display("\n--- T15 SYNC timeout (sync_valid force 0)");
    continuous = 1'b1; crst_before = n_core_rst;
    pulse_start; wait_more(6); wait_more(1); after_frame; force_sync_valid_low;
    wait_idle(50000.0); release_sync_valid;
    $display("    launch -> core_rst: %0.2f us | core_rst genisligi: %0.0f ns | core_rst -> busy dusus: %0.0f ns | CS=%0d err=%0d",
             (t_crst_rise - t_last_launch) / 1000.0, t_crst_fall - t_crst_rise, t_busy_fall - t_crst_rise, spi_cs_n, err);
    ok = n_core_rst == crst_before + 1 && (t_crst_fall - t_crst_rise) == 40.0 && spi_cs_n === 1'b1 &&
         err === 1'b1 && busy === 1'b0 && (t_crst_rise - t_last_launch) >= 10000.0 && (t_crst_rise - t_last_launch) <= 10020.0;
    repeat (600) @(posedge clk);
    continuous = 1'b0; mark; pulse_start; wait_idle(200000.0);
    ew(16'hFFFF); ew(cw(0,1,1)); ew(cw(1,1,1)); ew(cw(2,1,1)); ew(cw(3,1,1)); ew(cw(0,1,1));
    ec(0); ec(1); ec(2); ec(3); cmp_mosi; cmp_ch;
    $display("    sonraki start: power-up yeniden, cikis %0d, err=%0d", dl_n - w_dl, err);
    chk_sd_last(3);
    result(ok && ok_m && ok_c && ok_s && err === 1'b0, "T15 timeout -> core_rst, durur");

    // ===================================================================== T16
    $display("\n--- T16 SYNC id hatasi (sync force)");
    continuous = 1'b1; crst_before = n_core_rst;
    pulse_start; wait_more(6); wait_more(1); after_frame; force_sync_id(last_sync + 8'd7);
    wait_idle(50000.0); release_sync_id;
    $display("    launch -> busy dusus: %0.2f us | err=%0d | core_rst pulse: %0d", (t_busy_fall - t_last_launch) / 1000.0,
             err, n_core_rst - crst_before);
    ok = err === 1'b1 && busy === 1'b0 && n_core_rst == crst_before && (t_busy_fall - t_last_launch) <= 1400.0;
    repeat (600) @(posedge clk);
    continuous = 1'b0; mark; pulse_start; wait_idle(200000.0);
    ok = ok && mo_log[w_mo] == 16'hFFFF && dl_n - w_dl == 4 && err === 1'b0;
    chk_sd_last(3);
    result(ok && ok_s, "T16 SYNC id hatasi -> durur, power-up yeniden");

    // ===================================================================== T17
    $display("\n--- T17 expectation FIFO underflow (beklenmeyen sdi_valid)");
    continuous = 1'b1; crst_before = n_core_rst;
    pulse_start; wait_more(6); wait_more(1); after_frame;
    @(posedge clk); #1 force_sdi_valid_high; t0 = $realtime; @(posedge clk); t1 = $realtime; #1 release_sdi_valid;
    wait_idle(50000.0);
    $display("    sdi_valid -> busy dusus: %0.0f ns | err=%0d | core_rst pulse: %0d", t_busy_fall - t1, err, n_core_rst - crst_before);
    ok = err === 1'b1 && busy === 1'b0 && n_core_rst == crst_before && (t_busy_fall - t1) <= 20.0;
    repeat (600) @(posedge clk);
    continuous = 1'b0; mark; pulse_start; wait_idle(200000.0);
    ok = ok && mo_log[w_mo] == 16'hFFFF && dl_n - w_dl == 4 && err === 1'b0;
    chk_sd_last(3);
    result(ok && ok_s, "T17 FIFO underflow -> durur, power-up yeniden");

    // ===================================================================== T18
    $display("\n--- T18 frame ortasinda rst_n (acil durdurma)");
    continuous = 1'b1; ab_before = u_adc.aborted;
    pulse_start; wait_more(6);
    @(negedge spi_cs_n); t_ab_csf = $realtime; #600;
    rst_n = 1'b0; t_ab_rst = $realtime;
    while (spi_cs_n !== 1'b1) #1;
    t_cs_rel = $realtime;
    repeat (4) @(posedge clk); #1 rst_n = 1'b1;
    rz18 = regs_zero(0);
    continuous = 1'b0; mark; pulse_start; wait_idle(200000.0);
    ew(16'hFFFF); ew(cw(0,1,1)); ew(cw(1,1,1)); ew(cw(2,1,1)); ew(cw(3,1,1)); ew(cw(0,1,1));
    ec(0); ec(1); ec(2); ec(3); cmp_mosi; cmp_ch;
    $display("    rst_n -> CS pasif: %0.0f ns | iptal edilen frame CS -> sonraki CS: %0.2f us | model iptal: %0d | sonra power-up + 4 cikis: %0s",
             t_cs_rel - t_ab_rst, min_cs_t / 1000.0, u_adc.aborted - ab_before, (ok_m && ok_c) ? "dogru" : "YANLIS");
    chk_sd_last(3); show_ch;
    $display("    rst_n sonrasi chN_data = 0: %0s", rz18 ? "evet" : "HAYIR");
    result(ok_m && ok_c && ok_s && rz18 && (t_cs_rel - t_ab_rst) <= 10.0 && u_adc.aborted == ab_before + 1 &&
           min_cs_t >= MIN_CYC && err === 1'b0, "T18 rst_n abort + yeniden power-up");

    // ===================================================================== T19
    $display("\n--- T19 mask 0101: yalniz ch0 / ch2 register'lari guncellenir");
    ch_mask = 4'b0101; continuous = 1'b1; period_us = 16'd0;
    d1_snap = ch1_data; d3_snap = ch3_data;
    mark; pulse_start; wait_out(10); stop_in_gap;
    n0 = 0; n2 = 0; i0 = -1; i2 = -1;
    for (k = w_dl; k < dl_n; k = k + 1) begin
      if (dl_ch[k] == 2'd0) begin n0 = n0 + 1; i0 = k; end
      if (dl_ch[k] == 2'd2) begin n2 = n2 + 1; i2 = k; end
    end
    for (k = 0; k < dl_n - w_dl; k = k + 1) ec((k % 2 == 0) ? 2'd0 : 2'd2);
    cmp_ch; chk_sd_last(2); show_ch;
    $display("    ch1_data %h -> %h, ch3_data %h -> %h (degismemeli) | ch0_data = son ch0 verisi: %0s, ch2_data = son ch2 verisi: %0s",
             d1_snap, ch1_data, d3_snap, ch3_data, (ch0_data === dl_d[i0]) ? "evet" : "HAYIR",
             (ch2_data === dl_d[i2]) ? "evet" : "HAYIR");
    result(ok_c && ok_s && cv_cnt[1] == w_cv[1] && cv_cnt[3] == w_cv[3] &&
           cv_cnt[0] - w_cv[0] == n0 && cv_cnt[2] - w_cv[2] == n2 && n0 > 0 && n2 > 0 &&
           ch1_data === d1_snap && ch3_data === d3_snap && d1_snap !== 12'd0 && d3_snap !== 12'd0 &&
           ch0_data === dl_d[i0] && ch2_data === dl_d[i2] && err === 1'b0, "T19 mask 0101 -> yalniz ch0/ch2, scan_done ch2'de");
    ch_mask = 4'hF;

    // ================================================================ özet
    $display("\n--- Genel olcumler");
    $display("    Frame suresi (ilk komut handshake -> sync_valid): min %0.0f ns, maks %0.0f ns (%0d frame)", ft_min, ft_max, n_ft);
    $display("      (tb_ad7923 referans olcumu komut kuyruga yazilinca baslar, tb SYNC'i gorunce biter: +20 ns -> %0.0f ns)", ft_max + 20.0);
    $display("    CS low suresi: min %0.0f ns, maks %0.0f ns", cs_low_min, cs_low_max);
    $display("    En kisa CS falling edge araligi (tum simulasyon): %0.2f us", min_cs_all / 1000.0);
    $display("    Veri icerik hatasi: %0d | sira hatasi: %0d | toplam cikis: %0d | toplam frame: %0d", e_content, e_seq, dl_n, n_cs);
    $display("    Kanal register'lari: chN_valid toplam %0d/%0d/%0d/%0d | scan_done %0d", cv_cnt[0], cv_cnt[1], cv_cnt[2], cv_cnt[3], n_sd);
    $display("      chN_valid kanal/zaman hatasi: %0d | chN_data != data: %0d | valid'siz degisim: %0d | verisiz scan_done: %0d",
             e_chv, e_chd, e_chchg, e_sd);
    $display("\n--- AD7923 timing kontrolleri (model)");
    u_adc.report; u_adc_bad.report;
    $display("    Olculen: tSCLK min %0.0f ns | t2 min %0.0f ns | t11 min %0.0f ns | tQUIET min %0.0f ns",
             u_adc.min_tsclk, u_adc.min_t2, u_adc.min_t11, u_adc.min_quiet);
    i = u_adc.violations(0) + u_adc_bad.violations(0);
    if (i != 0 || min_cs_all < MIN_CYC || e_content != 0 || e_seq != 0 || ft_max > 1330.0 || ft_min < 1290.0 ||
        e_chv != 0 || e_chd != 0 || e_chchg != 0 || e_sd != 0 || cv_cnt[0] + cv_cnt[1] + cv_cnt[2] + cv_cnt[3] != dl_n)
      n_fail = n_fail + 1;
    $display("\nTOPLAM: %0d test gecti, %0d kaldi | timing ihlali=%0d  ->  SONUC: %0s",
             n_pass, n_fail, i, (n_fail == 0) ? "BASARILI" : "BASARISIZ");
    $finish;
  end

  initial begin #20_000_000; $display("ZAMAN ASIMI"); $finish; end

endmodule
