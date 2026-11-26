# AD7923: 4 kanal, 12 bit, 200 kSPS SAR ADC SPI driver'ı

## Amaç
CPU'suz FADEC sensör okuma sisteminin (Microchip PolarFire) SPI tarafında AD7923'ün 4 analog
kanalını tarayan driver. Driver ortak SPI master core'u `common/rtl/async/spi_exec` ile entegreyi
power-up eder, seçilen kanalları sırayla çevirir, her sonucun format ve kanal adresini kontrol
eder ve sonucu düz sinyallerle verir: valid pulse + veri, ayrıca kanal başına kalıcı register.
Board test tarafı driver'ı start, stop ve ayarlarla sürer (AXI yok).

Datasheet: AD7923 Rev. D. PDF bu repo'da yok (açık işler). Model ve RTL referansları Rev. D'nin
tablo ve şekillerine göre (`tb/ad7923_model.v` başlığı).
Blok diyagram: `docs/ad7923_spi_blok_diyagram.drawio` (5 sayfa, `python3 -I docs/gen_drawio.py`).
Sunum notları: `docs/KONUSMA_NOTLARI.md`. Ortak core'un çevirisi ve doğrulaması: `../common/README.md`.

## Dosyalar
| Dosya | İçerik |
|---|---|
| `rtl/ad7923_drv.vhd` | Driver: kontrol FSM'i, kanal seçici, timer'lar, packer, expectation FIFO, RX kontrolü |
| `rtl/ad7923_ch_regs.vhd` | Kanal başına sonuç register'ları (chN_data, chN_valid) ve scan_done |
| `rtl/ad7923_top.vhd` | Driver + ch_regs + `spi_exec` + `p_core_resetn`; gnt = '1' |
| `tb/ad7923_model.v` | AD7923 modeli: kanal pipeline'ı, power-up, DOUT formatı, timing kontrolleri |
| `tb/tb_ad7923_drv.v` | T01–T22 |
| `tb/tb_drv_lockstep.v`, `tb/sync_ref/` | Async geçişinden önceki sync reset driver (referans, ürüne girmez) ↔ güncel driver lockstep'i |
| `sim/run_ad7923_drv_vhdl.sh` | GHDL synth → Icarus. Argüman: `[T_DOUT]` (MISO gecikme köşesi) |
| `sim/run_drv_lockstep.sh`, `sim/run_drv_mutation.sh` | Driver lockstep (sync ref ↔ async) ve mutation (4 hata) |
| `sim/run_flop_check.sh`, `sim/check_flops.py` | Netlist flop yapısı |
| `sim/run_comment_check.sh`, `sim/check_comment_only.py` | "Yalnız yorum değişti" kontrolü (token + netlist) |
| `sim/run_questa_ad7923_drv_vhdl.do` | Questa akışı |
| `sim/SONUCLAR.txt`, `sim/log/` | Sonuçlar; `sim/log/hash_gecmis/` eski SHA listeleri (geçmiş kaydı) |

## Arayüz (`ad7923_top`)
**Girişler** (clk ile senkron)
| Sinyal | Genişlik | Anlam |
|---|---|---|
| clk, rst_n | 1 | 100 MHz; async aktif-düşük reset (reset synchronizer'dan) |
| start | 1 | IDLE'da tarama başlatır (ch_mask ≠ 0000). busy iken yok sayılır |
| stop | 1 | Çalışan frame biter (≤ 1 frame), sonra IDLE |
| continuous | 1 | 1: tarama period_us aralıkla tekrarlanır |
| ch_mask | 4 | Taranacak kanallar; tarama sınırında örneklenir |
| period_us | 16 | Sürekli modda tarama başları arası µs; 0 = beklemesiz |
| range_sel | 1 | AD7923 RANGE: 1 = 0..REFIN, 0 = 0..2×REFIN |
| coding_sel | 1 | AD7923 CODING: 1 = binary, 0 = ikiye tümleyen |

**Çıkışlar**
| Sinyal | Genişlik | Anlam |
|---|---|---|
| data_valid | 1 | 1 clk: data / data_ch geçerli |
| data_ch | 2 | Verinin kanalı |
| data | 12 | 12 bit sonuç (DB11..DB0) |
| ch0..3_data | 12 | Kanal başına son sonuç (kalıcı) |
| ch0..3_valid | 1 | İlgili kanal güncellendi (1 clk) |
| scan_done | 1 | Tarama tamamlandı (1 clk) |
| busy | 1 | IDLE dışı |
| err | 1 | Sticky hata; yeni start ile temizlenir |
| spi_sclk, spi_mosi, spi_cs_n, spi_miso | | AD7923 SCLK (Mode 2, boşta '1'), DIN, CS, DOUT |

**Generic'ler** (top: CLK_DIV, CS_T; diğerleri driver içinde)
| Generic | Varsayılan | Not |
|---|---|---|
| CLK_DIV | 2 | SCLK 16,7 MHz (≤ 20 MHz) |
| CS_T | 1 | CS komutundaki bekleme |
| CLKS_PER_US | 100 | 100 MHz |
| CYCLE_CLKS | 500 | CS düşen kenarları arası ≥ 5 µs (200 kSPS) |
| PWRUP_CLKS | 100 | dummy frame sonrası 1 µs power-up |
| SYNC_TO_CLKS / CORE_RST_CLKS | 1000 / 4 | SYNC timeout 10 µs, core_rst pulse |
| ERR_LIMIT | 4 | art arda hatalı tarama |
| SPI_MODE / WORD_LEN / CS_IDX | 2 / 16 / 0 | Mode 2 (CPOL = 1, CPHA = 0), 16 bit kelime |

## Mimari
```
start/stop/mask --> Control FSM --frm_go--> Command packer --cmd/sdo--> spi_exec --> AD7923
                        ^                        |  ^
                        |                 launch |  | sync (frm_done)
                        |                        v  |
data/data_valid <-- RX checker <-- Expectation FIFO <-- sdi_data <-- spi_exec
       |
       v
ad7923_ch_regs --> chN_data / chN_valid / scan_done
```
- **AD7923 kanal pipeline'ı:** AD7923, CS düşen kenarında bir önceki tam frame'de DIN ile yazılan
  kanalı çevirir. Her ölçüm frame'inde o anki kanal çevrilir (DOUT) ve sıradaki kanal yazılır (DIN).
  Power-up'ta önce 0xFFFF dummy frame + 1 µs, sonra gerekirse select frame gelir; bunların sonucu
  atılır.
- **Expectation FIFO:** Her launch'ta o frame'de dönecek sonucun beklentisi (kanal, son mu, atılacak
  mı) yazılır, sdi geldiğinde okunur.
- **RX checker:** DOUT[15:14] = 00 ve DOUT[13:12] = beklenen kanal olmalı. Aksi veri hatasıdır.

## FSM
| Durum | İş |
|---|---|
| ST_IDLE | start bekler (mask ≠ 0000) |
| ST_PWR_DUMMY / ST_PWR_WAIT | Power-up: DIN = 0xFFFF dummy frame, ardından 1 µs |
| ST_SCAN_START | Tarama tetiği; period referansı sıfırlanır, select gerekir mi |
| ST_SELECT | Select frame: ilk kanal yazılır, sonuç atılır |
| ST_MEAS | Ölçüm frame'leri (her biri bir kanal) |
| ST_SCAN_END | Tarama sınırı: hata sayacı, yeni mask / period örneklenir |
| ST_PERIOD_WAIT | Sürekli modda period bekleme |
| ST_CORE_RST | SYNC timeout sonrası core_rst pulse'ı |

Packer: PK_IDLE → PK_CMD (7 komut) → PK_WAIT (SYNC). Ayrıntı: diyagram sayfa 3.

## Paket (frame)
`2002 2102 2210 11FE 0300 11FF 30nn`: CONFIG clk_div 2, CONFIG mode 2, CONFIG word length 16,
CS aktif, TRANSFER 16 bit okuma + yazma, CS pasif, SYNC id.
- MOSI kelimesi AD7923 control register'ıdır: WRITE = 1, SEQ = 0, ADD = kanal, PM = 11 (normal),
  SHADOW = 0, RANGE, CODING.
- MISO kelimesi: 00, ADD1..0, DB11..DB0.
- Ölçülen (T_DOUT 25 ns): frame 1300 ns, CS low 1120 ns, CS düşen kenarları arası ≥ 5,00 µs.
  4 kanallı tarama ~20 µs.
- Model ölçümü: tSCLK min 60 ns, t2 min 120 ns, t11 min 23 ns, tQUIET min 3880 ns.

## Hatalar
- **Veri hatası** (format / adres): Örnek basılmaz, err sticky, tarama kesilir, sonraki tarama
  select frame ile yeniden hizalanır. Art arda ERR_LIMIT hatalı taramada driver durur.
- **Yapısal hata** (SYNC timeout, SYNC id, FIFO underflow): Driver hemen durur. Timeout'ta core,
  core_rst ile reset'lenir. Sonraki start power-up'ı tekrarlar.
- err yeni start ile temizlenir.

## Reset stratejisi (async reset geçişi)
Ekip standardı gereği driver async reset'e geçti. Port'lar, generic'ler ve normal çalışmadaki
davranış eski sync sürümle aynı; değişen tek şey reset'in tipi.

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

## Entegrasyonda değişen iki satır (`rtl/ad7923_top.vhd`)
1. Component adı: `spi_engine_execution` → `spi_exec`.
2. Core reset'i: `core_resetn <= rst_n and not core_rst` (kombinasyonel) yerine register'lı:
   rst_n ile async assert, `core_rst` ile bir clock gecikmeli senkron. Async reset hattı
   kombinasyonel mantıktan gelmemeli (glitch).

## Doğrulama özeti (ayrıntı: `sim/SONUCLAR.txt`)
| Test | Ne kontrol eder |
|---|---|
| T01–T03 | Power-up (dummy + select) ve 4 kanal; tek tarama 4 frame; select frame sonucu basılmıyor |
| T04–T09 | Sürekli + stop (≤ 1 frame); period 100 µs; period < tarama süresi; mask sınırda uygulanır; mask 0000; çalışan tarama biter |
| T10–T11 | busy iken start yok sayılır; ayar sonraki frame'de geçerli |
| T12–T14 | Format hatası (basılmaz, select ile hizalanır); adres hatası; ERR_LIMIT = 4 → durur |
| T15–T17 | SYNC timeout → core_rst; SYNC id hatası; FIFO underflow (her biri durur, power-up yeniden) |
| T18–T19 | rst_n ile abort + yeniden power-up; mask 0101 → yalnız ch0/ch2, scan_done ch2'de |
| T20–T22 | Async reset: frame ortasında, clock dururken, 1 clock'luk |

- T01–T22: T_DOUT 25 ns ve 40 ns köşelerinde **22/22**, model timing ihlali **0**.
- Driver lockstep (sync ref ↔ async, her clock bütün çıkışlar): 3 seed × 2.000.000 clock, FARK = 0.
- Driver mutation 4/4 yakalandı.
- Flop kontrolü: 89 grup / 391 bit, düz posedge clk 0.
- Yorum kontrolü: RTL'deki yorum değişikliklerinde kod ve netlist aynı (netlist sha 596ae01e…).
- Core'un kendi doğrulaması (lockstep, kısa reset, mutation): `../common/README.md`.

## Çalıştırma
```
cd AD7923/sim
./run_ad7923_drv_vhdl.sh 25.0                 # T01-T22, T_DOUT 25 ns
./run_ad7923_drv_vhdl.sh 40.0                 # T01-T22, T_DOUT 40 ns
./run_drv_lockstep.sh 1 2000000               # sync ref <-> async driver (SEED CYCLES); seed 2, 3 de
./run_drv_mutation.sh 400000 1                # 4 mutation, hepsi YAKALANDI olmalı
./run_flop_check.sh                           # düz posedge clk flop = 0
./run_comment_check.sh c5e0676               # yalnız yorum değişti mi (token + netlist)
vsim -c -do run_questa_ad7923_drv_vhdl.do     # Questa
../../common/sim/run_sha_check.sh             # core değişmezlik
python3 -I ../docs/gen_drawio.py              # blok diyagramı yeniden üret
```
Gerekenler: GHDL ≥ 4 (`--synth`), Icarus Verilog ≥ 12, Python 3.

## Açık işler
| Konu | Durum |
|---|---|
| AD7923 datasheet PDF'i (`docs/datasheet/`) | repo'da yok; yüklenmeli (Rev. D) |
| Questa koşusu (`.do` hazır) | bu ortamda koşulmadı; T20–T22 ve `tb_drv_lockstep.v`'nin QUESTA dalı (SignalSpy) dahil |
| Libero / Synplify sentezi, kaynak raporu (LUT/FF) | yapılmadı |
| Reset ağacı / recovery-removal timing raporu (rst_n synchronizer → bütün flop'lar) | yapılmadı |
| Kart testi | yapılmadı |
| Arbiter (paylaşılan hatta HI-8436'larla) | driver req/gnt hazır; arbiter yazılmadı |
| P2: SLEEP 255 düzeltmesi, kullanılmayan core özelliklerinin temizlenmesi | onay sonrası (core değişikliği) |
| İsteğe bağlı: Yosys + SymbiYosys ile formal equivalence (P1 ↔ orijinal) | – |
