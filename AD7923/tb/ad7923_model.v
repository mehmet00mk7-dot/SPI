// ============================================================================
// ad7923_model.v  -  AD7923 (4 kanal, 12 bit, 200 kSPS SAR ADC) davranış modeli
// Kaynak: AD7923 datasheet Rev. D (Tablo 5-9, Şekil 20-28)
//
// Modellenen davranış:
//   * CS düşen kenarı dönüşümü başlatır; çevrilen kanal = önceki tam çerçevede
//     yazılan ADD1:ADD0 (ya da sıralayıcı açıksa sıradaki kanal).
//   * DIN, SCLK düşen kenarında okunur; ilk 12 bit kontrol register'ıdır
//     (WRITE=1 ise). Register yalnızca 16 SCLK tamamlanırsa güncellenir.
//   * DOUT = 0,0,ADD1,ADD0,DB11..DB0. İlk bit CS düşüşünden T_EN sonra,
//     sonrakiler her SCLK düşen kenarından T_DOUT sonra çıkar.
//     16. düşen kenardan T_DIS sonra DOUT yüksek empedans olur.
//   * Açılışta güç modu bilinmiyor (kapalı kabul edilir). PM1:PM0=11 yazılan
//     çerçevenin CS yükselen kenarından 1 us sonra dönüşümler geçerli olur.
//     Geçersiz dönüşümde DOUT = 16'hFFFF (biçim hatası olarak yakalanır).
//   * Veri deseni: DB11..0 = {kanal[1:0], ID[1:0], sayaç[7:0]}; sayaç her
//     tamamlanan geçerli dönüşümde o kanal için 1 artar (testbench kontrolü).
//
// Zamanlama kontrolleri (sayaçlar): fSCLK <= 20 MHz, tQUIET >= 50 ns,
//   CS düşenler arası >= 5 us (200 kSPS), t2 >= 10 ns, t3 (DOUT hazır) <= ilk
//   düşen kenar, t11 >= 20 ns, CS düşerken SCLK = 1 (Mod 2), eksik çerçeve.
// ============================================================================
`timescale 1ns/100ps

module ad7923_model #(
  parameter [1:0] ID     = 2'd0,
  parameter real  T_EN   = 35.0,   // t3 maks: CS düşen -> DOUT sürülür
  parameter real  T_DOUT = 25.0,   // SCLK düşen -> yeni DOUT biti (t7=10 min, t4=40 maks)
  parameter real  T_DIS  = 25.0    // t8: 16. düşen kenar -> yüksek empedans
)(
  input  cs_n,
  input  sclk,
  input  din,
  output dout
);
  reg dout_r = 1'bz;
  assign dout = dout_r;

  // Kontrol register'ı durumu
  reg [1:0] sel      = 2'd0;      // bir sonraki dönüşümde çevrilecek kanal
  reg       seq_on   = 1'b0;
  reg [1:0] seq_last = 2'd3;
  reg       rng      = 1'b0;
  reg       cod      = 1'b0;
  reg [1:0] pm       = 2'b00;     // açılışta bilinmiyor -> kapalı kabul
  realtime  t_ready  = 1.0e15;    // bu andan önce başlayan dönüşümler geçersiz

  reg [7:0] cnt [0:3];
  integer   k;
  initial for (k = 0; k < 4; k = k + 1) cnt[k] = 8'd0;

  integer    bitc = 0;
  reg [15:0] sh_out = 16'hFFFF, sh_in = 16'h0;
  reg        conv_valid = 1'b0;
  reg [1:0]  conv_ch = 2'd0;

  // İstatistik ve hata sayaçları
  integer frames = 0, valid_conv = 0, invalid_conv = 0, aborted = 0, writes = 0;
  integer e_sclk = 0, e_quiet = 0, e_cycle = 0, e_t2 = 0, e_t3 = 0, e_t11 = 0, e_cpol = 0;
  realtime t_fall = -1.0e9, t_rise = -1.0e9, t_sfall = -1.0e9;
  realtime min_cycle = 1.0e9, min_quiet = 1.0e9, min_t2 = 1.0e9, min_t11 = 1.0e9, min_tsclk = 1.0e9;

  // ---------------------------------------------------------------- CS düşen
  always @(negedge cs_n) begin
    frames = frames + 1;
    if (frames > 1) begin
      if ($realtime - t_rise < min_quiet) min_quiet = $realtime - t_rise;
      if ($realtime - t_fall < min_cycle) min_cycle = $realtime - t_fall;
      if ($realtime - t_rise < 50.0)   e_quiet = e_quiet + 1;
      if ($realtime - t_fall < 5000.0) e_cycle = e_cycle + 1;
    end
    if (sclk !== 1'b1) e_cpol = e_cpol + 1;
    t_fall     = $realtime;
    bitc       = 0;
    conv_ch    = sel;
    conv_valid = (pm == 2'b11) && ($realtime >= t_ready);
    if (conv_valid) begin
      sh_out = {2'b00, sel, sel, ID, cnt[sel]};
      valid_conv = valid_conv + 1;
    end else begin
      sh_out = 16'hFFFF;
      invalid_conv = invalid_conv + 1;
    end
    dout_r <= #(T_EN) sh_out[15];
  end

  // ------------------------------------------------------- SCLK düşen kenarı
  always @(negedge sclk) begin
    if (cs_n === 1'b0 && bitc < 16) begin
      if (bitc == 0) begin
        if ($realtime - t_fall < min_t2) min_t2 = $realtime - t_fall;
        if ($realtime - t_fall < 10.0) e_t2 = e_t2 + 1;
        if ($realtime - t_fall < T_EN) e_t3 = e_t3 + 1;
      end else begin
        if ($realtime - t_sfall < min_tsclk) min_tsclk = $realtime - t_sfall;
        if ($realtime - t_sfall < 50.0) e_sclk = e_sclk + 1;
      end
      t_sfall = $realtime;
      sh_in   = {sh_in[14:0], din};
      bitc    = bitc + 1;
      if (bitc < 16) dout_r <= #(T_DOUT) sh_out[15 - bitc];
      else           dout_r <= #(T_DIS) 1'bz;
    end
  end

  // ------------------------------------------------------- CS yükselen kenarı
  always @(posedge cs_n) begin
    if (frames > 0) begin
      dout_r <= 1'bz;
      t_rise = $realtime;
      if (bitc < 16) aborted = aborted + 1;     // dönüşüm iptal, register güncellenmez
      else begin
        if ($realtime - t_sfall < min_t11) min_t11 = $realtime - t_sfall;
        if ($realtime - t_sfall < 20.0) e_t11 = e_t11 + 1;
        if (conv_valid) cnt[conv_ch] = cnt[conv_ch] + 1;
        // Kontrol register'ı: b15 WRITE, b14 SEQ1, b11:10 ADD, b9:8 PM, b7 SEQ0, b5 RANGE, b4 CODING
        if (sh_in[15]) begin
          writes = writes + 1;
          rng = sh_in[5];
          cod = sh_in[4];
          if (sh_in[9:8] == 2'b11 && pm != 2'b11) t_ready = $realtime + 1000.0;   // t12 = 1 us
          pm = sh_in[9:8];
          if (sh_in[14] && sh_in[7]) begin            // SEQ1=1, SEQ0=1: 0..ADD sıralı
            seq_on = 1'b1; seq_last = sh_in[11:10]; sel = 2'd0;
          end else if (sh_in[14]) begin               // SEQ1=1, SEQ0=0: sıra sürer
            if (seq_on) sel = (sel == seq_last) ? 2'd0 : sel + 2'd1;
          end else begin                              // SEQ1=0: kanal = ADD
            seq_on = 1'b0; sel = sh_in[11:10];
          end
        end else if (seq_on) sel = (sel == seq_last) ? 2'd0 : sel + 2'd1;
      end
    end
  end

  task report;
    begin
      $display("    AD7923[%0d]: cerceve=%0d gecerli=%0d gecersiz=%0d iptal=%0d | ihlal: fSCLK=%0d tQUIET=%0d 5us=%0d t2=%0d t3=%0d t11=%0d CPOL=%0d",
               ID, frames, valid_conv, invalid_conv, aborted, e_sclk, e_quiet, e_cycle, e_t2, e_t3, e_t11, e_cpol);
    end
  endtask

  function integer violations;
    input dummy;
    violations = e_sclk + e_quiet + e_cycle + e_t2 + e_t3 + e_t11 + e_cpol;
  endfunction
endmodule
