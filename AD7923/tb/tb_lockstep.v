`timescale 1ns/100ps
// ---------------------------------------------------------------------------
// tb_lockstep: orijinal ADI spi_engine_execution (Verilog) ile iki VHDL sürümünü
// aynı girişlerle sürer ve her clock'ta bütün çıkışları karşılaştırır.
//   REF : spi_engine_execution        (ADI, değiştirilmemiş)
//   P1  : spi_exec_p1                 (birebir VHDL çeviri, sync reset)
//   AS  : spi_exec                    (async reset VHDL)
// VHDL sürümleri ghdl --synth ile Verilog netlist'e çevrilip burada kullanılır.
//
// Karşılaştırma penceresi: her reset'ten sonra ilk komut (CONFIG yazımı) kabul
// edildikten 4 clock sonra başlar. Neden: orijinalde bazı register'ların reset'i yok
// (cmd_d1, sdo_enabled...). Reset sonrası ilk komuta kadar orijinalin çıkışı bu
// eski/X değerlere bağlı olabilir; async sürüm bunları reset'liyor (bilinçli fark).
// Gerçek kullanımda driver her zaman CONFIG ile başlar.
// ---------------------------------------------------------------------------
module tb_lockstep;
  parameter NUM_OF_CS       = 1;
  parameter DATA_WIDTH      = 16;
  parameter DEFAULT_SPI_CFG = 2;
  parameter DEFAULT_CLK_DIV = 2;
  parameter NUM_OF_SDI      = 1;
  parameter SDO_DEFAULT     = 0;
  parameter SDI_DELAY       = 0;
  parameter SEED            = 1;
  parameter CYCLES          = 200000;
  parameter MUT             = 0;   // 1: mutation koşusu (fark bulunması beklenir)
  parameter RST_MODE        = 0;   // 1: async core'a KISA (1-2 clock) ve clock kenarına denk
                                   //    gelmeyen anda reset; ref/p1 uzun reset alır.
                                   //    Reset anında async çıkışların hemen güvenli olduğu da kontrol edilir.

  localparam W  = DATA_WIDTH;
  localparam SW = NUM_OF_SDI * DATA_WIDTH;

  reg clk = 0;
  reg clk_en = 1;
  always #5 if (clk_en) clk = ~clk;

  reg               resetn = 0;
  reg               resetn_a = 0;   // async core'un reset'i (RST_MODE=0 iken resetn ile aynı)
  integer           a_left = 0, safe_err = 0, safe_chk = 0;
  reg               cmd_valid = 0;
  reg  [15:0]       cmd = 16'h0;
  reg               sdo_data_valid = 0;
  reg  [W-1:0]      sdo_data = 0;
  reg               sdi_data_ready = 1;
  reg               sync_ready = 1;
  reg  [NUM_OF_SDI-1:0] sdi = 0;

  // ---- çıkışlar
  wire r_cmd_ready, p_cmd_ready, a_cmd_ready;
  wire r_sdo_ready, p_sdo_ready, a_sdo_ready;
  wire r_sdi_valid, p_sdi_valid, a_sdi_valid;
  wire [SW-1:0] r_sdi_data, p_sdi_data, a_sdi_data;
  wire r_sync_valid, p_sync_valid, a_sync_valid;
  wire [7:0] r_sync, p_sync, a_sync;
  wire r_sclk, p_sclk, a_sclk, r_sdo, p_sdo, a_sdo, r_sdo_t, p_sdo_t, a_sdo_t;
  wire [NUM_OF_CS-1:0] r_cs, p_cs, a_cs;
  wire r_3w, p_3w, a_3w;

  spi_engine_execution #(
    .NUM_OF_CS(NUM_OF_CS), .DEFAULT_SPI_CFG(DEFAULT_SPI_CFG), .DEFAULT_CLK_DIV(DEFAULT_CLK_DIV),
    .DATA_WIDTH(DATA_WIDTH), .NUM_OF_SDI(NUM_OF_SDI), .SDO_DEFAULT(SDO_DEFAULT[0]),
    .ECHO_SCLK(0), .SDI_DELAY(SDI_DELAY[1:0])
  ) u_ref (
    .clk(clk), .resetn(resetn),
    .cmd_ready(r_cmd_ready), .cmd_valid(cmd_valid), .cmd(cmd),
    .sdo_data_valid(sdo_data_valid), .sdo_data_ready(r_sdo_ready), .sdo_data(sdo_data),
    .sdi_data_ready(sdi_data_ready), .sdi_data_valid(r_sdi_valid), .sdi_data(r_sdi_data),
    .sync_ready(sync_ready), .sync_valid(r_sync_valid), .sync(r_sync),
    .echo_sclk(1'b0), .sclk(r_sclk), .sdo(r_sdo), .sdo_t(r_sdo_t), .sdi(sdi),
    .cs(r_cs), .three_wire(r_3w));

  spi_exec_p1 u_p1 (
    .clk(clk), .resetn(resetn),
    .cmd_ready(p_cmd_ready), .cmd_valid(cmd_valid), .cmd(cmd),
    .sdo_data_valid(sdo_data_valid), .sdo_data_ready(p_sdo_ready), .sdo_data(sdo_data),
    .sdi_data_ready(sdi_data_ready), .sdi_data_valid(p_sdi_valid), .sdi_data(p_sdi_data),
    .sync_ready(sync_ready), .sync_valid(p_sync_valid), .sync(p_sync),
    .echo_sclk(1'b0), .sclk(p_sclk), .sdo(p_sdo), .sdo_t(p_sdo_t), .sdi(sdi),
    .cs(p_cs), .three_wire(p_3w));

  spi_exec u_as (
    .clk(clk), .resetn(resetn_a),
    .cmd_ready(a_cmd_ready), .cmd_valid(cmd_valid), .cmd(cmd),
    .sdo_data_valid(sdo_data_valid), .sdo_data_ready(a_sdo_ready), .sdo_data(sdo_data),
    .sdi_data_ready(sdi_data_ready), .sdi_data_valid(a_sdi_valid), .sdi_data(a_sdi_data),
    .sync_ready(sync_ready), .sync_valid(a_sync_valid), .sync(a_sync),
    .echo_sclk(1'b0), .sclk(a_sclk), .sdo(a_sdo), .sdo_t(a_sdo_t), .sdi(sdi),
    .cs(a_cs), .three_wire(a_3w));

  // ---- karşılaştırma vektörleri
  wire [SW+NUM_OF_CS+20:0] r_vec = {r_cmd_ready, r_sdo_ready, r_sdi_valid, r_sdi_data, r_sync_valid, r_sync,
                                    r_sclk, r_sdo, r_sdo_t, r_cs, r_3w};
  wire [SW+NUM_OF_CS+20:0] p_vec = {p_cmd_ready, p_sdo_ready, p_sdi_valid, p_sdi_data, p_sync_valid, p_sync,
                                    p_sclk, p_sdo, p_sdo_t, p_cs, p_3w};
  wire [SW+NUM_OF_CS+20:0] a_vec = {a_cmd_ready, a_sdo_ready, a_sdi_valid, a_sdi_data, a_sync_valid, a_sync,
                                    a_sclk, a_sdo, a_sdo_t, a_cs, a_3w};

  // ---- handshake'ler (clock kenarındaki değerler)
  reg hs_cmd = 0, hs_sdo = 0;
  always @(posedge clk) begin
    hs_cmd <= cmd_valid & r_cmd_ready;
    hs_sdo <= sdo_data_valid & r_sdo_ready;
  end

  // ---- sayaçlar
  integer seed;
  integer cyc = 0, cmp_cycles = 0, err_p1 = 0, err_as = 0, ref_x = 0;
  integer n_resets = 0, gap = 0, rst_left = 0, cmp_wait = -1;
  reg     first_after_reset = 1, cmp_en = 0;
  integer c_transfer = 0, c_cs = 0, c_wcfg = 0, c_wdiv = 0, c_wlen = 0, c_wnone = 0;
  integer c_sync = 0, c_sleep = 0, c_csinv = 0, c_undef = 0;
  integer c_wait_io = 0, c_sdi_words = 0, c_sync_hs = 0, c_rw[0:3];
  integer stall = 0;
  reg     prev_wait = 0;
  reg [15:0] last_cmd;

  initial begin
    c_rw[0] = 0; c_rw[1] = 0; c_rw[2] = 0; c_rw[3] = 0;
  end

  function integer urand(input integer n);  // 0..n-1
    begin urand = $unsigned($random(seed)) % n; end
  endfunction

  // Yasal rastgele komut üreteci
  function [15:0] gen_cmd(input integer force_cfg);
    integer k, t, n;
    reg [15:0] c;
    begin
      k = force_cfg ? 0 : urand(100);
      if (k < 8) begin                                   // CONFIG
        c = 16'h2100 | urand(16); c_wcfg = c_wcfg + 1;
      end else if (k < 13) begin                         // CLK_DIV
        t = urand(10);
        n = (t < 6) ? urand(4) : (t < 9) ? 7 : urand(21);
        c = 16'h2000 | n; c_wdiv = c_wdiv + 1;
      end else if (k < 20) begin                         // WORD_LENGTH 1..DW
        c = 16'h2200 | (1 + urand(W)); c_wlen = c_wlen + 1;
      end else if (k < 21) begin                         // WRITE, reg = 11 (yok)
        c = 16'h2300 | urand(256); c_wnone = c_wnone + 1;
      end else if (k < 55) begin                         // TRANSFER
        t = urand(4);
        n = (urand(10) < 8) ? urand(4) : urand(16);
        c = (t << 8) | n; c_transfer = c_transfer + 1; c_rw[t] = c_rw[t] + 1;
      end else if (k < 75) begin                         // CHIPSELECT
        c = 16'h1000 | (urand(4) << 8) | urand(256); c_cs = c_cs + 1;
      end else if (k < 85) begin                         // SYNC
        c = 16'h3000 | urand(256); c_sync = c_sync + 1;
      end else if (k < 91) begin                         // SLEEP 0..254
        n = (urand(10) < 8) ? urand(8) : urand(255);
        c = 16'h3100 | n; c_sleep = c_sleep + 1;
      end else if (k < 97) begin                         // CS_INV
        c = 16'h4000 | urand(256); c_csinv = c_csinv + 1;
      end else begin                                     // tanımsız 101..111
        c = ((5 + urand(3)) << 12) | urand(4096); c_undef = c_undef + 1;
      end
      // kullanılmayan bitlere gürültü: bit 15, [11:10]
      if (urand(4) == 0) c = c | (urand(2) << 15) | (urand(4) << 10);
      gen_cmd = c;
    end
  endfunction

  // ---- stimulus ve karşılaştırma: negedge'de
  always @(negedge clk) begin
    cyc = cyc + 1;

    // 1) karşılaştırma (çıkışlar kararlı)
    if (cmp_en) begin
      cmp_cycles = cmp_cycles + 1;
      if (^r_vec === 1'bx) ref_x = ref_x + 1;
      if (r_vec !== p_vec) begin
        err_p1 = err_p1 + 1;
        if (err_p1 <= 5 && !MUT) $display("FARK P1 t=%0t cyc=%0d ref=%h p1=%h last_cmd=%h", $time, cyc, r_vec, p_vec, last_cmd);
      end
      if (r_vec !== a_vec) begin
        err_as = err_as + 1;
        if (err_as <= 5 && !MUT) $display("FARK AS t=%0t cyc=%0d ref=%h as=%h last_cmd=%h", $time, cyc, r_vec, a_vec, last_cmd);
      end
    end

    // coverage
    if (u_ref.wait_for_io && !prev_wait) c_wait_io = c_wait_io + 1;
    prev_wait = u_ref.wait_for_io;
    if (r_sdi_valid && sdi_data_ready) c_sdi_words = c_sdi_words + 1;
    if (r_sync_valid && sync_ready) c_sync_hs = c_sync_hs + 1;

    // hang watchdog
    if (resetn && !r_cmd_ready) stall = stall + 1; else stall = 0;
    if (stall > 300000) begin
      $display("HATA: core 300000 clock boyunca cmd_ready=0 (hang)"); $finish;
    end

    // 2) reset yönetimi
    if (rst_left > 0) begin
      if (RST_MODE == 1 && rst_left == a_left) fork assert_async_late; join_none
      rst_left = rst_left - 1;
      if (rst_left == 0) begin resetn = 1; resetn_a = 1; end
    end else if (cyc > 20 && urand(15000) == 0) begin
      resetn = 0; rst_left = 8 + urand(13); n_resets = n_resets + 1;
      if (RST_MODE == 0) resetn_a = 0; else a_left = 2 + urand(2);  // reset 1..2 clock kenarı sürer
      cmp_en = 0; cmp_wait = -1; first_after_reset = 1;
      cmd_valid = 0; sdo_data_valid = 0;
    end

    if (!resetn) begin
      cmd_valid = 0; sdo_data_valid = 0; sdi_data_ready = 1; sync_ready = 1;
    end else begin
      // 3) komut akışı
      if (hs_cmd) begin
        cmd_valid = 0;
        gap = (urand(2) == 0) ? 0 : urand(4);
        if (first_after_reset) begin first_after_reset = 0; cmp_wait = 4; end
      end
      if (!cmd_valid) begin
        if (gap > 0) gap = gap - 1;
        else begin
          cmd = gen_cmd(first_after_reset); last_cmd = cmd; cmd_valid = 1;
        end
      end
      // 4) SDO veri akışı (valid handshake'e kadar düşmez)
      if (hs_sdo) begin
        sdo_data = $random(seed);
        sdo_data_valid = (urand(4) != 0);
      end else if (!sdo_data_valid) begin
        sdo_data_valid = (urand(2) == 0);
      end
      // 5) diğer girişler
      sdi_data_ready = (urand(100) < 85);
      sync_ready     = (urand(100) < 70);
    end
    sdi = $random(seed);

    if (cmp_wait > 0) begin
      cmp_wait = cmp_wait - 1;
      if (cmp_wait == 0) cmp_en = 1;
    end

    if (cyc >= CYCLES) finish_run;
  end

  // async core'a clock kenarına denk gelmeyen anda reset ver ve çıkışların
  // clock beklemeden güvenli değere gittiğini kontrol et
  task assert_async_late;
    begin
      #(1 + urand(3));
      resetn_a = 0;
      #0.5;
      check_safe;
    end
  endtask

  task check_safe;
    begin
      safe_chk = safe_chk + 1;
      if (a_cs !== {NUM_OF_CS{1'b1}} || a_sclk !== DEFAULT_SPI_CFG[1] || a_sdo !== SDO_DEFAULT[0] ||
          a_sdo_t !== 1'b1 || a_cmd_ready !== 1'b1 || a_sdi_valid !== 1'b0 || a_sync_valid !== 1'b0) begin
        safe_err = safe_err + 1;
        $display("HATA: reset aninda async cikislar guvenli degil t=%0t cs=%b sclk=%b sdo=%b sdo_t=%b",
                 $time, a_cs, a_sclk, a_sdo, a_sdo_t);
      end
    end
  endtask

  // Clock dururken reset: çıkışlar clock olmadan güvenli olmalı
  reg clkstop_ok = 1;
  task clock_stop_test;
    begin
      // önce aktif bir transfer başlat: CHIPSELECT (CS0 aktif) + TRANSFER W, 4 kelime
      @(negedge clk); resetn = 0; resetn_a = 0; cmd_valid = 0; sdo_data_valid = 0;
      sdi_data_ready = 1; sync_ready = 1;
      repeat (10) @(negedge clk);
      resetn = 1; resetn_a = 1;
      @(negedge clk);
      cmd = 16'h1000 | 8'hFE; cmd_valid = 1;
      @(negedge clk); while (!r_cmd_ready) @(negedge clk);
      cmd = 16'h0103; sdo_data_valid = 1;
      @(negedge clk);
      cmd_valid = 0;
      repeat (37) @(negedge clk);
      #2 clk_en = 0;                 // clock durur (clk = 0)
      #20 resetn_a = 0; resetn = 0;
      #1 check_safe;
      if (safe_err != 0) clkstop_ok = 0;
      #50 clk_en = 1;                // clock geri gelir
      repeat (3) @(negedge clk);
      resetn = 1; resetn_a = 1;
      $display("  CLOCK-STOP reset: %s (cs=%b sclk=%b sdo_t=%b)", clkstop_ok ? "OK" : "HATA", a_cs, a_sclk, a_sdo_t);
    end
  endtask

  task finish_run;
    begin
      if (RST_MODE == 1) clock_stop_test;
      // Yönlendirilmiş test: SLEEP 255 (orijinal hata). Üç model de hang olmalı.
      sleep255_test;
      $display("CONFIG DW=%0d CS=%0d SDI=%0d DELAY=%0d CFG=%0d DIV=%0d SDO_DEF=%0d SEED=%0d",
               DATA_WIDTH, NUM_OF_CS, NUM_OF_SDI, SDI_DELAY, DEFAULT_SPI_CFG, DEFAULT_CLK_DIV, SDO_DEFAULT, SEED);
      $display("  cycles=%0d karsilastirilan=%0d reset=%0d | FARK P1=%0d AS=%0d | ref X=%0d | RST_MODE=%0d guvenli-cikis kontrol=%0d hata=%0d",
               cyc, cmp_cycles, n_resets, err_p1, err_as, ref_x, RST_MODE, safe_chk, safe_err);
      $display("  COV transfer=%0d (none=%0d W=%0d R=%0d RW=%0d) cs=%0d cfg=%0d div=%0d wlen=%0d reg11=%0d",
               c_transfer, c_rw[0], c_rw[1], c_rw[2], c_rw[3], c_cs, c_wcfg, c_wdiv, c_wlen, c_wnone);
      $display("  COV sync=%0d sleep=%0d csinv=%0d undef=%0d | wait_for_io=%0d sdi_words=%0d sync_hs=%0d",
               c_sync, c_sleep, c_csinv, c_undef, c_wait_io, c_sdi_words, c_sync_hs);
      if (MUT)
        $display("MUTATION: %s", (err_p1 > 0 || err_as > 0) ? "YAKALANDI" : "YAKALANMADI");
      else if (err_p1 == 0 && err_as == 0 && ref_x == 0 && s255_ok && cmp_cycles > CYCLES/2 &&
               safe_err == 0 && clkstop_ok)
        $display("SONUC: BASARILI");
      else
        $display("SONUC: BASARISIZ");
      $finish;
    end
  endtask

  reg s255_ok = 0;
  task sleep255_test;
    integer k, busy_r, busy_p, busy_a;
    begin
      // reset + config + SLEEP 255
      @(negedge clk); resetn = 0; resetn_a = 0; cmd_valid = 0; sdo_data_valid = 0; sdi_data_ready = 1; sync_ready = 1;
      repeat (10) @(negedge clk);
      resetn = 1; resetn_a = 1;
      @(negedge clk); cmd = 16'h2000; cmd_valid = 1;        // CLK_DIV = 0 (hızlı)
      @(negedge clk); while (!r_cmd_ready) @(negedge clk);
      cmd = 16'h31FF;                                        // SLEEP 255
      @(negedge clk); cmd_valid = 0;
      busy_r = 0; busy_p = 0; busy_a = 0;
      for (k = 0; k < 5000; k = k + 1) begin
        @(negedge clk);
        if (!r_cmd_ready) busy_r = busy_r + 1;
        if (!p_cmd_ready) busy_p = busy_p + 1;
        if (!a_cmd_ready) busy_a = busy_a + 1;
      end
      // SLEEP 254 ~ 255*2 = 510 periyot; 5000 clock'ta bitmesi gerekirdi
      s255_ok = (busy_r == 5000) && (busy_p == 5000) && (busy_a == 5000);
      $display("  SLEEP255: ref/p1/as cmd_ready=0 sureleri %0d/%0d/%0d (5000 = hang, beklenen) -> %s",
               busy_r, busy_p, busy_a, s255_ok ? "OK" : "HATA");
    end
  endtask

  initial begin
    seed = SEED;
    resetn = 0; resetn_a = 0; rst_left = 10;
  end
endmodule
