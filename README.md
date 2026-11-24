# spi_exec: ADI spi_engine_execution'ın VHDL çevirisi (async reset)

Kaynak: ADI HDL `hdl_2026_r1`, commit `b62abef`, `spi_engine_execution.v` + `spi_engine_execution_shiftreg.v`.
Orijinal dosyalar `vendor/adi/` altında, değiştirilmeden duruyor:

| Dosya | SHA-256 |
|---|---|
| spi_engine_execution.v | f18ed3e82b865d2ab0b4a897d0a0d03584cf5bad0c0ee0422f0dd81d0c83ac86 |
| spi_engine_execution_shiftreg.v | 70868cc989cda94ffe54bed3e99fa86520bc812980564003c7f64621c9233460 |

## Klasörler

| Klasör | İçerik |
|---|---|
| `rtl/async/` | **Kullanılacak sürüm.** `spi_exec.vhd`, `spi_exec_shiftreg.vhd`: async reset |
| `rtl/p1/` | Ara adım: birebir çeviri, sync reset (`spi_exec_p1*`). Yalnız doğrulama zinciri için |
| `rtl/drv/` | AD7923 driver + `ad7923_top.vhd` (core olarak `spi_exec` kullanır) |
| `vendor/adi/` | Orijinal ADI Verilog (read-only, referans) |
| `tb/` | `tb_lockstep.v` (orijinal ↔ VHDL karşılaştırma), AD7923 driver testbench'i ve modeli |
| `sim/` | Çalıştırma script'leri, Questa `.do`, sonuç dosyaları |

## Nasıl yapıldı

1. **Birebir çeviri (`spi_exec_p1`).** Her Verilog `always` bloğu bir VHDL process'i oldu.
   Process başlarında kaynak satır aralığı yazıyor (ör. `Kaynak: execution.v 270-278`).
   Verilog'un genişlik kuralları (32 bit unsized literal, kırpılan concatenation, büyük shift)
   birebir kopyalandı. Orijinal hatalar da kopyalandı (SLEEP n = 255 hang).
2. **Async reset sürümü (`spi_exec`).** P1'in üzerine:
   - Bütün register'lar `process(clk, resetn)` ile async reset. Initial value yok.
   - Reset değerleri, orijinalin "reset + birkaç clock" sonundaki durumu. Reset kalktıktan
     sonra davranış orijinalle birebir aynı.
   - Pin çıkışları reset anında, clock beklemeden güvenli değerde:
     `cs` hepsi '1', `sclk` = CPOL, `sdo` = SDO_DEFAULT, `sdo_t` = '1'.
3. **ECHO_SCLK.** Desteklenmiyor (bizde 0). VHDL büyük/küçük harf ayırmadığı için
   `ECHO_SCLK` generic'i `echo_sclk` port'uyla çakışıyor; generic yok, davranış ECHO_SCLK = 0.
   Generic/port listesi `ad7923_top`'taki eski component ile aynı.

## Doğrulama

**1) Lockstep (sim/run_lockstep.sh, run_matrix.sh).** Orijinal Verilog, P1 ve async sürüm aynı
girişlerle sürülür; her clock'ta bütün çıkışlar (cmd_ready, sdo_data_ready, sdi_data_valid,
sdi_data, sync_valid, sync, sclk, sdo, sdo_t, cs, three_wire) karşılaştırılır.
- Rastgele ama yasal komut akışı: 5 komut tipinin hepsi, tanımsız kodlar, kullanılmayan
  bitlerde gürültü; SDO/SDI/SYNC backpressure; komutlar arası rastgele boşluk; rastgele reset.
- 8 konfigürasyon: DATA_WIDTH 8/16/24/32, NUM_OF_CS 1/2/4/8, NUM_OF_SDI 1/2, SDI_DELAY 0..3,
  4 SPI modu + three_wire, CLK_DIV 0..3, SDO_DEFAULT 0/1. AD7923 konfigürasyonu dahil.
- Yönlendirilmiş test: SLEEP 255 → üç model de hang (orijinal hata, birebir).

**2) Kısa async reset (RST_MODE=1).** Async core'a 1–2 clock'luk, clock kenarına denk gelmeyen
reset verilir; orijinal uzun reset alır. Kontroller:
- Reset düştükten 0,5 ns sonra async çıkışlar güvenli değerde mi?
- Reset kalktıktan sonra async core orijinalle birebir aynı mı?
- Clock dururken reset: çıkışlar clock olmadan güvenli mi?

**3) Mutation (sim/run_mutation.sh).** VHDL'e bilerek 5 küçük hata konur
(CPHA, last_transfer, SDI_DELAY indeksi, SLEEP karşılaştırması, cs_activate maskesi).
Lockstep hepsini yakalamalı.

**4) AD7923 entegrasyonu (sim/run_ad7923_drv_vhdl.sh).** `ad7923_top` core olarak `spi_exec` ile;
mevcut 19 driver testi + AD7923 timing kontrolleri.

Sonuçlar: `sim/SONUCLAR.txt`.

## Orijinalden farklar (bilinçli, yalnız reset ile ilgili)

| ID | Fark | Neden |
|---|---|---|
| D1 | Bütün register'lar async reset alıyor (orijinalde cmd_d1, sdo_enabled, sdi_enabled, pending_sdi_data_valid, counter'lar, pin çıkış register'ları, shift register'lar, RX delay line reset'siz) | Ekip standardı; initial value'a ve reset sırasında clock'a bağımlılık yok |
| D2 | Pin çıkışları reset anında güvenli (orijinalde ilk clock kenarında, sclk/sdo/sdo_t için 2 kenar) | Clock yokken de CS pasif |
| D3 | SDI shift register doğrudan resetn ile temizleniyor (orijinalde reset sırasında cs_activate = 1 + clock kenarı) | Async reset'te clock beklenmez |
| D4 | Reset sonrası ilk komuta kadar: orijinalin bazı çıkışları reset'siz register'lara (X / eski değer) bağlı olabilir; async sürümde tanımlı | D1'in sonucu. Lockstep karşılaştırması reset sonrası ilk komuttan (CONFIG) itibaren başlar |

Bilerek **korunan** orijinal davranışlar: SLEEP n = 255 hang, word_length sınır kontrolü yok,
timeout yok, sdi_data latch'lenmiyor. Bunların düzeltilmesi ayrı bir adım (P2) olarak planlı.

## Entegrasyonda değişen iki satır (rtl/drv/ad7923_top.vhd)

1. Component adı: `spi_engine_execution` → `spi_exec`.
2. Core reset'i: `core_resetn <= rst_n and not core_rst` (kombinasyonel) yerine register'lı:
   rst_n ile async assert, `core_rst` ile bir clock gecikmeli senkron. Async reset hattı
   kombinasyonel mantıktan gelmemeli (glitch).

## Çalıştırma

```
cd sim
./run_lockstep.sh 16 1 1 0 2 2 1 1 200000     # DW CS SDI DELAY CFG DIV SDO_DEF SEED CYCLES
./run_matrix.sh 1000000 "1 2 3"               # 8 konfigürasyon x 3 seed
RST_MODE=1 ./run_matrix.sh 500000 "11 12"     # kısa async reset modu
./run_mutation.sh
./run_ad7923_drv_vhdl.sh                      # AD7923 driver testleri
vsim -c -do run_questa_ad7923_drv_vhdl.do     # Questa (resmi koşu)
```
Gerekenler: GHDL (--synth destekli, ≥ 4.x), Icarus Verilog ≥ 12, Python 3.

## Açık işler

- Questa'da `run_questa_ad7923_drv_vhdl.do` koşusu (bu ortamda yalnız GHDL synth → Icarus akışı koştu;
  VHDL kaynağı ayrıca Questa'da doğrudan simüle edilmeli).
- Libero (Synplify Pro) sentezi: kaynak raporu (LUT/FF) Verilog sürümüyle karşılaştırılacak.
- Driver (ad7923_drv, ch_regs) async reset'e geçişi (Opus prompt'u hazır).
- P2: SLEEP 255 düzeltmesi ve kullanılmayan özelliklerin temizlenmesi (onay sonrası).
- İsteğe bağlı: Yosys + SymbiYosys ile formal equivalence (P1 ↔ orijinal).
