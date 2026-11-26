// ============================================================================
// tb_hi8436_drv.v  -  hi8436_top (driver + spi_exec) + HI-8436 modeli: senaryo testleri
//
// Testler (HI8436/docs/ANALIZ.md F.2 + byte sırası):
//   T01 reset sonrası çıkışlar, start'sız SPI trafiği yok    T13 self-test (IDLE'dan, çalışırken,
//   T02 init: nMR, 5 yazma + 5 geri okuma, register'lar           DS-9, hata, stop ertelenir)
//   T03 tek okuma                                           T14 VERIFY_EVERY + POR glitch'i
//   T04 polarite (karışık bank modu), sense_act             T15 SYNC timeout -> core_rst
//   T05 hysteresis (band'de önceki durum)                   T16 yanlış SYNC id
//   T06 sürekli + period_us (tam aralık), period 0/küçük    T17 beklenmeyen / eksik sdi kelimesi
//   T07 sense değişimi, sense_chg, gecikme                  T18 settle (yazma -> F8 >= 2 us)
//   T08 çalışırken ayar değişikliği uygulanmaz              T19 gnt = 0 iken paket yok, req
//   T09 stop (boşlukta, paket uçarken, init sırasında)      T20 reset frame ortasında (SCK aktif)
//   T10 busy iken start yok sayılır                         T21 reset clock dururken
//   T11 geri okuma hatası, retry, ERR_LIMIT                 T22 1 clock'luk reset
//   T12 CFG_RANGE (geçersiz eşik reddi, kullanılmayan mod)  T23 0xF8 byte sırası (0x12345678)
//   Init politikası (INIT_EVERY_START = false): T24 arka arkaya tek okumalar (nMR / yazma yok,
//   hysteresis korunur), T25 alan alan ayar değişimi (yalnız değişen register), T26 yapısal
//   hatalardan sonra tam init, T27 self-test hatasından sonra tam init. IES = 1 köşesinde
//   T24/T25 eski davranışı (her start'ta nMR + tam init) doğrular.
//   Varsayılan köşede (IES = 0) tam init gerektiren testler (T09c, T11) öncesinde boşta bir
//   rst_n pulse'ı verilir (force_full_init: "rst_n sonrası ilk start = tam init" kuralı).
//
// Genel kontroller (her clock): sense_valid 1 clk; her sense_valid'de sense = modelin
// gönderdiği son test-dışı F8 kelimesi, sense_chg = sense xor önceki, sense_act = sense xor
// bank modu; cfg_done = 0 iken sense_valid yok; CS low iken req = 1; err = 0 iken err_code = 0.
// Model timing ihlali toplamı 0 olmalı; iptal edilen çerçeve yalnız T20-T22'de (reset).
//
// İç sinyallere (force / izleme) Icarus'ta hierarchical referansla, Questa'da
// (+define+QUESTA) SignalSpy ile erişilir. T14 ikinci bir DUT (VERIFY_EVERY = 8) kullanır:
// Icarus'ta netlist modülü hi8436_top_v, Questa'da hi8436_top #(.VERIFY_EVERY(8)).
// ============================================================================
`timescale 1ns/100ps

module tb_hi8436_drv;
  parameter real    T_SO         = 15.0;   // model: SCK düşen -> SO (timing köşesi)
  parameter integer DW           = 8;      // core DATA_WIDTH (netlist bu değerle üretilir)
  parameter integer UNUSED_STORE = 0;      // model: kullanılmayan register bitleri saklanır mı
  parameter integer HAS_MR       = 1;      // DUT HAS_MR generic'i (netlist bu değerle üretilir)
  parameter integer IES          = 0;      // DUT INIT_EVERY_START generic'i (1 = eski davranış)

  // ---------------------------------------------------------------- clock / reset
  reg clk = 1'b0;
  reg clk_en = 1'b1;
  always #5 if (clk_en) clk = ~clk;
  reg rst_n = 1'b0;

  // ---------------------------------------------------------------- DUT girişleri
  reg        start = 0, stop = 0, continuous = 0, st_req = 0;
  reg [15:0] period_us = 16'd0;
  reg [3:0]  bank_mode = 4'b0000;
  reg [5:0]  go_c = 6'd9, go_h = 6'd5, so_c = 6'd35, so_h = 6'd15;
  reg [63:0] lvl = {32{2'b11}};

  wire [31:0] sense, sense_chg, sense_act;
  wire        sense_valid, cfg_done, busy, err, st_done, st_fail;
  wire [3:0]  err_code;
  wire        spi_sclk, spi_mosi, spi_cs_n, spi_miso, spi_mr_n;

`ifdef QUESTA
  hi8436_top #(.DATA_WIDTH(DW), .HAS_MR(HAS_MR != 0), .INIT_EVERY_START(IES != 0)) u_dut (
`else
  hi8436_top u_dut (
`endif
    .clk(clk), .rst_n(rst_n), .start(start), .stop(stop), .continuous(continuous),
    .period_us(period_us), .bank_mode(bank_mode), .go_center(go_c), .go_hyst(go_h),
    .so_center(so_c), .so_hyst(so_h), .self_test_req(st_req),
    .sense(sense), .sense_valid(sense_valid), .sense_chg(sense_chg), .sense_act(sense_act),
    .cfg_done(cfg_done), .busy(busy), .err(err), .err_code(err_code), .st_done(st_done),
    .st_fail(st_fail), .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_cs_n(spi_cs_n),
    .spi_miso(spi_miso), .spi_mr_n(spi_mr_n));

  hi8436_model #(.T_SO(T_SO), .T_SENSE(1000.0), .UNUSED_STORE(UNUSED_STORE)) u_hi (
    .ncs(spi_cs_n), .sck(spi_sclk), .si(spi_mosi), .nmr(spi_mr_n), .so(spi_miso), .sense_lvl(lvl));

  // ---------------------------------------------------------------- VERIFY_EVERY = 8 DUT (T14)
  reg         startv = 0, stopv = 0, contv = 0;
  wire [31:0] sensev, sense_chgv, sense_actv;
  wire        sense_validv, cfg_donev, busyv, errv, st_donev, st_failv;
  wire [3:0]  err_codev;
  wire        v_sclk, v_mosi, v_cs_n, v_miso, v_mr_n;
`ifdef QUESTA
  hi8436_top #(.DATA_WIDTH(DW), .HAS_MR(HAS_MR != 0), .INIT_EVERY_START(IES != 0), .VERIFY_EVERY(8)) u_dutv (
`else
  hi8436_top_v u_dutv (
`endif
    .clk(clk), .rst_n(rst_n), .start(startv), .stop(stopv), .continuous(contv),
    .period_us(16'd5), .bank_mode(4'b0011), .go_center(6'd9), .go_hyst(6'd5),
    .so_center(6'd35), .so_hyst(6'd15), .self_test_req(1'b0),
    .sense(sensev), .sense_valid(sense_validv), .sense_chg(sense_chgv), .sense_act(sense_actv),
    .cfg_done(cfg_donev), .busy(busyv), .err(errv), .err_code(err_codev), .st_done(st_donev),
    .st_fail(st_failv), .spi_sclk(v_sclk), .spi_mosi(v_mosi), .spi_cs_n(v_cs_n),
    .spi_miso(v_miso), .spi_mr_n(v_mr_n));
  hi8436_model #(.T_SO(T_SO), .T_SENSE(1000.0), .UNUSED_STORE(UNUSED_STORE)) u_hiv (
    .ncs(v_cs_n), .sck(v_sclk), .si(v_mosi), .nmr(v_mr_n), .so(v_miso), .sense_lvl(lvl));

  // ---------------------------------------------------------------- iç sinyaller
`ifdef QUESTA
  reg        s_cmd_valid, s_cmd_ready, s_sync_valid, s_core_rst, s_req;
  reg [15:0] s_cmd;
  reg [7:0]  s_sync;
  initial begin
    $init_signal_spy("/tb_hi8436_drv/u_dut/cmd_valid",  "/tb_hi8436_drv/s_cmd_valid",  0);
    $init_signal_spy("/tb_hi8436_drv/u_dut/cmd_ready",  "/tb_hi8436_drv/s_cmd_ready",  0);
    $init_signal_spy("/tb_hi8436_drv/u_dut/cmd",        "/tb_hi8436_drv/s_cmd",        0);
    $init_signal_spy("/tb_hi8436_drv/u_dut/sync_valid", "/tb_hi8436_drv/s_sync_valid", 0);
    $init_signal_spy("/tb_hi8436_drv/u_dut/sync",       "/tb_hi8436_drv/s_sync",       0);
    $init_signal_spy("/tb_hi8436_drv/u_dut/core_rst",   "/tb_hi8436_drv/s_core_rst",   0);
    $init_signal_spy("/tb_hi8436_drv/u_dut/u_drv/req",  "/tb_hi8436_drv/s_req",        0);
  end
  task force_sync_valid_low;  $signal_force("/tb_hi8436_drv/u_dut/sync_valid", "0", 0, 3, -1, 0); endtask
  task release_sync_valid;    $signal_release("/tb_hi8436_drv/u_dut/sync_valid", 0);              endtask
  task force_sync_id(input [7:0] v); $signal_force("/tb_hi8436_drv/u_dut/sync", $sformatf("%b", v), 0, 3, -1, 0); endtask
  task release_sync_id;       $signal_release("/tb_hi8436_drv/u_dut/sync", 0);                    endtask
  task force_sdi_valid(input v); $signal_force("/tb_hi8436_drv/u_dut/sdi_valid", v ? "1" : "0", 0, 3, -1, 0); endtask
  task release_sdi_valid;     $signal_release("/tb_hi8436_drv/u_dut/sdi_valid", 0);               endtask
  task force_gnt_low;         $signal_force("/tb_hi8436_drv/u_dut/gnt", "0", 0, 3, -1, 0);        endtask
  task release_gnt;           $signal_release("/tb_hi8436_drv/u_dut/gnt", 0);                     endtask
`else
  wire        s_cmd_valid  = u_dut.cmd_valid;
  wire        s_cmd_ready  = u_dut.cmd_ready;
  wire [15:0] s_cmd        = u_dut.cmd;
  wire        s_sync_valid = u_dut.sync_valid;
  wire [7:0]  s_sync       = u_dut.sync;
  wire        s_core_rst   = u_dut.core_rst;
  wire        s_req        = u_dut.u_drv.req;
  task force_sync_valid_low;  force u_dut.sync_valid = 1'b0; endtask
  task release_sync_valid;    release u_dut.sync_valid;      endtask
  task force_sync_id(input [7:0] v); force u_dut.sync = v;  endtask
  task release_sync_id;       release u_dut.sync;            endtask
  task force_sdi_valid(input v); force u_dut.sdi_valid = v; endtask
  task release_sdi_valid;     release u_dut.sdi_valid;       endtask
  task force_gnt_low;         force u_dut.gnt = 1'b0;        endtask
  task release_gnt;           release u_dut.gnt;             endtask
`endif

  // ---------------------------------------------------------------- referans fonksiyonlar
  // Tbl 14 (s.11) / s.9: seviye -> SO (00 GND: 1, 01 band: önceki, 10 high: 0, 11 open: mod)
  function [31:0] ref_so(input [63:0] l, input [3:0] bm, input [31:0] prev);
    integer n;
    begin
      for (n = 0; n < 32; n = n + 1)
        case (l[2*n +: 2])
          2'b00: ref_so[n] = 1'b1;
          2'b01: ref_so[n] = prev[n];
          2'b10: ref_so[n] = 1'b0;
          default: ref_so[n] = bm[n / 8];
        endcase
    end
  endfunction
  function [31:0] expand(input [3:0] bm);
    expand = {{8{bm[3]}}, {8{bm[2]}}, {8{bm[1]}}, {8{bm[0]}}};
  endfunction
  // istenen SO kelimesini veren seviyeler (band yok): GND/Open 1 -> GND, 0 -> open;
  // Supply/Open 1 -> open, 0 -> high
  function [63:0] lvl_for(input [31:0] w, input [3:0] bm);
    integer n;
    begin
      for (n = 0; n < 32; n = n + 1)
        if (bm[n / 8]) lvl_for[2*n +: 2] = w[n] ? 2'b11 : 2'b10;
        else           lvl_for[2*n +: 2] = w[n] ? 2'b00 : 2'b11;
    end
  endfunction

  // ---------------------------------------------------------------- genel izleme
  integer    n_sv = 0, n_svv = 0, n_st_done = 0;
  integer    e_sense = 0, e_chg = 0, e_act = 0, e_svw = 0, e_cfgsv = 0, e_req = 0, e_errc = 0;
  integer    e_sensev = 0;
  reg [31:0] prev_sense = 32'h0, prev_sensev = 32'h0;
  reg [3:0]  bm_lat = 4'b0000;
  reg        sv_d = 1'b0;
  reg [7:0]  last_sync = 8'h00;
  integer    n_core_rst_clk = 0, core_rst_w = 0;

  always @(negedge rst_n) begin prev_sense = 32'h0; prev_sensev = 32'h0; end

  always @(negedge clk) if (rst_n === 1'b1) begin
    // driver ile aynı kural: IDLE'da start / self_test_req -> bank modu latch'lenir
    if (busy === 1'b0 && (start === 1'b1 || st_req === 1'b1)) bm_lat = bank_mode;
    if (sense_valid === 1'b1) begin
      n_sv = n_sv + 1;
      if (sv_d === 1'b1) e_svw = e_svw + 1;
      if (cfg_done !== 1'b1) e_cfgsv = e_cfgsv + 1;
      if (sense !== u_hi.last_norm_f8) begin
        e_sense = e_sense + 1;
        if (e_sense <= 5) $display("    !! sense %h, model F8 %h (t=%0t)", sense, u_hi.last_norm_f8, $time);
      end
      if (sense_chg !== (sense ^ prev_sense)) e_chg = e_chg + 1;
      if (sense_act !== (sense ^ expand(bm_lat))) e_act = e_act + 1;
      prev_sense = sense;
    end
    sv_d = sense_valid;
    if (sense_validv === 1'b1) begin
      n_svv = n_svv + 1;
      if (sensev !== u_hiv.last_norm_f8 || sense_chgv !== (sensev ^ prev_sensev)) e_sensev = e_sensev + 1;
      prev_sensev = sensev;
    end
    if (st_done === 1'b1) n_st_done = n_st_done + 1;
    if (spi_cs_n === 1'b0 && s_req !== 1'b1) e_req = e_req + 1;
    if (err === 1'b0 && err_code !== 4'h0) e_errc = e_errc + 1;
    if (s_sync_valid === 1'b1) last_sync = s_sync;
    if (s_core_rst === 1'b1) n_core_rst_clk = n_core_rst_clk + 1;
  end

  // ---------------------------------------------------------------- paket ölçümleri
  // sınıf: 0 W1 (02/04/1E), 1 W2 (3A/3C), 2 R1 (82/84/9E), 3 R2 (BA/BC), 4 F8
  function integer op_class(input [7:0] o);
    case (o)
      8'h3A, 8'h3C: op_class = 1;
      8'h82, 8'h84, 8'h9E: op_class = 2;
      8'hBA, 8'hBC: op_class = 3;
      8'hF8: op_class = 4;
      default: op_class = 0;
    endcase
  endfunction
  real    cs_min [0:4], cs_max [0:4], pk_min [0:4], pk_max [0:4];
  integer pk_n [0:4];
  real    t_csf_tb = 0.0, t_launch = 0.0;
  real    f8_t [0:63];          // F8 çerçevelerinin CS düşen zamanları (T06)
  integer n_f8_t = 0;
  reg     f8_rec = 1'b0;
  integer k;
  initial for (k = 0; k < 5; k = k + 1) begin
    cs_min[k] = 1e9; cs_max[k] = 0.0; pk_min[k] = 1e9; pk_max[k] = 0.0; pk_n[k] = 0;
  end
  always @(negedge spi_cs_n) t_csf_tb = $realtime;
  always @(posedge spi_cs_n) if (rst_n === 1'b1 && $realtime > 1.0) begin
    k = op_class(u_hi.last_op);
    if ($realtime - t_csf_tb < cs_min[k]) cs_min[k] = $realtime - t_csf_tb;
    if ($realtime - t_csf_tb > cs_max[k]) cs_max[k] = $realtime - t_csf_tb;
    if (f8_rec && u_hi.last_op == 8'hF8 && n_f8_t < 64) begin f8_t[n_f8_t] = t_csf_tb; n_f8_t = n_f8_t + 1; end
  end
  // posedge'de örneklenir (kenardan önceki değerler): yarım clock'luk handshake de görülür
  always @(posedge clk) if (rst_n === 1'b1) begin
    if (s_cmd_valid === 1'b1 && s_cmd_ready === 1'b1 && s_cmd === 16'h2002) t_launch = $realtime;
    if (s_sync_valid === 1'b1) begin
      k = op_class(u_hi.last_op);
      pk_n[k] = pk_n[k] + 1;
      if ($realtime - t_launch < pk_min[k]) pk_min[k] = $realtime - t_launch;
      if ($realtime - t_launch > pk_max[k]) pk_max[k] = $realtime - t_launch;
    end
  end

  // nMR pulse ölçümü (T02)
  real t_mrf = 0.0, mr_w = 0.0;
  always @(negedge spi_mr_n) t_mrf = $realtime;
  always @(posedge spi_mr_n) if ($realtime > 1.0 && rst_n === 1'b1) mr_w = $realtime - t_mrf;

  // beklenen iptal: yalnız reset testlerinde, CS low iken rst_n düşerse
  reg     exp_abort_win = 1'b0;
  integer n_exp_abort = 0;
  always @(negedge rst_n) if (exp_abort_win && spi_cs_n === 1'b0) n_exp_abort = n_exp_abort + 1;

  // ---------------------------------------------------------------- yardımcı task'lar
  integer n_pass = 0, n_fail = 0;
  task result(input integer pass, input [8*100:1] name);
    begin
      if (pass) begin n_pass = n_pass + 1; $display("  PASS  %0s", name); end
      else      begin n_fail = n_fail + 1; $display("  FAIL  %0s", name); end
    end
  endtask
  task pulse_start; begin @(negedge clk) start = 1'b1; @(negedge clk) start = 1'b0; end endtask
  task pulse_stop;  begin @(negedge clk) stop = 1'b1;  @(negedge clk) stop = 1'b0;  end endtask
  task pulse_st;    begin @(negedge clk) st_req = 1'b1; @(negedge clk) st_req = 1'b0; end endtask
  task wait_idle(input real max_ns);
    real t0;
    begin
      t0 = $realtime; @(negedge clk);
      while (busy !== 1'b0 && $realtime - t0 < max_ns) @(negedge clk);
    end
  endtask
  task wait_sv(input integer n, input real max_ns);   // şu andan itibaren n sense_valid
    integer tgt; real t0;
    begin
      tgt = n_sv + n; t0 = $realtime;
      while (n_sv < tgt && $realtime - t0 < max_ns) @(negedge clk);
    end
  endtask
  task wait_ns(input real ns); begin #(ns); @(negedge clk); end endtask
  task wait_op(input integer n, input real max_ns);    // model n opcode daha çözene kadar
    integer tgt; real t0;
    begin
      tgt = u_hi.n_op + n; t0 = $realtime;
      while (u_hi.n_op < tgt && $realtime - t0 < max_ns) #10;
    end
  endtask
  // varsayılan köşede entegreyi tam init'e zorla: boştayken rst_n pulse'ı (IES = 1'de hiçbir şey)
  task force_full_init;
    begin
      if (IES == 0) begin
        @(negedge clk) rst_n = 1'b0; #50; @(negedge clk) rst_n = 1'b1; wait_ns(100.0);
      end
    end
  endtask
  task cfg_default;
    begin
      bank_mode = 4'b0000; go_c = 6'd9; go_h = 6'd5; so_c = 6'd35; so_h = 6'd15;
      continuous = 1'b0; period_us = 16'd0;
    end
  endtask
  // op_log[m..] beklenen listeyle aynı mı
  reg [7:0] exp_ops [0:63];
  integer   n_exp_ops;
  function ops_match(input integer m);
    integer i;
    begin
      ops_match = (u_hi.n_op - m == n_exp_ops);
      for (i = 0; i < n_exp_ops; i = i + 1)
        if (u_hi.op_log[m + i] !== exp_ops[i]) ops_match = 0;
    end
  endfunction
  task exp_init;   // init opcode'ları
    begin
      exp_ops[0] = 8'h02; exp_ops[1] = 8'h04; exp_ops[2] = 8'h3A; exp_ops[3] = 8'h3C; exp_ops[4] = 8'h1E;
      exp_ops[5] = 8'h82; exp_ops[6] = 8'h84; exp_ops[7] = 8'hBA; exp_ops[8] = 8'hBC; exp_ops[9] = 8'h9E;
      n_exp_ops = 10;
    end
  endtask
  task exp_add(input [7:0] o); begin exp_ops[n_exp_ops] = o; n_exp_ops = n_exp_ops + 1; end endtask
  function integer count_op(input integer m, input [7:0] o);
    integer i;
    begin
      count_op = 0;
      for (i = m; i < u_hi.n_op; i = i + 1) if (u_hi.op_log[i] == o) count_op = count_op + 1;
    end
  endfunction
  task show_ops(input integer m);
    integer i;
    begin
      $write("    op:");
      for (i = m; i < u_hi.n_op && i < m + 40; i = i + 1) $write(" %h", u_hi.op_log[i]);
      $write("\n");
    end
  endtask
  // sonraki F8 çerçevesinin opcode'u çözülene kadar bekle (CS düşüşünden ~0,6 us sonra,
  // çerçeve 2,58 us sürer; çağıran +300 ns ile hâlâ çerçeve ortasındadır). Sınırlı bekleme.
  task wait_f8_cs;
    integer n0; real t0;
    begin
      n0 = u_hi.n_f8; t0 = $realtime;
      while (u_hi.n_f8 == n0 && $realtime - t0 < 200000.0) #10;
    end
  endtask
  // reset anında bütün çıkışlar güvenli değerde mi
  function outs_reset(input dummy);
    outs_reset = (busy === 1'b0 && err === 1'b0 && err_code === 4'h0 && cfg_done === 1'b0 &&
                  sense === 32'h0 && sense_valid === 1'b0 && sense_chg === 32'h0 &&
                  sense_act === 32'h0 && st_done === 1'b0 && st_fail === 1'b0 &&
                  spi_cs_n === 1'b1 && spi_mr_n === 1'b1 && spi_sclk === 1'b0);
  endfunction

  // ---------------------------------------------------------------- testler
  integer    m, f0, sv0, a0, ok, ok2, ok3, i, j, mr0, e0;
  real       t0, t1, d;
  reg [31:0] w, s0, s1, e;

  initial begin
    $display("tb_hi8436_drv: T_SO = %0.1f ns, DATA_WIDTH = %0d, UNUSED_STORE = %0d, HAS_MR = %0d, INIT_EVERY_START = %0d",
             T_SO, DW, UNUSED_STORE, HAS_MR, IES);
    #200 @(negedge clk) rst_n = 1'b1;

    // ============================================================ T01
    $display("\n--- T01 reset sonrasi cikislar");
    #800;
    ok = (busy === 0 && err === 0 && err_code === 0 && cfg_done === 0 && sense === 0 &&
          sense_valid === 0 && st_fail === 0 && spi_cs_n === 1 && spi_mr_n === 1 && spi_sclk === 0);
    wait_ns(5000.0);
    result(ok && u_hi.frames == 0 && busy === 0, "T01 reset sonrasi cikislar, start'siz SPI trafigi yok");

    // ============================================================ T02
    $display("\n--- T02 init (nMR, 5 yazma, 5 geri okuma, dogrulama)");
    cfg_default; bank_mode = 4'b0101;
    lvl = lvl_for(32'hA5A5_0F0F, 4'b0101); wait_ns(1500.0);
    m = u_hi.n_op; sv0 = n_sv; mr0 = u_hi.mr_resets; mr_w = 0.0;
    t0 = $realtime; pulse_start;
    while (cfg_done !== 1'b1 && $realtime - t0 < 100000.0) @(negedge clk);
    t1 = $realtime;
    wait_idle(100000.0);
    exp_init; exp_add(8'hF8);
    ok = ops_match(m);
    ok2 = (u_hi.ctrl == 8'h00 && u_hi.psen == 8'h05 && u_hi.gohys == 8'h05 && u_hi.gocval == 8'h09 &&
           u_hi.sohys == 8'h0F && u_hi.socval == 8'h23 && u_hi.tmdata == 8'h00);
    $display("    nMR pulse %0.0f ns (>= 100), model nMR reset +%0d | start -> cfg_done %0.2f us | sense %h",
             mr_w, u_hi.mr_resets - mr0, (t1 - t0) / 1000.0, sense);
    $display("    model register: CTRL %h PSEN %h GOHYS %h GOCVAL %h SOHYS %h SOCVAL %h TMDATA %h",
             u_hi.ctrl, u_hi.psen, u_hi.gohys, u_hi.gocval, u_hi.sohys, u_hi.socval, u_hi.tmdata);
    show_ops(m);
    ok3 = HAS_MR ? (mr_w == 200.0 && u_hi.mr_resets - mr0 == 1) : (mr_w == 0.0 && u_hi.mr_resets == mr0);
    result(ok && ok2 && ok3 && cfg_done === 1 && err === 0 &&
           n_sv - sv0 == 1 && busy === 0 && sense === 32'hA5A5_0F0F, "T02 init + geri okuma, register'lar, nMR");

    // ============================================================ T03
    $display("\n--- T03 tek okuma");
    w = 32'h3C96_E10F; lvl = lvl_for(w, 4'b0101); wait_ns(1500.0);
    sv0 = n_sv; m = u_hi.n_op; mr0 = u_hi.mr_resets;
    pulse_start; wait_idle(100000.0);
    $display("    sense %h (beklenen %h), sense_valid %0d, paket %0d", sense, w, n_sv - sv0, u_hi.n_op - m);
    // IES = 1: her start tam init (11 paket); IES = 0: ayarlar aynı -> doğrudan okuma (1 paket, nMR yok)
    result(sense === w && n_sv - sv0 == 1 && busy === 0 && e_svw == 0 &&
           (IES ? (u_hi.n_op - m == 11) : (u_hi.n_op - m == 1 && u_hi.mr_resets == mr0)),
           "T03 tek okuma: sense dogru, 1 sense_valid, busy duser");

    // ============================================================ T04
    $display("\n--- T04 polarite (bank_mode 0110), sense_act");
    bank_mode = 4'b0110;
    for (i = 0; i < 32; i = i + 1) lvl[2*i +: 2] = (i % 3 == 0) ? 2'b00 : (i % 3 == 1) ? 2'b10 : 2'b11;
    wait_ns(1500.0);
    e = ref_so(lvl, 4'b0110, 32'h0);
    pulse_start; wait_idle(100000.0);
    ok = 1;
    for (i = 0; i < 32; i = i + 1)   // aktif: GND/Open'da toprak, Supply/Open'da besleme
      if (sense_act[i] !== ((bank_mode[i / 8] == 1'b0 && lvl[2*i +: 2] == 2'b00) ||
                            (bank_mode[i / 8] == 1'b1 && lvl[2*i +: 2] == 2'b10))) ok = 0;
    $display("    sense %h (Tbl 14 referansi %h) | sense_act %h", sense, e, sense_act);
    result(sense === e && ok, "T04 polarite (GND/Open, Supply/Open; GND/high/open), sense_act");

    // ============================================================ T05
    // Hysteresis sürekli okuma içinde test edilir: her start nMR ile tam reset yapar ve
    // SO latch'leri reset değerine (0x00, s.9 Tbl 8-12) döner (DS-10), band'deki kanalın
    // önceki durumu start'lar arasında taşınmaz.
    $display("\n--- T05 hysteresis (band'de onceki durum korunur, surekli okuma)");
    cfg_default; continuous = 1'b1; period_us = 16'd5;
    for (i = 0; i < 32; i = i + 1) lvl[2*i +: 2] = (i < 16) ? 2'b00 : 2'b10;
    wait_ns(1500.0); pulse_start; wait_sv(2, 100000.0); s0 = sense;
    for (i = 0; i < 8; i = i + 1) begin lvl[2*i +: 2] = 2'b01; lvl[2*(i+16) +: 2] = 2'b01; end
    wait_ns(1500.0); wait_sv(2, 100000.0); w = sense;            // band: 0000ffff kalmalı
    for (i = 0; i < 8; i = i + 1) lvl[2*i +: 2] = 2'b10;         // ch0-7 high ...
    wait_ns(1500.0); wait_sv(2, 100000.0); e = sense;            // 0000ff00
    for (i = 0; i < 8; i = i + 1) lvl[2*i +: 2] = 2'b01;         // ... sonra band: 0 kalır
    for (i = 16; i < 24; i = i + 1) lvl[2*i +: 2] = 2'b00;       // ch16-23 GND (1)
    wait_ns(1500.0); wait_sv(2, 100000.0); s1 = sense;           // 00ffff00
    for (i = 16; i < 24; i = i + 1) lvl[2*i +: 2] = 2'b01;       // ch16-23 band: 1 kalır
    wait_ns(1500.0); wait_sv(2, 100000.0);
    pulse_stop; wait_idle(10000.0);
    $display("    %h -> band %h -> high %h -> band/GND %h -> band %h", s0, w, e, s1, sense);
    result(s0 === 32'h0000_FFFF && w === 32'h0000_FFFF && e === 32'h0000_FF00 && s1 === 32'h00FF_FF00 &&
           sense === 32'h00FF_FF00, "T05 hysteresis: band icindeki kanal onceki durumunu korur (0 ve 1)");

    // ============================================================ T06
    $display("\n--- T06 surekli okuma + period_us");
    cfg_default; continuous = 1'b1; period_us = 16'd20;
    lvl = lvl_for(32'h0F0F_A5A5, 4'b0000); wait_ns(1500.0);
    pulse_start; wait_sv(1, 100000.0);
    n_f8_t = 0; f8_rec = 1'b1;
    wait_sv(5, 200000.0);
    ok = (n_f8_t >= 5);
    for (i = 1; i < n_f8_t; i = i + 1) if (f8_t[i] - f8_t[i-1] != 20000.0) ok = 0;
    $display("    period 20 us: F8 CS araliklari (ns): %0.0f %0.0f %0.0f %0.0f",
             f8_t[1] - f8_t[0], f8_t[2] - f8_t[1], f8_t[3] - f8_t[2], f8_t[4] - f8_t[3]);
    period_us = 16'd0; wait_sv(2, 100000.0); n_f8_t = 0; wait_sv(4, 100000.0);
    d = f8_t[2] - f8_t[1];
    ok2 = (n_f8_t >= 3 && d > 2700.0 && d < 3100.0 && f8_t[1] - f8_t[0] == d);
    $display("    period 0: arka arkaya aralik %0.0f ns (en yuksek okuma hizi %0.0f kHz)", d, 1.0e6 / d);
    period_us = 16'd2; wait_sv(2, 100000.0); n_f8_t = 0; wait_sv(4, 100000.0);
    ok3 = (n_f8_t >= 3 && f8_t[2] - f8_t[1] == d);
    $display("    period 2 us (< paket suresi): aralik %0.0f ns", f8_t[2] - f8_t[1]);
    f8_rec = 1'b0; pulse_stop; wait_idle(10000.0);
    result(ok && ok2 && ok3 && busy === 0, "T06 surekli + period_us: tam 20 us; period 0 ve 2 us arka arkaya");

    // ============================================================ T07
    $display("\n--- T07 sense degisimi, sense_chg, gecikme");
    cfg_default; bank_mode = 4'b0101; continuous = 1'b1; period_us = 16'd5;
    e0 = e_sense + e_chg + e_act; sv0 = n_sv;
    pulse_start; wait_sv(1, 100000.0);
    j = 0;
    for (i = 0; i < 25; i = i + 1) begin
      lvl[2*($random & 31) +: 2] = $random;
      lvl[2*($random & 31) +: 2] = $random;
      #(2000 + ($random & 4095));
      if (sense_chg !== 32'h0) j = j + 1;
    end
    // tek değişimin gecikmesi: kanal 11 (bank 1 = GND/Open) GND -> open: SO 1 -> 0
    lvl[23:22] = 2'b00; wait_ns(12000.0);
    t0 = $realtime; lvl[23:22] = 2'b11;
    while (sense[11] !== 1'b0 && $realtime - t0 < 20000.0) @(negedge clk);
    d = $realtime - t0;
    pulse_stop; wait_idle(10000.0);
    $display("    %0d okuma, sense_chg /= 0 goruldu: %0d | tek degisim gecikmesi %0.0f ns (<= T_SENSE 1000 + period 5000 + paket 2770)",
             n_sv - sv0, j, d);
    result(e_sense + e_chg + e_act == e0 && j >= 5 && d <= 8800.0, "T07 sense degisimi: sense = model, sense_chg = xor, gecikme");

    // ============================================================ T08
    $display("\n--- T08 calisirken ayar degisikligi uygulanmaz");
    cfg_default; continuous = 1'b1; period_us = 16'd10;
    pulse_start; wait_sv(2, 100000.0);
    m = u_hi.n_op;
    bank_mode = 4'b1111; go_c = 6'd10; go_h = 6'd4; so_c = 6'd30; so_h = 6'd10;
    wait_ns(40000.0);
    ok = (count_op(m, 8'hF8) == u_hi.n_op - m && u_hi.psen == 8'h00 && u_hi.gohys == 8'h05 &&
          u_hi.gocval == 8'h09 && u_hi.sohys == 8'h0F && u_hi.socval == 8'h23 && busy === 1);
    pulse_stop; wait_idle(10000.0);
    continuous = 1'b0; pulse_start; wait_idle(100000.0);
    ok2 = (u_hi.psen == 8'h0F && u_hi.gohys == 8'h04 && u_hi.gocval == 8'h0A && u_hi.sohys == 8'h0A &&
           u_hi.socval == 8'h1E && err === 0 && cfg_done === 1);
    $display("    calisirken: yalniz F8 (%0d), register'lar eski | stop/start sonrasi PSEN %h GO %h/%h SO %h/%h",
             u_hi.n_op - m, u_hi.psen, u_hi.gohys, u_hi.gocval, u_hi.sohys, u_hi.socval);
    result(ok && ok2, "T08 ayar degisikligi calisirken uygulanmaz, stop/start ile uygulanir");

    // ============================================================ T09
    $display("\n--- T09 stop");
    cfg_default; a0 = u_hi.aborted;
    // (a) period boşluğunda stop
    continuous = 1'b1; period_us = 16'd20;
    pulse_start; wait_sv(2, 100000.0); wait_ns(1000.0);
    f0 = u_hi.frames; t0 = $realtime; pulse_stop;
    while (busy !== 1'b0 && $realtime - t0 < 10000.0) @(negedge clk);
    t1 = $realtime; wait_ns(30000.0);
    j = u_hi.frames - f0;
    ok = (j == 0 && t1 - t0 <= 40.0);
    // (b) paket uçarken stop: paket biter, yenisi başlamaz
    period_us = 16'd0;
    pulse_start; wait_sv(2, 100000.0);
    wait_f8_cs; #300; f0 = u_hi.frames; pulse_stop; wait_idle(10000.0); wait_ns(10000.0);
    ok2 = (u_hi.frames == f0 && u_hi.aborted == a0 && u_hi.last_op == 8'hF8);
    // (c) init sırasında stop (3. yazma çerçevesi sırasında)
    force_full_init;
    continuous = 1'b0; m = u_hi.n_op;
    pulse_start; wait_op(3, 20000.0); #200; pulse_stop; wait_idle(20000.0); wait_ns(5000.0);
    ok3 = (u_hi.n_op - m == 3 && cfg_done === 0 && err === 0 && busy === 0 && u_hi.aborted == a0);
    show_ops(m);
    $display("    (a) bosluk: busy %0.0f ns'de dustu, yeni cerceve %0d | (b) ucan paket tamamlandi, yeni cerceve 0 | (c) init: %0d paket",
             t1 - t0, j, u_hi.n_op - m);
    result(ok && ok2 && ok3, "T09 stop: boslukta hemen, ucan paket biter (iptal yok), init sirasinda");

    // ============================================================ T10
    $display("\n--- T10 busy iken start yok sayilir");
    cfg_default; continuous = 1'b1; period_us = 16'd10;
    pulse_start; wait_sv(2, 100000.0);
    m = u_hi.n_op; sv0 = n_sv;
    pulse_start; wait_ns(30000.0);
    ok = (count_op(m, 8'h02) == 0 && busy === 1 && n_sv - sv0 >= 2);
    pulse_stop; wait_idle(10000.0);
    result(ok, "T10 busy iken start: yeniden init yok, okumalar suruyor");

    // ============================================================ T11
    $display("\n--- T11 geri okuma hatasi");
    cfg_default; force_full_init; m = u_hi.n_op; sv0 = n_sv; mr0 = u_hi.mr_resets;
    u_hi.inj_rb_flip = 1;
    pulse_start; wait_idle(200000.0);
    ok = (err === 1 && err_code === 4'h2 && cfg_done === 1 && n_sv - sv0 == 1 &&
          count_op(m, 8'h02) == 2 && u_hi.mr_resets - mr0 == 2 * HAS_MR && u_hi.n_op - m == 21);
    $display("    tek hata: err %0d code %h, init sayisi %0d, okuma %0d", err, err_code, count_op(m, 8'h02), n_sv - sv0);
    force_full_init; m = u_hi.n_op; sv0 = n_sv;
    u_hi.inj_rb_flip = 2;
    pulse_start; wait_idle(400000.0);
    u_hi.inj_rb_flip = 0;
    ok2 = (err === 1 && err_code === 4'h2 && cfg_done === 0 && busy === 0 && count_op(m, 8'h02) == 4 &&
           count_op(m, 8'hF8) == 0 && n_sv == sv0);
    $display("    surekli hata: init denemesi %0d (ERR_LIMIT 4), F8 %0d, cfg_done %0d", count_op(m, 8'h02), count_op(m, 8'hF8), cfg_done);
    m = u_hi.n_op;
    pulse_start; wait_idle(100000.0);
    // ERR_LIMIT ile durduktan sonraki start: tam init (nMR + 02..9E)
    ok = ok && (err === 0 && cfg_done === 1 && count_op(m, 8'h02) == 1 && count_op(m, 8'h9E) == 1);
    // (c) her geri okuma register'ı ayrı ayrı karşılaştırılıyor mu: 82, 84, BA, BC, 9E
    ok3 = 1;
    for (j = 0; j < 5; j = j + 1) begin
      force_full_init;
      m = u_hi.n_op;
      u_hi.inj_rb_op = (j == 0) ? 8'h82 : (j == 1) ? 8'h84 : (j == 2) ? 8'hBA : (j == 3) ? 8'hBC : 8'h9E;
      pulse_start; wait_idle(200000.0);
      if (!(err === 1 && err_code === 4'h2 && count_op(m, 8'h02) == 2 && cfg_done === 1)) begin
        ok3 = 0; $display("    !! %0d. register hatasi yakalanmadi", j);
      end
    end
    $display("    tek register hatasi (82/84/BA/BC/9E ayri ayri): hepsi yakalandi: %0s", ok3 ? "evet" : "HAYIR");
    result(ok && ok2 && ok3, "T11 geri okuma hatasi: err/kod 2, retry; ERR_LIMIT'te durur; her register ayri kontrol");

    // ============================================================ T12
    $display("\n--- T12 CFG_RANGE");
    cfg_default; f0 = u_hi.frames; mr0 = u_hi.mr_resets;
    go_h = 6'd0; pulse_start; wait_ns(3000.0);
    ok = (err === 1 && err_code === 4'h1 && busy === 0);
    go_h = 6'd5; go_c = 6'd50; pulse_start; wait_ns(3000.0);         // 50 + 5 > 52
    ok = ok && (err === 1 && err_code === 4'h1);
    go_c = 6'd6; go_h = 6'd3; pulse_start; wait_ns(3000.0);           // 6 - 3 < 4
    ok = ok && (err === 1 && err_code === 4'h1);
    bank_mode = 4'b0001; go_c = 6'd9; go_h = 6'd5; so_h = 6'd0; pulse_start; wait_ns(3000.0);  // SO kullanılıyor
    j = u_hi.frames - f0;
    ok = ok && (err === 1 && err_code === 4'h1 && j == 0 && u_hi.mr_resets == mr0);
    bank_mode = 4'b0000; pulse_start; wait_idle(100000.0);           // SO kullanılmıyor: kabul
    ok2 = (err === 0 && cfg_done === 1 && u_hi.sohys == 8'h00 && u_hi.socval == 8'h23);
    bank_mode = 4'b1111; so_h = 6'd15; go_h = 6'd0; pulse_start; wait_idle(100000.0);   // GO kullanılmıyor
    ok3 = (err === 0 && cfg_done === 1 && u_hi.gohys == 8'h00 && u_hi.psen == 8'h0F);
    $display("    red: go_h=0, 50+5, 6-3, (bm 0001, so_h=0) -> SPI trafigi %0d | kabul: bm 0000 so_h=0, bm 1111 go_h=0",
             j);
    result(ok && ok2 && ok3, "T12 CFG_RANGE: gecersiz kod reddi (SPI yok), kullanilmayan mod kontrol edilmez");

    // ============================================================ T13
    $display("\n--- T13 self-test");
    cfg_default;
    // (a) IDLE'dan, continuous = 0: init + self-test, okuma yok. IES = 0: önce ayarlar bir start
    //     ile uygulanır; self_test_req (init_done = 1, ayarlar aynı) doğrudan self-test yapar.
    if (IES == 0) begin pulse_start; wait_idle(100000.0); end
    m = u_hi.n_op; sv0 = n_sv; i = n_st_done; j = u_hi.n_f8_test;
    pulse_st; wait_idle(200000.0);
    if (IES) exp_init; else n_exp_ops = 0;
    exp_add(8'h1E); exp_add(8'h02); exp_add(8'hF8); exp_add(8'h1E); exp_add(8'hF8); exp_add(8'h02); exp_add(8'h1E);
    ok = (ops_match(m) && n_st_done - i == 1 && st_fail === 0 && err === 0 && n_sv == sv0 &&
          u_hi.ctrl == 8'h00 && u_hi.tmdata == 8'h00 && u_hi.n_f8_test - j == 2 && cfg_done === 1);
    show_ops(m);
    $display("    (a) IDLE'dan: st_done %0d st_fail %0d, sense_valid %0d", n_st_done - i, st_fail, n_sv - sv0);
    // (b) çalışırken: sıradaki okuma yerine self-test, sonra okumalar sürer.
    //     DS-9: band içindeki kanallar (16-23) self-test sonrası son test değerini (ALL0 -> 1) korur
    //     IES = 0: start entegreyi reset'lemez; band kanalları önce high (0) yapılıp band'e alınır
    for (i = 0; i < 32; i = i + 1)
      lvl[2*i +: 2] = (i < 8) ? 2'b00 : (i < 16) ? 2'b10 : (i < 24) ? (IES ? 2'b01 : 2'b10) : 2'b11;
    if (IES == 0) begin wait_ns(1500.0); for (i = 16; i < 24; i = i + 1) lvl[2*i +: 2] = 2'b01; end
    wait_ns(1500.0);
    continuous = 1'b1; period_us = 16'd10;
    pulse_start; wait_sv(2, 100000.0); s0 = sense;
    m = u_hi.n_op; i = n_st_done; e0 = e_sense;
    pulse_st; wait_sv(3, 200000.0);
    ok2 = (n_st_done - i == 1 && st_fail === 0 && err === 0 && count_op(m, 8'h1E) == 3 &&
           count_op(m, 8'h02) == 2 && u_hi.ctrl == 8'h00 && e_sense == e0 && busy === 1 &&
           sense[23:16] === 8'hFF && sense[15:0] === s0[15:0] && sense[31:24] === s0[31:24] &&
           (IES != 0 || s0[23:16] === 8'h00));
    show_ops(m);
    $display("    (b) calisirken: st_done %0d | DS-9: once %h, self-test sonrasi %h (band kanallari 23:16 -> ff)",
             n_st_done - i, s0, sense);
    pulse_stop; wait_idle(10000.0);
    // (c) hata: test cevabı bozuk -> st_fail, err 4, test modundan çıkılmış, durur
    continuous = 1'b0; u_hi.inj_st_bad = 1; i = n_st_done;
    pulse_st; wait_idle(200000.0);
    ok3 = (n_st_done - i == 1 && st_fail === 1 && err === 1 && err_code === 4'h4 && busy === 0 &&
           cfg_done === 0 && u_hi.ctrl == 8'h00 && u_hi.tmdata == 8'h00);
    $display("    (c) hata: st_fail %0d err %0d code %h, model CTRL %h TMDATA %h", st_fail, err, err_code, u_hi.ctrl, u_hi.tmdata);
    // (d) self-test sırasında stop: test tamamlanır (çıkış yazmaları), sonra durur
    continuous = 1'b1; m = u_hi.n_op; i = n_st_done; sv0 = n_sv;
    pulse_st; wait_op(11, 50000.0); pulse_stop; wait_idle(100000.0);
    ok3 = ok3 && (n_st_done - i == 1 && st_fail === 0 && u_hi.ctrl == 8'h00 && u_hi.tmdata == 8'h00 &&
                  count_op(m, 8'h1E) == 4 && n_sv == sv0 && busy === 0);
    $display("    (d) stop self-test sirasinda: test tamamlandi (%0d paket), okuma yok", u_hi.n_op - m);
    result(ok && ok2 && ok3, "T13 self-test: IDLE'dan / calisirken, DS-9, hata -> dur, stop ertelenir");

    // ============================================================ T14
    $display("\n--- T14 periyodik dogrulama (VERIFY_EVERY = 8) + POR glitch");
    i = u_hiv.n_op;
    @(negedge clk) begin contv = 1'b1; startv = 1'b1; end @(negedge clk) startv = 1'b0;
    t0 = $realtime; while (n_svv < 18 && $realtime - t0 < 400000.0) @(negedge clk);
    ok = 1;
    // init (10) + F8 ve her 8 okumada bir 82 84 BA BC 9E
    for (j = i + 10; j < i + 10 + 13; j = j + 1)
      if (u_hiv.op_log[j] !== ((j - i - 10 < 8) ? 8'hF8 : (j - i - 10 == 8) ? 8'h82 : (j - i - 10 == 9) ? 8'h84 :
                               (j - i - 10 == 10) ? 8'hBA : (j - i - 10 == 11) ? 8'hBC : 8'h9E)) ok = 0;
    m = u_hiv.n_op; sv0 = n_svv;
    u_hiv.por;
    t0 = $realtime; while (!(errv === 1'b1 && cfg_donev === 1'b1 && n_svv > sv0 + 3) && $realtime - t0 < 400000.0) @(negedge clk);
    ok2 = (errv === 1 && err_codev === 4'h3 && cfg_donev === 1 && busyv === 1 && u_hiv.psen == 8'h03 &&
           u_hiv.gohys == 8'h05 && u_hiv.socval == 8'h23 && e_sensev == 0);
    j = 0; for (i = m; i < u_hiv.n_op; i = i + 1) if (u_hiv.op_log[i] == 8'h02) j = j + 1;
    @(negedge clk) stopv = 1'b1; @(negedge clk) stopv = 1'b0;
    t0 = $realtime; while (busyv !== 1'b0 && $realtime - t0 < 20000.0) @(negedge clk);
    $display("    dogrulama paketleri her 8 okumada: %0s | POR sonrasi: err %0d code %h, yeniden init %0d, okumalar suruyor",
             ok ? "evet" : "HAYIR", errv, err_codev, j);
    result(ok && ok2 && j == 1 && busyv === 0, "T14 VERIFY_EVERY: her 8 okumada dogrulama; POR -> kod 3, yeniden init");

    // ============================================================ T15
    $display("\n--- T15 SYNC timeout (sync_valid force 0) -> core_rst");
    cfg_default; continuous = 1'b1; period_us = 16'd10;
    pulse_start; wait_sv(2, 100000.0);
    wait_f8_cs; force_sync_valid_low; i = n_core_rst_clk;
    wait_idle(50000.0); release_sync_valid;
    ok = (err === 1 && err_code === 4'h8 && n_core_rst_clk - i == 4 && cfg_done === 0);
    $display("    err %0d code %h, core_rst pulse %0d clk", err, err_code, n_core_rst_clk - i);
    continuous = 1'b0; pulse_start; wait_idle(100000.0);
    result(ok && err === 0 && err_code === 0 && cfg_done === 1, "T15 SYNC timeout: kod 8, core_rst 4 clk, start ile normal");

    // ============================================================ T16
    $display("\n--- T16 yanlis SYNC id");
    continuous = 1'b1; pulse_start; wait_sv(2, 100000.0);
    wait_f8_cs; force_sync_id(last_sync + 8'd8);
    wait_idle(50000.0); release_sync_id;
    ok = (err === 1 && err_code === 4'h9 && busy === 0);
    continuous = 1'b0; pulse_start; wait_idle(100000.0);
    result(ok && err === 0 && cfg_done === 1, "T16 yanlis SYNC id: kod 9, start ile normal");

    // ============================================================ T17
    $display("\n--- T17 beklenmeyen / eksik sdi kelimesi");
    continuous = 1'b1; period_us = 16'd20;
    pulse_start; wait_sv(2, 100000.0); wait_ns(2000.0);
    @(posedge clk) #1 force_sdi_valid(1'b1); @(posedge clk) #1 release_sdi_valid;
    wait_idle(10000.0);
    ok = (err === 1 && err_code === 4'hA && busy === 0);
    pulse_start; wait_sv(2, 100000.0);
    wait_f8_cs; force_sdi_valid(1'b0);
    wait_idle(50000.0); release_sdi_valid;
    ok2 = (err === 1 && err_code === 4'hB && busy === 0);
    $display("    beklenmeyen: code %s | eksik: code %h", ok ? "A" : "?", err_code);
    continuous = 1'b0; pulse_start; wait_idle(100000.0);
    result(ok && ok2 && err === 0 && cfg_done === 1, "T17 sdi: beklenmeyen kelime kod A, eksik kelime kod B");

    // ============================================================ T18
    $display("\n--- T18 settle");
    $display("    yazma -> F8 en kisa %0.0f ns (SETTLE 2 us), model settle ihlali %0d", u_hi.min_settle, u_hi.e_settle);
    result(u_hi.min_settle >= 2000.0 && u_hi.e_settle == 0 && u_hi.n_f8_test >= 4,
           "T18 settle: init ve self-test sonrasi ilk F8 >= 2 us, ihlal 0");

    // ============================================================ T19
    $display("\n--- T19 gnt / req");
    cfg_default; force_gnt_low; f0 = u_hi.frames;
    pulse_start; wait_ns(5000.0);
    ok = (u_hi.frames == f0 && s_req === 1'b1 && busy === 1 && err === 0);
    release_gnt; wait_idle(100000.0);
    // IES = 1: tam init + F8 (11 çerçeve); IES = 0: ayarlar aynı -> yalnız F8 (1 çerçeve)
    ok2 = (err === 0 && cfg_done === 1 && u_hi.frames - f0 == (IES ? 11 : 1) && e_req == 0);
    $display("    gnt=0: cerceve %0d, req %0d | gnt=1: %0d cerceve, CS low iken req=0 sayisi %0d", 0, s_req, u_hi.frames - f0, e_req);
    result(ok && ok2, "T19 gnt=0 iken paket yok (timeout yok), req paket boyunca 1");

    // ============================================================ T20
    $display("\n--- T20 reset frame ortasinda (SCK aktif)");
    exp_abort_win = 1'b1; a0 = u_hi.aborted; i = n_exp_abort;
    cfg_default; continuous = 1'b1;
    pulse_start; wait_sv(2, 100000.0);
    wait_f8_cs; #300; @(posedge clk); #3 rst_n = 1'b0; #1;
    ok = outs_reset(0);
    #100 @(negedge clk) rst_n = 1'b1; continuous = 1'b0;
    f0 = u_hi.frames; wait_ns(5000.0);
    ok2 = (u_hi.frames == f0 && busy === 0);
    mr0 = u_hi.mr_resets; pulse_start; wait_idle(100000.0);
    ok3 = (cfg_done === 1 && err === 0 && u_hi.mr_resets - mr0 == HAS_MR && sense === u_hi.last_norm_f8);
    $display("    1 ns sonra cikislar guvenli: %0s | kendiliginden baslama yok: %0s | start ile init: %0s | iptal %0d",
             ok ? "evet" : "HAYIR", ok2 ? "evet" : "HAYIR", ok3 ? "evet" : "HAYIR", u_hi.aborted - a0);
    result(ok && ok2 && ok3 && u_hi.aborted - a0 == 1 && n_exp_abort - i == 1, "T20 reset frame ortasinda");

    // ============================================================ T21
    $display("\n--- T21 reset clock dururken");
    a0 = u_hi.aborted; i = n_exp_abort;
    continuous = 1'b1; pulse_start; wait_sv(2, 100000.0);
    wait_f8_cs; #300; @(negedge clk); clk_en = 1'b0;
    #50 rst_n = 1'b0; #1;
    ok = outs_reset(0);
    #200 clk_en = 1'b1; #47 @(negedge clk) rst_n = 1'b1; continuous = 1'b0;
    f0 = u_hi.frames; wait_ns(5000.0);
    ok2 = (u_hi.frames == f0 && busy === 0);
    pulse_start; wait_idle(100000.0);
    ok3 = (cfg_done === 1 && err === 0);
    result(ok && ok2 && ok3 && u_hi.aborted - a0 == 1 && n_exp_abort - i == 1, "T21 reset clock dururken: cikislar clock'suz guvenli");

    // ============================================================ T22
    $display("\n--- T22 1 clock'luk reset");
    a0 = u_hi.aborted; i = n_exp_abort;
    continuous = 1'b1; pulse_start; wait_sv(2, 100000.0);
    wait_f8_cs; #300; @(posedge clk); #2 rst_n = 1'b0; #1;
    ok = outs_reset(0);
    @(posedge clk); #2 rst_n = 1'b1; continuous = 1'b0;
    f0 = u_hi.frames; wait_ns(5000.0);
    ok2 = (u_hi.frames == f0 && busy === 0);
    pulse_start; wait_idle(100000.0);
    ok3 = (cfg_done === 1 && err === 0);
    result(ok && ok2 && ok3 && u_hi.aborted - a0 == 1 && n_exp_abort - i == 1, "T22 1 clock'luk reset");
    exp_abort_win = 1'b0;

    // ============================================================ T23
    $display("\n--- T23 0xF8 byte sirasi");
    cfg_default; lvl = lvl_for(32'h1234_5678, 4'b0000); wait_ns(1500.0);
    pulse_start; wait_idle(100000.0);
    ok = (sense === 32'h1234_5678 && sense[31:24] === 8'h12 && sense[23:16] === 8'h34 &&
          sense[15:8] === 8'h56 && sense[7:0] === 8'h78);
    bank_mode = 4'b1111; lvl = lvl_for(32'h8765_4321, 4'b1111); wait_ns(1500.0);
    pulse_start; wait_idle(100000.0);
    ok2 = (sense === 32'h8765_4321);
    $display("    GND/Open: sense %h (DB3=SO<31:24>=12 ... DB0=78) | Supply/Open: sense %h", 32'h1234_5678, sense);
    result(ok && ok2, "T23 F8 byte sirasi: DB3..DB0 -> sense[31:0] (0x12345678, 0x87654321)");

    // ============================================================ T24
    $display("\n--- T24 arka arkaya iki tek okuma (init politikasi)");
    cfg_default; pulse_start; wait_idle(100000.0);                  // ayarlar uygulanmış olsun
    for (i = 0; i < 32; i = i + 1) lvl[2*i +: 2] = (i < 8) ? 2'b00 : (i < 16) ? 2'b10 : 2'b11;
    wait_ns(1500.0);
    m = u_hi.n_op; mr0 = u_hi.mr_resets; sv0 = n_sv;
    t0 = $realtime; pulse_start; wait_sv(1, 100000.0); d = $realtime - t0; wait_idle(100000.0); s0 = sense;
    for (i = 0; i < 16; i = i + 1) lvl[2*i +: 2] = 2'b01;           // ch0-15 band
    wait_ns(1500.0);
    t0 = $realtime; pulse_start; wait_sv(1, 100000.0); t1 = $realtime - t0; wait_idle(100000.0); s1 = sense;
    // band: IES = 0 (ya da nMR yoksa) önceki durum korunur (00ff); IES = 1 + nMR: latch reset (0000, DS-10)
    e[15:0] = (IES != 0 && HAS_MR != 0) ? 16'h0000 : 16'h00FF;
    ok = (s0[15:0] === 16'h00FF && s1[15:0] === e[15:0] && n_sv - sv0 == 2);
    if (IES == 0)
      ok2 = (u_hi.n_op - m == 2 && count_op(m, 8'hF8) == 2 && u_hi.mr_resets == mr0 && d < 3200.0 && t1 < 3200.0);
    else
      ok2 = (count_op(m, 8'h02) == 2 && u_hi.mr_resets - mr0 == 2 * HAS_MR && d > 15000.0);
    show_ops(m);
    $display("    start -> sense_valid: %0.0f / %0.0f ns | sense[15:0] %h -> band %h (beklenen %h) | nMR %0d",
             d, t1, s0[15:0], s1[15:0], e[15:0], u_hi.mr_resets - mr0);
    result(ok && ok2, "T24 arka arkaya tek okuma: nMR / yazma yok, sure ~ okuma, band durumu korunur");

    // ============================================================ T25
    $display("\n--- T25 iki start arasinda ayar degisimi (yalniz degisen register)");
    cfg_default; lvl = {32{2'b11}}; pulse_start; wait_idle(100000.0);   // hepsi open
    ok = 1;
    for (j = 0; j < 6; j = j + 1) begin
      case (j)
        0: go_c = 6'd10;
        1: go_h = 6'd4;
        2: so_c = 6'd30;
        3: so_h = 6'd10;
        4: bank_mode = 4'b0011;
        default: begin bank_mode = 4'b1100; go_c = 6'd9; go_h = 6'd5; so_c = 6'd35; so_h = 6'd15; end
      endcase
      m = u_hi.n_op; mr0 = u_hi.mr_resets;
      t0 = $realtime; pulse_start; wait_sv(1, 100000.0); d = $realtime - t0; wait_idle(100000.0);
      $display("    adim %0d: start -> sense_valid %0.0f ns", j, d);
      if (IES) begin exp_init; exp_add(8'hF8); end
      else begin
        n_exp_ops = 0;
        case (j)
          0, 1: begin exp_add(8'h3A); exp_add(8'hBA); end
          2, 3: begin exp_add(8'h3C); exp_add(8'hBC); end
          4:    begin exp_add(8'h04); exp_add(8'h84); end
          default: begin exp_add(8'h04); exp_add(8'h3A); exp_add(8'h3C); exp_add(8'h84); exp_add(8'hBA); exp_add(8'hBC); end
        endcase
        exp_add(8'hF8);
      end
      if (!(ops_match(m) && u_hi.mr_resets - mr0 == (IES ? HAS_MR : 0) && err === 0 && cfg_done === 1 &&
            u_hi.psen == {4'h0, bank_mode} && u_hi.gocval == {2'b00, go_c} && u_hi.gohys == {2'b00, go_h} &&
            u_hi.socval == {2'b00, so_c} && u_hi.sohys == {2'b00, so_h} && sense === ref_so(lvl, bank_mode, 32'h0))) begin
        ok = 0; $display("    !! adim %0d", j);
      end
      show_ops(m);
    end
    $display("    son: bank_mode %b -> sense %h | yazma -> F8 en kisa %0.0f ns, settle ihlali %0d",
             bank_mode, sense, u_hi.min_settle, u_hi.e_settle);
    result(ok && u_hi.min_settle >= 2000.0 && u_hi.e_settle == 0,
           "T25 ayar degisimi: nMR yok, yalniz degisen register yazilip geri okunur, settle, yeni ayarla sense");

    // ============================================================ T26
    $display("\n--- T26 yapisal hatadan sonra start: nMR + tam init");
    ok = 1;
    for (j = 0; j < 4; j = j + 1) begin
      cfg_default; continuous = 1'b1; period_us = 16'd10;
      pulse_start; wait_sv(1, 100000.0);
      case (j)
        0: begin wait_f8_cs; force_sync_valid_low; wait_idle(50000.0); release_sync_valid; end
        1: begin wait_f8_cs; force_sync_id(last_sync + 8'd8); wait_idle(50000.0); release_sync_id; end
        2: begin wait_ns(2000.0); @(posedge clk) #1 force_sdi_valid(1'b1); @(posedge clk) #1 release_sdi_valid;
                 wait_idle(10000.0); end
        default: begin wait_f8_cs; force_sdi_valid(1'b0); wait_idle(50000.0); release_sdi_valid; end
      endcase
      ok2 = (err === 1 && err_code === ((j == 0) ? 4'h8 : (j == 1) ? 4'h9 : (j == 2) ? 4'hA : 4'hB) && cfg_done === 0);
      e[3:0] = err_code;
      continuous = 1'b0; m = u_hi.n_op; mr0 = u_hi.mr_resets;
      pulse_start; wait_idle(100000.0);
      exp_init; exp_add(8'hF8);
      ok3 = (ops_match(m) && u_hi.mr_resets - mr0 == HAS_MR && err === 0 && cfg_done === 1);
      $display("    hata kodu %h -> sonraki start: %0d paket, nMR %0d: %0s", e[3:0], u_hi.n_op - m,
               u_hi.mr_resets - mr0, (ok2 && ok3) ? "tam init" : "HATALI");
      if (!(ok2 && ok3)) begin ok = 0; show_ops(m); end
    end
    result(ok, "T26 yapisal hata (8, 9, A, B) sonrasi start: nMR + tam init");

    // ============================================================ T27
    $display("\n--- T27 self-test hatasindan sonra start: nMR + tam init");
    cfg_default; pulse_start; wait_idle(100000.0);
    u_hi.inj_st_bad = 1; pulse_st; wait_idle(200000.0);
    ok = (st_fail === 1 && err === 1 && err_code === 4'h4 && cfg_done === 0);
    m = u_hi.n_op; mr0 = u_hi.mr_resets;
    pulse_start; wait_idle(100000.0);
    exp_init; exp_add(8'hF8);
    ok2 = (ops_match(m) && u_hi.mr_resets - mr0 == HAS_MR && err === 0 && st_fail === 0 && cfg_done === 1);
    show_ops(m);
    result(ok && ok2, "T27 self-test hatasi sonrasi start: nMR + tam init");

    // ============================================================ özet
    $display("\n--- Paket olcumleri (launch = ilk komut kabulu -> SYNC; CS low)");
    $display("    W1 (02/04/1E): %0.0f..%0.0f ns, CS %0.0f..%0.0f | W2 (3A/3C): %0.0f..%0.0f ns, CS %0.0f..%0.0f",
             pk_min[0], pk_max[0], cs_min[0], cs_max[0], pk_min[1], pk_max[1], cs_min[1], cs_max[1]);
    $display("    R1 (82/84/9E): %0.0f..%0.0f ns, CS %0.0f..%0.0f | R2 (BA/BC): %0.0f..%0.0f ns, CS %0.0f..%0.0f",
             pk_min[2], pk_max[2], cs_min[2], cs_max[2], pk_min[3], pk_max[3], cs_min[3], cs_max[3]);
    $display("    F8: %0.0f..%0.0f ns, CS %0.0f..%0.0f (%0d paket)", pk_min[4], pk_max[4], cs_min[4], cs_max[4], pk_n[4]);
    $display("\n--- Genel kontroller");
    $display("    sense hatasi %0d | sense_chg %0d | sense_act %0d | sense_valid genislik %0d | cfg_done'suz sense_valid %0d",
             e_sense, e_chg, e_act, e_svw, e_cfgsv);
    $display("    CS low iken req=0: %0d | err=0 iken err_code/=0: %0d | VERIFY DUT sense hatasi %0d | sense_valid toplam %0d",
             e_req, e_errc, e_sensev, n_sv);
    $display("\n--- HI-8436 timing kontrolleri (model)");
    u_hi.report; u_hiv.report;
    $display("    Iptal edilen cerceve: %0d, beklenen (T20-T22 reset) %0d | VERIFY DUT iptal %0d",
             u_hi.aborted, n_exp_abort, u_hiv.aborted);
    i = u_hi.violations(0) + u_hiv.violations(0);
    result(i == 0 && e_sense == 0 && e_chg == 0 && e_act == 0 && e_svw == 0 && e_cfgsv == 0 && e_req == 0 &&
           e_errc == 0 && e_sensev == 0 && u_hi.aborted == n_exp_abort && u_hiv.aborted == 0,
           "G   genel: model timing ihlali 0, sense/chg/act/req/err_code izleme, iptal yalniz reset testlerinde");
    $display("\nTOPLAM: %0d test gecti, %0d kaldi | timing ihlali=%0d  ->  SONUC: %0s",
             n_pass, n_fail, i, (n_fail == 0 && n_pass == 28) ? "BASARILI" : "BASARISIZ");
    $finish;
  end

  initial begin #60_000_000; $display("ZAMAN ASIMI -> SONUC: BASARISIZ"); $finish; end

endmodule
