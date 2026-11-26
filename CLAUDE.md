# SPI driver projeleri: kalıcı talimatlar

Bu repo, Microchip PolarFire üzerinde CPU'suz bir FADEC sensör okuma sisteminin SPI tarafıdır.
Her entegre için bir driver yazılır. Hepsi aynı SPI master core'unu (`spi_exec`) kullanır.

Sistem zinciri: UART Master → Interconnect 1 → Sequencer → Interconnect 2 → **Driver → Arbiter → SPI Master** → Entegre.
Kalın kısım bu reponun kapsamı. Driver'lar AXI değildir. Board test tarafı onları düz sinyallerle sürer
(start, stop, ayarlar). Sonuç da düz sinyal olarak çıkar (valid pulse + veri, gerekiyorsa kalıcı register).

## Repo düzeni

```
CLAUDE.md                 bu dosya
common/                   ortak SPI master core (bütün driver'lar buradan kullanır)
  vendor/adi/             orijinal ADI Verilog (READ-ONLY, SHA-256 kontrollü)
  rtl/async/              spi_exec.vhd, spi_exec_shiftreg.vhd (kullanılan core, async reset)
  rtl/p1/                 birebir çeviri (sync), yalnız core doğrulaması için
  tb/, sim/               core lockstep doğrulaması
<ENTEGRE>/                ör. AD7923/, HI8436/
  rtl/                    <entegre>_drv.vhd, <entegre>_top.vhd, varsa yardımcı bloklar
  tb/                     entegre modeli (Verilog), testbench
  sim/                    run_*.sh, Questa .do, SONUCLAR.txt, log/
  docs/                   datasheet/, blok diyagram (.drawio), konuşma notları
  README.md
```

## Değişmez kurallar

1. **Core'a dokunma.** `common/vendor/adi`, `common/rtl/async` ve `common/rtl/p1` değişmez
   (yerleri `AD7923/` altındaysa orada). Her işin başında ve sonunda SHA-256 al, karşılaştır, rapora koy.
   - spi_engine_execution.v: `f18ed3e82b865d2ab0b4a897d0a0d03584cf5bad0c0ee0422f0dd81d0c83ac86`
   - spi_engine_execution_shiftreg.v: `70868cc989cda94ffe54bed3e99fa86520bc812980564003c7f64621c9233460`
2. **Başka bir entegrenin klasörüne dokunma.** HI8436 üzerinde çalışırken `AD7923/` değişmez.
   Tek istisna: onaylı bir repo düzenleme işi. O durumda da AD7923 testleri tekrar koşulup aynen geçmeli.
3. **Testi geçirmek için testi değiştirme.** Karşılaştırmayı gevşetme, beklenen değeri değiştirme,
   senaryo çıkarma yok. Uyuşmazlıkta önce kök nedeni bul: ilk farklı clock, sinyal, değerler,
   datasheet referansı. Testin kendisi yanlışsa bunu ayrıca açıkla ve onay al.
4. **Faz kapıları.** Her fazın sonunda dur, rapor ver, onay bekle. Durmadan önce commit + push yap.
5. **Datasheet esastır.** Her opcode, register, bit alanı ve timing değeri için datasheet'te
   bölüm/tablo/sayfa referansı ver. Bulamadığın ya da emin olmadığın bilgiyi uydurma; "AÇIK SORU" diye listele.
6. **Kart bilgisi bilinmiyorsa generic yap.** (Bağlantı, eşik değeri, mod, periyot vb.) Varsayılanı ve
   gerekçesini yaz.

## VHDL kodlama kuralları

- VHDL-2008, `ieee.std_logic_1164` + `ieee.numeric_std`. `std_logic_arith` / `std_logic_unsigned` yasak.
- Libero SoC / Synplify Pro ile sentezlenebilir. Emin olunmayan 2008 özelliklerinden kaçın.
- **Async reset, aktif-düşük `rst_n`.** Her clocked process şu kalıpta:
  ```vhdl
  process(clk, rst_n) begin
    if rst_n = '0' then ...bütün register'lar...
    elsif rising_edge(clk) then ...
  ```
  Process'te atanan her register reset listesinde olur. Initial value'a güvenilmez.
  `rst_n` projedeki reset synchronizer'dan gelir (async assert, sync deassert, PLL lock'a bağlı).
- **Türetilmiş async reset yasak.** Async reset olarak yalnız `rst_n` port'u kullanılır. İç soft reset'ler
  (FIFO temizliği, timer sıfırlama, core_rst) senkron mantıktır.
- Core'un reset'i top'ta tek bir flop'tan gelir (`p_core_resetn`: rst_n ile async clear, `D = not core_rst`).
- Latch yok. Kombinasyonel process'lerde her sinyale varsayılan değer.
- Yorumlar Türkçe, teknik terimler İngilizce (trigger, FIFO, state, register, opcode…).
  Her dosyanın başında: amaç, arayüz özeti, RESET STRATEJİSİ, datasheet referansları.
  Her process'in başında kısa bir başlık yorumu.

## Driver mimarisi (AD7923'te kanıtlanmış kalıp)

**Core ile iç arayüz** (bütün driver'larda aynı, arbiter ile uyumlu):

| Sinyal | Yön | Not |
|---|---|---|
| req / gnt | driver ↔ arbiter | Arbiter yoksa top'ta `gnt = '1'`. gnt paket bitene (SYNC) kadar tutulur |
| cmd[15:0] / cmd_valid / cmd_ready | driver → core | Komutlar birer birer yürür |
| sdo_data / sdo_valid / sdo_ready | driver → core | Her yazma kelimesi için bir sdo kelimesi |
| sdi_data / sdi_valid | core → driver | `sdi_data_ready = '1'` sabit: core veriyi latch'lemez |
| sync[7:0] / sync_valid | core → driver | `sync_ready = '1'` sabit. "Paket bitti" |
| core_rst | driver → top | Yalnız SYNC timeout'ta, birkaç clock |

**Paket kalıbı:** `CONFIG clk_div` → `CONFIG mode` → `CONFIG word_length` → `CHIPSELECT (aktif)` →
`TRANSFER`(lar) → `CHIPSELECT (pasif)` → `SYNC id`.
- CONFIG her pakette yeniden yazılır (paylaşılan hatta önceki paket başka entegreye ait olabilir).
- Paketin ilk komutunun kabul edildiği an **launch**'tır: sdo kelimesi hazırlanır, beklenen cevap
  FIFO'ya yazılır, SYNC timeout sayacı başlar.
- SYNC kimliği her pakette artar. Beklenen kimlikle gelen SYNC = paket bitti; diğer her SYNC yapısal hata.
- Bir paketin SYNC'i gelmeden yenisi başlatılmaz.

**Hata sınıfları:**
- *Veri hatası* (cevap formatı/geri okuma uyuşmazlığı): veri basılmaz, `err` sticky; gerekirse yeniden hizalanır.
  Art arda `ERR_LIMIT` hatada durur.
- *Yapısal hata* (SYNC timeout, yanlış SYNC, FIFO underflow): hemen durur, `err = 1`.
  SYNC timeout'ta core'u `core_rst` ile reset'ler (core'un kendi timeout'u yok).
- `err` yeni `start` ile temizlenir. `busy` = IDLE dışındaki her state.
- `stop`: henüz launch olmamış paket iptal edilir; başlamış olan biter (≤ 1 paket).
- `busy` iken gelen `start` yok sayılır.

**Core kullanım kuralları** (spi_exec koddan çıkan):
- SCLK = f_clk / (2 × (clk_div + 1)). 100 MHz, clk_div = 2 → 16,7 MHz.
- Komut kodları ([14:12]): 000 TRANSFER ([9] oku, [8] yaz, [7:0] kelime−1), 001 CHIPSELECT ([9:8] t, [7:0] desen, 0 = seçili),
  010 CONFIG ([9:8]: 00 clk_div, 01 mode: bit0 CPHA, bit1 CPOL, bit3 SDO idle; 10 word_length), 011 MISC ([8]=0 SYNC, 1 SLEEP), 100 CS_INV.
- SLEEP kullanma (n = 255'te kilitlenir). Beklemeler driver'daki timer'larla yapılır.
- Kelime uzunluğu 1…DATA_WIDTH (DATA_WIDTH en fazla 32). Daha uzun çerçeveler birden çok kelimeyle yapılır;
  CS iki CHIPSELECT arasında aktif kalır.
- CPOL yalnız CS pasifken değişir (CONFIG'ler CS'den önce).
- En fazla 8 CS. MISO, pindeki örnekleme kenarından (1 + SDI_DELAY) clock sonra okunur.

## Doğrulama standardı

- Akış: GHDL (`--std=08`, `--synth --out=verilog`) → Icarus Verilog (`-g2012`). Questa için `.do` dosyası da hazırlanır.
- **Entegre modeli** (Verilog, `tb/`): datasheet'teki protokolü (opcode'lar, register'lar, cevap formatı,
  reset/power-up) ve timing kontrollerini (SCLK hızı, CS setup/hold, CS high süresi, SPI modu) uygular.
  Her ihlal sayılır ve raporlanır. Hata enjeksiyonu için test kancaları içerir.
- **Senaryo testleri** T01…Tnn: normal akış, ayar değişiklikleri, stop/start, her hata türü, reset
  (frame ortasında, clock dururken, 1 clock'luk). En az iki timing köşesi (MISO gecikmesi).
- **Mutation:** RTL'e bilerek en az 4 küçük hata konur; testler hepsini yakalamalı.
- **Flop kontrolü:** netlist'te düz `posedge clk` flop'u ve türetilmiş async reset olmamalı.
- Her script başarıda `SONUC: BASARILI` basar, başarısızlıkta non-zero exit code döner.
- Sonuçlar `<ENTEGRE>/sim/SONUCLAR.txt`'ye, loglar `sim/log/`'a.
- Araçlar yoksa kur (ör. `sudo apt-get install -y ghdl iverilog`). GHDL ≥ 4 ve `--synth` desteği gerekir.

## Teslim (her driver için)

- `README.md`: amaç, arayüz tabloları, mimari, nasıl çalışır, doğrulama özeti, açık işler.
- `docs/`: blok diyagram (.drawio), FSM diyagramı, frame/paket zamanlaması; toplantı konuşma notları + soru-cevap.
- `sim/SONUCLAR.txt`, SHA-256 kontrol çıktısı.
- Açık sorular listesi (kart tarafına sorulacaklar).

## Git

- Kalıcı tek branch `main`. Bütün driver'lar main'de kendi klasöründe (`<ENTEGRE>/`), ortak core `common/` altında.
- Çalışma sırasında geçici driver branch'i: `drv/<entegre>` (ör. `drv/hi8436`). Her faz kapısında commit + push.
- İş bitince main'e PR aç; merge'ü kullanıcı yapar (merge commit, squash değil).
  Merge'den sonra driver branch'i silinir (commit'leri main'in geçmişinde kalır).
- Gizli bilgi (anahtar, şifre, kişisel bilgi) commit'leme.
