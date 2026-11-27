# common: ortak SPI master core (spi_exec)

Bütün entegre driver'ları (AD7923, HI8436, …) aynı SPI master core'unu kullanır. Core
ADI HDL `hdl_2026_r1` (commit `b62abef`) `spi_engine_execution`'ın VHDL çevirisidir.
Core ilk olarak AD7923 işinde yazıldı; dosyalar oradan buraya değiştirilmeden taşındı.
Çeviri yöntemi ve doğrulama aşağıda; geçmiş koşuların ayrıntılı sonuçları
`../AD7923/sim/SONUCLAR.txt` bölüm 1–3 ve 8–10'da.

**Bu klasördeki core dosyalarına dokunulmaz** (CLAUDE.md kural 1). Her işin başında ve
sonunda `sim/run_sha_check.sh` koşulur ve çıktısı rapora konur.

| Klasör | İçerik |
|---|---|
| `vendor/adi/` | Orijinal ADI Verilog (read-only, SHA-256 kontrollü) |
| `rtl/async/` | **Kullanılan core.** `spi_exec.vhd`, `spi_exec_shiftreg.vhd` (async reset, aktif-düşük `resetn`) |
| `rtl/p1/` | Birebir çeviri (sync reset). Yalnız core lockstep doğrulaması için |
| `tb/` | `tb_lockstep.v`: orijinal Verilog ↔ P1 ↔ async, her clock bütün çıkışlar |
| `sim/` | `run_lockstep.sh`, `run_matrix.sh`, `run_mutation.sh`, `run_sha_check.sh`, `hash/sha256_core.txt`, `SONUCLAR.txt`, `log/` |

| Dosya | SHA-256 |
|---|---|
| vendor/adi/spi_engine_execution.v | f18ed3e82b865d2ab0b4a897d0a0d03584cf5bad0c0ee0422f0dd81d0c83ac86 |
| vendor/adi/spi_engine_execution_shiftreg.v | 70868cc989cda94ffe54bed3e99fa86520bc812980564003c7f64621c9233460 |

Driver'dan kullanım: driver'ın sim script'i core'u `../../common/rtl/async/` yolundan analiz eder
(örnek: `AD7923/sim/run_ad7923_drv_vhdl.sh`, `CORE` değişkeni).

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

## Core doğrulaması

**1) Lockstep (common/sim/run_lockstep.sh, run_matrix.sh).** Orijinal Verilog, P1 ve async sürüm aynı
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

**3) Mutation (common/sim/run_mutation.sh).** VHDL'e bilerek 5 küçük hata konur
(CPHA, last_transfer, SDI_DELAY indeksi, SLEEP karşılaştırması, cs_activate maskesi).
Lockstep hepsini yakalamalı.

## Orijinalden farklar (bilinçli, yalnız reset ile ilgili)

| ID | Fark | Neden |
|---|---|---|
| D1 | Bütün register'lar async reset alıyor (orijinalde cmd_d1, sdo_enabled, sdi_enabled, pending_sdi_data_valid, counter'lar, pin çıkış register'ları, shift register'lar, RX delay line reset'siz) | Ekip standardı; initial value'a ve reset sırasında clock'a bağımlılık yok |
| D2 | Pin çıkışları reset anında güvenli (orijinalde ilk clock kenarında, sclk/sdo/sdo_t için 2 kenar) | Clock yokken de CS pasif |
| D3 | SDI shift register doğrudan resetn ile temizleniyor (orijinalde reset sırasında cs_activate = 1 + clock kenarı) | Async reset'te clock beklenmez |
| D4 | Reset sonrası ilk komuta kadar: orijinalin bazı çıkışları reset'siz register'lara (X / eski değer) bağlı olabilir; async sürümde tanımlı | D1'in sonucu. Lockstep karşılaştırması reset sonrası ilk komuttan (CONFIG) itibaren başlar |

Bilerek **korunan** orijinal davranışlar: SLEEP n = 255 hang, word_length sınır kontrolü yok,
timeout yok, sdi_data latch'lenmiyor. Bunların düzeltilmesi ayrı bir adım (P2) olarak planlı.

## Çalıştırma

```
cd common/sim
./run_sha_check.sh                            # core değişmezlik kontrolü
./run_lockstep.sh 16 1 1 0 2 2 1 1 200000     # DW CS SDI DELAY CFG DIV SDO_DEF SEED CYCLES
./run_matrix.sh 1000000 "1 2 3"               # 8 konfigürasyon x 3 seed (log/ altına)
RST_MODE=1 ./run_matrix.sh 500000 "11 12"     # kısa async reset modu
./run_mutation.sh                             # 5 mutation, hepsi YAKALANDI olmalı
```
Gerekenler: GHDL ≥ 4 (`--synth`), Icarus Verilog ≥ 12, Python 3.
