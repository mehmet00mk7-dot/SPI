// ============================================================================
// hi8436_model.v  -  Holt HI-8436 davranış modeli (32 kanal discrete sensör, SPI slave)
// Kaynak: HI-8436 datasheet DS8436 Rev. L (06/26). "s.N" = sayfa.
//
// Modellenen davranış
//   * SPI Mode 0 (s.4): SI yükselen kenarda örneklenir, SO düşen kenarda T_SO gecikmeyle
//     değişir. İlk 8 bit opcode (MSB önce, bit 7 = R/W', s.4 Fig 4); ardından Tbl 2'deki
//     sayıda veri byte'ı (s.3). Yazmada her byte 8. yükselen kenarında register'a yüklenir
//     (s.4); 2 byte'lık yazmada önce DB1 (hysteresis), sonra DB0 (center) (s.7 Tbl 6).
//     Okumada ilk veri biti 8. opcode bitinden sonraki düşen kenarda çıkar (s.4); SO,
//     okuma byte'ları dışında high-Z'dir, nCS kalkınca T_CHZ sonra yeniden high-Z (s.19).
//   * Register'lar (s.6-8 Tbl 3-7): CTRL, PSEN, GOCENHYS, SOCENHYS, TMDATA; reset değeri
//     0x00 (POR, nMR >= 100 ns, CTRL.SRST). Kullanılmayan bitler UNUSED_STORE = 1 ise
//     saklanır, 0 ise 0 okunur (datasheet belirsiz, DS-3).
//   * Sense (s.9, s.11 Tbl 14, s.2 Fig 2): kanal başına giriş seviyesi sense_lvl[2n+1:2n]:
//       00 = GND / < VTLO, 01 = VTLO..VTHI arası (hysteresis: latch önceki durumu korur),
//       10 = > VTHI (supply), 11 = open.
//     Open: GND/Open bankında high gibi (SO=0), Supply/Open bankında low gibi (SO=1).
//     low -> SO=1, high -> SO=0 (her iki modda; s.9). Giriş değişimi SO'ya T_SENSE
//     gecikmeyle yansır (<= 1 us, s.19).
//   * Test modu (CTRL.TEST, s.6 Tbl 5, s.12): comparator girişleri TMDATA'ya zorlanır.
//     ALL1 = high, ALL0 = low, ODD1/ODD0 = tek girişler high/low (çiftler tersi varsayımı,
//     DS-1), birden fazla bit = hepsi low, hiç bit yok = X. Latch hysteresis'i test
//     modundan çıkışta da geçerlidir (band içindeki kanal test değerini korur, DS-9).
//   * F8 okumasında 32 bit opcode çözüldüğü anda yakalanır (DS-4 belirsiz; model böyle).
//
// Zamanlama kontrolleri (s.19 AC tablo; her ihlal sayılır, report ile basılır)
//   tCYC >= 50, tSCKH >= 20, tSCKL >= 20, tCES >= 5, tCHH >= 5, tCEH >= 5, tCPH >= 55,
//   tDS >= 10, tDH >= 10 ns, tMR >= 100 ns; Mode 0 (nCS kenarlarında SCK = 0);
//   reserved opcode (s.5), fazladan byte / chaining (s.5); settle: yazmadan sonra
//   T_SETTLE içinde başlayan F8 okuması (s.19 "change of threshold <= 1 us");
//   eşik kodları geçersizken test moduna giriş (s.12 "valid threshold values").
//   İptal edilen çerçeve (yarım byte ya da eksik veri byte'ı) ayrıca sayılır (aborted).
//
// Hata enjeksiyonu kancaları
//   inj_rb_flip : 1 = sonraki register okumasında son byte'ın bit 0'ı ters (tek sefer),
//                 2 = her register okumasında
//   inj_rb_op   : /= 0 ise yalnız bu opcode'un sonraki okumasında son byte'ın bit 0'ı ters (tek sefer)
//   inj_st_bad  : 1 = sonraki test modu F8 okumasında bit 5 ters (tek sefer)
//   task por    : POR glitch'i (register'lar 0x00)
// ============================================================================
`timescale 1ns/100ps

module hi8436_model #(
  parameter real    T_SO         = 15.0,    // SCK düşen -> SO (tDV <= 20 ns + kart)
  parameter real    T_CHZ        = 10.0,    // nCS yükselen -> SO high-Z (<= 20 ns)
  parameter real    T_SENSE      = 500.0,   // sense girişi -> SO (<= 1 us)
  parameter real    T_SETTLE     = 1000.0,  // yazma -> geçerli SO (s.19)
  parameter integer UNUSED_STORE = 0
)(
  input         ncs,
  input         sck,
  input         si,
  input         nmr,
  output        so,
  input  [63:0] sense_lvl
);
  // ------------------------------------------------------------- register'lar
  reg [7:0] ctrl = 8'h00, psen = 8'h00, gohys = 8'h00, gocval = 8'h00;
  reg [7:0] sohys = 8'h00, socval = 8'h00, tmdata = 8'h00;
  reg [31:0] so_reg = 32'h0;                 // SO<31:0> (latch çıkışları)

  // ------------------------------------------------------------- SO pini
  reg so_q = 1'b0, so_en = 1'b0;
  assign so = so_en ? so_q : 1'bz;

  // ------------------------------------------------------------- test kancaları
  integer inj_rb_flip = 0;
  integer inj_st_bad  = 0;
  reg [7:0] inj_rb_op = 8'h00;

  // ------------------------------------------------------------- istatistik / log
  integer frames = 0, aborted = 0, writes = 0, mr_resets = 0, por_cnt = 0;
  integer e_tcyc = 0, e_sckh = 0, e_sckl = 0, e_tces = 0, e_tchh = 0, e_tceh = 0, e_tcph = 0;
  integer e_tds = 0, e_tdh = 0, e_tmr = 0, e_mode = 0, e_resv = 0, e_chain = 0, e_settle = 0;
  integer e_tmcfg = 0;
  realtime min_tcyc = 1e9, min_sckh = 1e9, min_sckl = 1e9, min_tces = 1e9, min_tchh = 1e9;
  realtime min_tceh = 1e9, min_tcph = 1e9, min_tds = 1e9, min_tdh = 1e9, min_tmr = 1e9;
  realtime min_settle = 1e9;                 // yazma -> F8 okuması (en kısa)
  reg  [7:0] op_log [0:4095];                // çözülen opcode'lar sırasıyla
  integer    n_op = 0;
  reg  [7:0] last_op = 8'h00;
  integer    n_f8 = 0, n_f8_test = 0, n_f8_norm = 0;
  reg [31:0] last_f8 = 32'h0, last_norm_f8 = 32'h0;   // son F8 / son test-dışı F8 cevabı

  // ------------------------------------------------------------- iç durum
  realtime t_csf = -1e9, t_csr = -1e9, t_rise = -1e9, t_fall = -1e9, t_si = -1e9;
  realtime t_wr = -1e9, t_mrf = 0.0;
  integer  bitc = 0, byte_i = 0, nbytes = 0, rd_pos = 0;
  reg      in_frame = 1'b0, opc_done = 1'b0, is_rd = 1'b0, op_bad = 1'b0, any_rise = 1'b0;
  reg [7:0]  shreg = 8'h0, opc = 8'h0;
  reg [31:0] rd_word = 32'h0;
  reg [63:0] lvl_d = {32{2'b11}};            // gecikmeli giriş seviyeleri

  // opcode -> veri byte sayısı (0 = reserved), s.3 Tbl 2
  function integer op_len(input [7:0] o);
    case (o)
      8'h02, 8'h04, 8'h1E, 8'h82, 8'h84, 8'h9E, 8'h90, 8'h92, 8'h94, 8'h96: op_len = 1;
      8'h3A, 8'h3C, 8'hBA, 8'hBC: op_len = 2;
      8'hF8: op_len = 4;
      default: op_len = 0;
    endcase
  endfunction

  function [7:0] msk(input [7:0] v, input [7:0] m);
    msk = UNUSED_STORE ? v : (v & m);
  endfunction

  // eşik kodu geçerli mi (s.7 Tbl 6 Note)
  function thr_ok(input [7:0] c, input [7:0] h);
    thr_ok = (h[5:0] >= 1) && (c[5:0] + h[5:0] <= 52) && (c[5:0] >= h[5:0] + 4);
  endfunction

  // ilk 10 ihlali zamanıyla basar (hata ayıklama)
  integer n_msg = 0;
  task viol_msg(input [8*8:1] name);
    begin
      if (n_msg < 10) $display("    !! %m: %0s ihlali t=%0t", name, $time);
      n_msg = n_msg + 1;
    end
  endtask

  // ------------------------------------------------------------- reset
  task reg_reset;
    begin
      ctrl = 8'h00; psen = 8'h00; gohys = 8'h00; gocval = 8'h00;
      sohys = 8'h00; socval = 8'h00; tmdata = 8'h00; so_reg = 32'h0;
      eval_so;
    end
  endtask
  task por;   // TB kancası: POR glitch'i
    begin por_cnt = por_cnt + 1; reg_reset; end
  endtask

  // ------------------------------------------------------------- sense değerlendirme
  // Her kanal: etkin giriş (low / band / high / X) -> latch (low: 1, high: 0, band: tut)
  task eval_so;
    integer n, b; reg [1:0] l; reg [1:0] e;   // e: 0 low, 1 band, 2 high, 3 X
    reg [3:0] t;
    begin
      for (n = 0; n < 32; n = n + 1) begin
        b = n / 8;
        if (ctrl[0]) begin
          t = tmdata[3:0];
          case (t)
            4'b0010: e = 2;                          // ALL1
            4'b0001: e = 0;                          // ALL0
            4'b1000: e = (n % 2) ? 2 : 0;            // ODD1 (çiftler low varsayımı)
            4'b0100: e = (n % 2) ? 0 : 2;            // ODD0 (çiftler high varsayımı)
            4'b0000: e = 3;                          // desen yok: tanımsız
            default: e = 0;                          // birden fazla bit: hepsi low
          endcase
        end else begin
          l = lvl_d[2*n +: 2];
          case (l)
            2'b00: e = 0;
            2'b01: e = 1;
            2'b10: e = 2;
            default: e = psen[b] ? 0 : 2;            // open
          endcase
        end
        case (e)
          0: so_reg[n] = 1'b1;
          2: so_reg[n] = 1'b0;
          3: so_reg[n] = 1'bx;
          default: ;                                 // band: önceki durum
        endcase
      end
    end
  endtask

  always @(sense_lvl) lvl_d <= #(T_SENSE) sense_lvl;
  always @(lvl_d or ctrl or tmdata or psen) eval_so;

  // ------------------------------------------------------------- nMR
  // pulse = gerçek 1 -> 0 -> 1 (simülasyon başındaki X -> 1 geçişi pulse değildir)
  reg mr_low = 1'b0;
  always @(negedge nmr) if (nmr === 1'b0) begin t_mrf = $realtime; mr_low = 1'b1; end
  always @(posedge nmr) if (mr_low) begin
    mr_low = 1'b0;
    if ($realtime - t_mrf < min_tmr) min_tmr = $realtime - t_mrf;
    if ($realtime - t_mrf < 100.0) begin e_tmr = e_tmr + 1; viol_msg("tMR"); end
    else begin mr_resets = mr_resets + 1; reg_reset; end
  end

  // ------------------------------------------------------------- nCS düşen
  always @(negedge ncs) if (nmr === 1'b1) begin
    frames = frames + 1;
    if (t_csr > 0.0) begin
      if ($realtime - t_csr < min_tcph) min_tcph = $realtime - t_csr;
      if ($realtime - t_csr < 55.0) begin e_tcph = e_tcph + 1; viol_msg("tCPH"); end
    end
    if (sck !== 1'b0) begin e_mode = e_mode + 1; viol_msg("mode"); end
    t_csf = $realtime; in_frame = 1'b1; opc_done = 1'b0; is_rd = 1'b0; op_bad = 1'b0;
    bitc = 0; byte_i = 0; nbytes = 0; rd_pos = 0; any_rise = 1'b0;
  end

  // ------------------------------------------------------------- nCS yükselen
  reg frm_ok;
  always @(posedge ncs) if (in_frame) begin
    // yarım byte, eksik veri byte'ı ya da saatsiz çerçeve: iptal (s.4)
    frm_ok = !((bitc % 8) != 0 || !opc_done || (!op_bad && byte_i < nbytes));
    if (any_rise) begin
      // ihlal her çerçevede sayılır; ölçülen min yalnız tam çerçevelerden (reset iptalleri hariç)
      if (frm_ok && $realtime - t_rise < min_tchh) min_tchh = $realtime - t_rise;
      if (frm_ok && $realtime - t_fall < min_tceh) min_tceh = $realtime - t_fall;
      if ($realtime - t_rise < 5.0) begin e_tchh = e_tchh + 1; viol_msg("tCHH"); end
      if ($realtime - t_fall < 5.0) begin e_tceh = e_tceh + 1; viol_msg("tCEH"); end
    end
    if (sck !== 1'b0) begin e_mode = e_mode + 1; viol_msg("mode"); end
    if (!frm_ok) aborted = aborted + 1;
    in_frame = 1'b0; t_csr = $realtime;
    so_en <= #(T_CHZ) 1'b0;
  end

  // ------------------------------------------------------------- SCK yükselen
  always @(posedge sck) if (in_frame && ncs === 1'b0) begin
    if (!any_rise) begin
      if ($realtime - t_csf < min_tces) min_tces = $realtime - t_csf;
      if ($realtime - t_csf < 5.0) begin e_tces = e_tces + 1; viol_msg("tCES"); end
    end else begin
      if ($realtime - t_rise < min_tcyc) min_tcyc = $realtime - t_rise;
      if ($realtime - t_fall < min_sckl) min_sckl = $realtime - t_fall;
      if ($realtime - t_rise < 50.0) begin e_tcyc = e_tcyc + 1; viol_msg("tCYC"); end
      if ($realtime - t_fall < 20.0) begin e_sckl = e_sckl + 1; viol_msg("tSCKL"); end
    end
    if ($realtime - t_si < min_tds) min_tds = $realtime - t_si;
    if ($realtime - t_si < 10.0) begin e_tds = e_tds + 1; viol_msg("tDS"); end
    any_rise = 1'b1; t_rise = $realtime;
    shreg = {shreg[6:0], si};
    bitc = bitc + 1;
    if (bitc % 8 == 0) begin
      if (bitc == 8) decode_op(shreg);
      else data_byte(shreg);
    end
  end

  // opcode çözme; okumada cevap kelimesi burada hazırlanır (MSB hizalı)
  task decode_op(input [7:0] b);
    begin
      opc = b; last_op = b; opc_done = 1'b1;
      if (n_op < 4096) op_log[n_op] = b;
      n_op = n_op + 1;
      nbytes = op_len(b);
      if (nbytes == 0) begin begin e_resv = e_resv + 1; viol_msg("resv"); end op_bad = 1'b1; end
      is_rd = b[7];
      rd_word = 32'h0;
      if (!op_bad && is_rd) begin
        case (b)
          8'h82: rd_word = {ctrl, 24'h0};
          8'h84: rd_word = {psen, 24'h0};
          8'h9E: rd_word = {tmdata, 24'h0};
          8'hBA: rd_word = {gohys, gocval, 16'h0};
          8'hBC: rd_word = {sohys, socval, 16'h0};
          8'h90: rd_word = {so_reg[7:0], 24'h0};
          8'h92: rd_word = {so_reg[15:8], 24'h0};
          8'h94: rd_word = {so_reg[23:16], 24'h0};
          8'h96: rd_word = {so_reg[31:24], 24'h0};
          8'hF8: begin
            rd_word = so_reg;
            if ($realtime - t_wr < min_settle) min_settle = $realtime - t_wr;
            if ($realtime - t_wr < T_SETTLE) begin e_settle = e_settle + 1; viol_msg("settle"); end
            if (ctrl[0] && inj_st_bad == 1) begin rd_word[5] = ~rd_word[5]; inj_st_bad = 0; end
            n_f8 = n_f8 + 1; last_f8 = rd_word;
            if (ctrl[0]) n_f8_test = n_f8_test + 1;
            else begin n_f8_norm = n_f8_norm + 1; last_norm_f8 = rd_word; end
          end
        endcase
        // register okumasında bit çevirme kancası (son veri byte'ının bit 0'ı)
        if (b != 8'hF8 && b[7:4] != 4'h9 && inj_rb_flip != 0) begin
          rd_word[32 - 8 * nbytes] = ~rd_word[32 - 8 * nbytes];
          if (inj_rb_flip == 1) inj_rb_flip = 0;
        end
        if (b == 8'h9E && inj_rb_flip != 0) begin
          rd_word[24] = ~rd_word[24];
          if (inj_rb_flip == 1) inj_rb_flip = 0;
        end
        if (inj_rb_op != 8'h00 && b == inj_rb_op) begin
          rd_word[32 - 8 * nbytes] = ~rd_word[32 - 8 * nbytes];
          inj_rb_op = 8'h00;
        end
      end
    end
  endtask

  // veri byte'ı (yazmada register'a yükle)
  task data_byte(input [7:0] b);
    begin
      byte_i = byte_i + 1;
      if (byte_i > nbytes) begin e_chain = e_chain + 1; viol_msg("chain"); end
      else if (!op_bad && !is_rd) begin
        writes = writes + 1; t_wr = $realtime;
        case (opc)
          8'h02: begin
            ctrl = msk(b, 8'h03);
            if (b[1]) reg_reset_keep_srst;
            if (b[0] && !(((psen[3:0] != 4'hF) ? thr_ok(gocval, gohys) : 1'b1) &&
                          ((psen[3:0] != 4'h0) ? thr_ok(socval, sohys) : 1'b1)))
              begin e_tmcfg = e_tmcfg + 1; viol_msg("tm-esik"); end
          end
          8'h04: psen = msk(b, 8'h0F);
          8'h1E: tmdata = msk(b, 8'h0F);
          8'h3A: if (byte_i == 1) gohys = msk(b, 8'h3F); else gocval = msk(b, 8'h3F);
          8'h3C: if (byte_i == 1) sohys = msk(b, 8'h3F); else socval = msk(b, 8'h3F);
        endcase
      end
    end
  endtask

  // SRST = 1: diğer register'lar ve TEST reset'te tutulur (s.6 Tbl 3); model: anında reset,
  // SRST biti saklanır (driver SRST kullanmaz)
  task reg_reset_keep_srst;
    begin
      psen = 8'h00; gohys = 8'h00; gocval = 8'h00; sohys = 8'h00; socval = 8'h00;
      tmdata = 8'h00; ctrl = 8'h02; eval_so;
    end
  endtask

  // ------------------------------------------------------------- SCK düşen
  always @(negedge sck) if (in_frame && ncs === 1'b0) begin
    if (any_rise) begin
      if ($realtime - t_rise < min_sckh) min_sckh = $realtime - t_rise;
      if ($realtime - t_rise < 20.0) begin e_sckh = e_sckh + 1; viol_msg("tSCKH"); end
    end
    t_fall = $realtime;
    if (opc_done && is_rd && !op_bad && bitc >= 8 && rd_pos < 8 * nbytes) begin
      so_q  <= #(T_SO) rd_word[31 - rd_pos];
      so_en <= #(T_SO) 1'b1;
      rd_pos = rd_pos + 1;
    end
  end

  // ------------------------------------------------------------- SI hold
  always @(si) begin
    if (in_frame && ncs === 1'b0 && any_rise) begin
      if ($realtime - t_rise < min_tdh) min_tdh = $realtime - t_rise;
      if ($realtime - t_rise < 10.0) begin e_tdh = e_tdh + 1; viol_msg("tDH"); end
    end
    t_si = $realtime;
  end

  // ------------------------------------------------------------- rapor
  function integer violations(input dummy);
    violations = e_tcyc + e_sckh + e_sckl + e_tces + e_tchh + e_tceh + e_tcph + e_tds + e_tdh +
                 e_tmr + e_mode + e_resv + e_chain + e_settle + e_tmcfg;
  endfunction

  task report;
    begin
      $display("    HI-8436 model: cerceve=%0d yazma=%0d iptal=%0d nMR reset=%0d POR enj.=%0d | F8=%0d (test %0d)",
               frames, writes, aborted, mr_resets, por_cnt, n_f8, n_f8_test);
      $display("      ihlal: tCYC=%0d tSCKH=%0d tSCKL=%0d tCES=%0d tCHH=%0d tCEH=%0d tCPH=%0d tDS=%0d tDH=%0d tMR=%0d",
               e_tcyc, e_sckh, e_sckl, e_tces, e_tchh, e_tceh, e_tcph, e_tds, e_tdh, e_tmr);
      $display("             mode=%0d reserved=%0d chaining=%0d settle=%0d test-esik=%0d  -> toplam %0d",
               e_mode, e_resv, e_chain, e_settle, e_tmcfg, violations(0));
      $display("      olculen min: tCYC %0.1f tSCKH %0.1f tSCKL %0.1f tCES %0.1f tCHH %0.1f tCEH %0.1f tCPH %0.1f tDS %0.1f tDH %0.1f tMR %0.1f ns",
               min_tcyc, min_sckh, min_sckl, min_tces, min_tchh, min_tceh, min_tcph, min_tds, min_tdh, min_tmr);
      $display("      yazma -> F8 okuma en kisa: %0.1f ns (settle siniri %0.0f ns)", min_settle, T_SETTLE);
    end
  endtask

endmodule
