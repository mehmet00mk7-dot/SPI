# AD7923 driver: konuşma notları

## 60 saniyelik özet
"AD7923, 4 kanallı, 12 bitlik, 200 kSPS bir SAR ADC. Ortak SPI core'umuzla (spi_exec) kanalları
sırayla tarayan bir VHDL driver yazdık. Entegrenin bir özelliği var: CS düştüğünde bir önceki
frame'de yazılan kanalı çeviriyor. Driver bu kanal pipeline'ını yönetiyor; power-up'ta dummy
frame atıyor, gerekirse bir select frame ile hizalıyor. Her sonucun format ve kanal adresini kontrol
ediyor. Sonuç 1 clk'lık valid pulse ile ve kanal başına kalıcı register'larda çıkıyor. Driver önce
sync reset'liydi, ekip standardına göre async reset'e geçirdik. Eski ve yeni sürümü her clock
karşılaştıran bir lockstep ile davranışın aynı kaldığını gösterdik. Doğrulama: datasheet'e göre
yazdığımız bir modele karşı 22 senaryo testi, iki MISO gecikme köşesinde geçti, timing ihlali 0.
Lockstep 3 × 2 milyon clock'ta fark 0, 4 mutation'ın 4'ü yakalandı, netlist'te reset'siz flop yok.
Henüz yapılmayanlar: Questa koşusu, Libero sentezi ve kart testi."

## Bölüm bölüm anlatım

### 1. Entegre ve SPI
- 4 kanal, 12 bit, en fazla 200 kSPS. CS düşen kenarları arası ≥ 5 µs (CYCLE_CLKS = 500).
- SPI Mode 2 (CPOL = 1, CPHA = 0), 16 bitlik frame, SCLK ≤ 20 MHz. CLK_DIV = 2 ile 16,7 MHz.
- MOSI kelimesi control register'ı: WRITE, ADD (sıradaki kanal), PM = 11, RANGE, CODING.
- MISO kelimesi: 00, ADD (çevrilen kanal), DB11..DB0.

### 2. Kanal pipeline'ı (asıl zorluk)
- CS düşünce, bir önceki tam frame'de yazılan kanal çevrilir. Yani N. frame'in sonucu, N−1.
  frame'de seçilen kanaldır.
- Power-up: DIN = 0xFFFF dummy frame (PM = 11), ardından 1 µs.
- Select frame: Taramanın ilk kanalı entegrede seçili değilse bir frame onu seçer, sonucu atılır.
- Expectation FIFO: Her frame'de dönecek sonucun beklentisini tutar (kanal, son mu, atılacak mı).
  Gelen DOUT'un adresi beklenenle karşılaştırılır.

### 3. Driver yapısı (diyagram sayfa 1–3)
- Control FSM, kanal seçici, timer'lar (cycle 5 µs, power-up 1 µs, SYNC timeout 10 µs, period),
  packer (7 komutluk paket), expectation FIFO, RX checker, çıkış register'ı; ayrıca ch_regs.
- Paket: `2002 2102 2210 11FE 0300 11FF 30nn`. Frame 1,3 µs, CS low 1,12 µs.

### 4. Async reset geçişi
- Bütün register'lar `rst_n` ile async reset'li; türetilmiş async reset yok.
- Soft clear'lar (fifo_clr, per_rst, timer clear'ları) senkron mantık olarak kaldı.
- Core reset'i tek flop'tan geliyor (p_core_resetn). Eskiden `rst_n and not core_rst`
  kombinasyonel ifadesiydi; glitch riski yüzünden değişti.
- Reset düşer düşmez, clock beklemeden, çıkışlar güvenli değerde ve CS pasif.
- Kanıt: Eski sync driver'ın kopyası (`tb/sync_ref/`) ile yeni driver her clock karşılaştırılıyor
  (lockstep), fark 0.

### 5. Doğrulama
- Model: kanal pipeline'ı, power-up, DOUT formatı ve timing (fSCLK, tQUIET, 5 µs cycle, t2, t3,
  t11, Mode 2, eksik frame).
- T01–T22: normal tarama, stop, period, mask değişimi, her hata türü, reset (frame ortası, clock
  durmuş, 1 clock). T_DOUT 25 ve 40 ns köşelerinde.
- Driver lockstep: 3 seed × 2.000.000 clock, FARK = 0. Driver mutation: 4/4.
- Flop kontrolü: 89 grup / 391 bit. Yorum kontrolü: RTL'e eklenen yorumlarda kod ve netlist aynı.

## Ezber sayılar
| Ne | Değer |
|---|---|
| SCLK | 16,7 MHz (CLK_DIV = 2), datasheet ≤ 20 MHz |
| Frame | 1,3 µs (launch → SYNC), CS low 1,12 µs |
| Örnekleme | CS düşen kenarları arası ≥ 5,00 µs (200 kSPS), 4 kanal tarama ~20 µs |
| Power-up | 0xFFFF dummy frame + 1 µs |
| SYNC timeout | 10 µs |
| Model ölçümü | tSCLK 60 ns, t2 120 ns, t11 23 ns, tQUIET 3880 ns |
| Test | 22/22, iki köşe (T_DOUT 25 / 40 ns), ihlal 0 |
| Lockstep / mutation | 3 × 2M clock fark 0 / 4/4 |
| Flop | 89 grup / 391 bit, düz flop 0 |

## Gelebilecek sorular

**S: Neden ilk sonuç atılıyor?**
C: AD7923 bir önceki frame'de seçilen kanalı çevirir. Power-up'tan sonraki ilk frame'in ya da
select frame'in sonucu istenen kanala ait değildir; driver bunu FIFO'daki "atılacak" işaretiyle
basmaz.

**S: Adres yanlış gelirse?**
C: Veri basılmaz, err sticky olur, tarama kesilir. Sonraki tarama select frame ile yeniden
hizalanır. Art arda 4 hatalı taramada driver durur.

**S: Async reset geçişi davranışı değiştirdi mi?**
C: Normal çalışmada hayır. Eski sync sürümle her clock karşılaştırıldı, fark 0. Tek fark reset
anında: çıkışlar clock beklemeden reset değerine iniyor ve CS pasif oluyor.

**S: Core'u siz mi yazdınız?**
C: Core, ADI'nin spi_engine_execution Verilog'unun VHDL çevirisi. Orijinalle lockstep'te birebir
karşılaştırıldı. Ayrıntısı `common/README.md`'de; driver'lar ona dokunmuyor.

**S: Questa'da ya da donanımda koştu mu?**
C: Hayır. GHDL'nin sentezlediği netlist Icarus'ta simüle edildi. Questa `.do` hazır ama koşulmadı.
Libero sentezi ve kart testi de yapılmadı.

**S: Datasheet nerede?**
C: Model ve RTL Rev. D'ye göre yazıldı, ama PDF repo'da yok; eklenmesi açık iş.

## Söyleme / söyle
| Söyleme | Söyle |
|---|---|
| "Driver doğrulandı, hazır" | "Modele karşı simülasyonda doğrulandı; Questa, Libero ve kart testi yapılmadı" |
| "Questa'da geçti" | "GHDL netlist + Icarus'ta geçti; Questa `.do` hazır, koşulmadı" |
| "Async reset geçişi hiçbir şeyi değiştirmedi" | "Normal çalışma aynı (lockstep fark 0); reset anında çıkışlar artık clock beklemeden güvenli" |
| "Core'u sıfırdan yazdık" | "Core ADI kodunun VHDL çevirisi, orijinalle lockstep'te birebir" |
| "Gerçek entegrede çalışıyor" | "Datasheet'e göre yazdığımız modelde çalışıyor; kart testi bekliyor" |
| "Paylaşılan hatta HI-8436'larla çalışıyor" | "req/gnt arayüzü hazır; arbiter henüz yazılmadı" |
