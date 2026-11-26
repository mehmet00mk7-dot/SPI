# spi_exec: ADI spi_engine_execution'ın VHDL çevirisi (async reset) + AD7923 driver (async reset)

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
| `rtl/drv/` | AD7923 driver + `ad7923_top.vhd` (core olarak `spi_exec` kullanır). **Async reset** |
| `rtl/drv_sync_ref/` | Async geçişinden önceki sync reset driver'ın kopyası, entity adları `_sref`. Yalnız lockstep referansı; ürün akışına girmez |
| `vendor/adi/` | Orijinal ADI Verilog (read-only, referans) |
| `tb/` | `tb_lockstep.v` (orijinal ↔ VHDL core), `tb_ad7923_drv.v` (driver testleri T01–T22), `tb_drv_lockstep.v` (sync ↔ async driver), AD7923 modeli |
| `sim/` | Çalıştırma script'leri, Questa `.do`, `check_flops.py`, `check_comment_only.py`, sonuç dosyaları, `hash/` (SHA-256 listeleri) |
| `docs/` | `ad7923_spi_blok_diyagram.drawio` (blok diyagram, 5 sayfa) ve onu üreten `gen_drawio.py` |

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

## Driver async reset geçişi (rtl/drv)

Ekip standardı gereği driver da async reset'e geçti. Port'lar, generic'ler ve normal çalışmadaki
davranış aynı; değişen tek şey reset'in tipi. Core (`vendor/adi`, `rtl/async`, `rtl/p1`)
değişmedi (SHA-256 başta/sonda aynı: `sim/hash/`).

**Reset stratejisi.** `rst_n`, projedeki reset synchronizer'dan gelir: async assert, sync
deassert, PLL lock'a bağlı. Driver, ch_regs ve core aynı `rst_n`'den beslenir. Driver ve
ch_regs `rst_n`'yi doğrudan async reset olarak alır. Core'un `resetn`'i `p_core_resetn`
flop'undan gelir: `rst_n` ile async assert edilir, `core_rst` ile bir clock gecikmeli ve
senkron. Bu flop değişmedi. Async reset olarak yalnız `rst_n` kullanılır. `core_rst`,
`fifo_clr`, `per_rst`, cycle timer clear'ı (`frm_launch`) ve power-up timer clear'ı
senkron mantık olarak kaldı.

| Process | Dosya | Register'lar | Reset değeri | Değişiklik |
|---|---|---|---|---|
| p_ctrl | ad7923_drv | state, mask_cur, period_cur, cur_ch, chip_sel, chip_sel_vld, pwr_done, stop_pend, err_r, err_scan, err_cnt, rst_cnt, core_rst_r, frm_pend, frm_dummy, frm_disc, frm_wch, frm_ech, frm_last, frm_derr, frm_go | ST_IDLE, geri kalanı 0 | async kalıba geçti. `frm_go` eskiden reset kontrolünden önce `'0'` atanıyordu (reset'te de 0); artık açıkça reset listesinde |
| p_cyc | ad7923_drv | cyc_cnt | 0 | `rst_n or frm_launch` ayrıldı: rst_n async, frm_launch senkron |
| p_pwr | ad7923_drv | pwr_cnt | 0 | `rst_n or state /= ST_PWR_WAIT` ayrıldı: rst_n async, diğeri senkron |
| p_per | ad7923_drv | per_pre, per_us | 0, 0 | async kalıp; per_rst senkron |
| p_pack | ad7923_drv | pk_st, pk_idx, pk_dummy, pk_wch, sync_id, sdo_r, sdo_valid_r, to_cnt | PK_IDLE, C_PK_CLK_DIV, 0 | async kalıp |
| p_fifo | ad7923_drv | fifo_wr, fifo_rd, fifo_cnt, fifo_mem | 0 | `rst_n or fifo_clr` ayrıldı: rst_n async, fifo_clr senkron |
| p_out | ad7923_drv | data_valid_r, data_ch_r, data_r, data_last_r, rx_err_p | 0 | async kalıp |
| p_regs | ad7923_ch_regs | ch_data_r(0..3), ch_valid_r, scan_done_r | 0 | async kalıp |
| p_core_resetn | ad7923_top | core_resetn | '0' | değişmedi (zaten async) |

Reset'siz bırakılan register yok. Sentez netlist'inde flop sayısı aynı (391 bit), hepsi async reset'li.

**Görünür davranış farkı (yalnız reset anı):** `rst_n` düşer düşmez, clock beklemeden busy, err,
data_valid, data, data_ch, chN_data, chN_valid ve scan_done reset değerine iner, spi_cs_n = '1'
olur. Clock yokken de böyledir. Reset kalktıktan sonra davranış eski sürümle clock'u clock'una
aynı. Driver kendiliğinden başlamaz; start gelince power-up (0xFFFF dummy frame + ≥ 1 µs)
tekrarlanır.

**Doğrulama (ayrıntı: `sim/SONUCLAR.txt` bölüm 4–9):**
- A. `run_ad7923_drv_vhdl.sh` 25.0 / 40.0: mevcut 19 test 19/19, yeni 3 test 3/3, timing ihlali 0.
  Core lockstep (`run_lockstep.sh 16 1 1 0 2 2 1 1 200000`) BAŞARILI.
- B. `run_drv_lockstep.sh`: eski sync driver (`*_sref`) ↔ yeni async driver, her birinin kendi
  AD7923 modeli. Rastgele yasal kontrol girişleri, rastgele rst_n pulse'ları (sync assert, ≥ 8 clk),
  hata enjeksiyonu (frame bozma, ERR_LIMIT burst'ü, SYNC timeout → core_rst, FIFO underflow,
  SYNC id). Her clock'ta bütün çıkışlar ve driver ↔ core arayüzü karşılaştırılır. 3 seed ×
  2.000.000 clock: FARK 0. Kapsama sayaçları: start, stop, continuous, mask değişimi, err,
  core_rst, scan_done ve diğerleri. `run_drv_mutation.sh`: 4 mutation'ın 4'ü de yakalandı
  (reset değeri, eksik reset, soft clear kaybı, ch_regs reset değeri).
- C. Yeni testler (`tb_ad7923_drv.v`):
  - **T20.** Frame ortasında, SCLK aktifken posedge + 3 ns'de `rst_n`. 1 ns'de bütün çıkışlar
    reset değerinde ve spi_cs_n = 1. Kendiliğinden başlamıyor, start ile power-up yeniden.
    Ek olarak data_valid = 1 ve scan_done = 1 iken reset de deneniyor.
  - **T21.** Clock durmuşken (frame ortası) `rst_n`. Çıkışlar ve CS clock olmadan güvenli.
    Clock geri gelince tek tarama ve sürekli tarama çalışıyor.
  - **T22.** 1 clock'luk `rst_n` frame ortasında. Ardından normal tarama.

  Reset'in yarıda kestiği frame'ler yalnız T20–T22'de "beklenen abort" sayılır. Bunun dışında
  kalan her iptal (T18'in kendi 1 iptali hariç) artık global hata. Aynı testler eski sync
  driver ile koşulunca T20–T22 kalıyor.
- D. `run_flop_check.sh` (`check_flops.py`): GHDL synth netlist'inde ad7923_top altındaki 89 flop
  grubunun hepsi `posedge clk or posedge <rst_n'den türeyen>`. Driver, ch_regs ve top'ta reset
  doğrudan ~rst_n. Core'da ~core_resetn (p_core_resetn flop'u, onaylı yol). Düz `posedge clk`
  flop 0.

## Kod yorumları ve blok diyagram

`rtl/drv` (3 dosya) ve `rtl/async` (2 dosya), Türkçe açıklama yorumlarıyla zenginleştirildi
(teknik terimler İngilizce). Eklenenler: genel akış ve blok yapısı, AD7923 kanal pipeline'ı,
komut formatı, SPI zamanlaması, FSM durumları, process ve sinyal açıklamaları.
**Kod değişmedi.** Bunu iki kontrol gösteriyor (`sim/run_comment_check.sh REV`):
- yorumlar atılınca token dizisi ve kod satırları önceki sürümle birebir aynı,
- ad7923_top'un GHDL netlist'i, kaynak satır yorumları hariç birebir aynı.

Testlerin hepsi yeniden koşuldu ve sonuçlar aynı çıktı (`sim/SONUCLAR.txt` bölüm 10).
rtl/async'e yalnız yorum eklendiği için SHA-256'sı değişti; güncel liste
`sim/hash/sha256_yorum.txt` dosyasında. vendor/adi ve rtl/p1 değişmedi.

Blok diyagram: `docs/ad7923_spi_blok_diyagram.drawio` (draw.io / diagrams.net ile açılır).
1. ad7923_top: bağlantılar, reset yolu, AD7923 pin'leri
2. ad7923_drv iç blokları
3. Control FSM ve packer FSM
4. spi_exec control path
5. spi_exec_shiftreg data path

Diyagram `python3 docs/gen_drawio.py` ile yeniden üretilir.

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
./run_ad7923_drv_vhdl.sh 25.0                 # AD7923 driver testleri T01-T22 (T_DOUT 25 ns)
./run_ad7923_drv_vhdl.sh 40.0                 #   ... T_DOUT 40 ns
./run_drv_lockstep.sh 1 2000000               # sync <-> async driver lockstep (SEED CYCLES)
./run_drv_lockstep.sh 2 2000000
./run_drv_lockstep.sh 3 2000000
./run_drv_mutation.sh 400000 1                # driver lockstep mutation (4 hata, hepsi YAKALANDI olmalı)
./run_flop_check.sh                           # netlist yapısal kontrolü (düz posedge clk flop = 0)
./run_comment_check.sh c5e0676               # yalnız yorum değişti mi (token + netlist)
vsim -c -do run_questa_ad7923_drv_vhdl.do     # Questa (resmi koşu; batch'te driver lockstep da)
```
SHA-256 kontrolü (repo kökünden):
`find vendor/adi rtl/async rtl/p1 -type f | sort | xargs sha256sum | diff - sim/hash/sha256_yorum.txt`
(`sha256_bas.txt` / `sha256_son.txt`: async reset geçişinin başı ve sonu; `sha256_yorum.txt`: yorum eklemesinden sonra)
Gerekenler: GHDL (--synth destekli, ≥ 4.x), Icarus Verilog ≥ 12, Python 3.

## Açık işler

- Questa'da `run_questa_ad7923_drv_vhdl.do` koşusu (bu ortamda yalnız GHDL synth → Icarus akışı koştu;
  VHDL kaynağı ayrıca Questa'da doğrudan simüle edilmeli). T20–T22 ve `tb_drv_lockstep.v`'nin
  QUESTA dalı (SignalSpy ile iç sinyal erişimi / force) bu ortamda koşulmadı.
- Libero (Synplify Pro) sentezi: kaynak raporu (LUT/FF) Verilog sürümüyle karşılaştırılacak.
- ~~Driver (ad7923_drv, ch_regs) async reset'e geçişi~~ tamamlandı (yukarıda).
- Driver async geçişi için Libero'da reset ağacı / recovery-removal timing raporu (rst_n
  synchronizer çıkışından bütün flop'lara).
- P2: SLEEP 255 düzeltmesi ve kullanılmayan özelliklerin temizlenmesi (onay sonrası).
- İsteğe bağlı: Yosys + SymbiYosys ile formal equivalence (P1 ↔ orijinal).
