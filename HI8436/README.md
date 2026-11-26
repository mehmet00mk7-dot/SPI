# HI8436: Holt HI-8436 (32 kanal discrete sensör) SPI driver'ı

## Amaç
CPU'suz FADEC sensör okuma sisteminin (Microchip PolarFire) SPI tarafında, HI-8436'nın 32 discrete
girişini okuyan driver. Driver ortak SPI master core'u `common/rtl/async/spi_exec` ile entegreyi
programlar, geri okuyarak doğrular, 32 bitlik sense kelimesini okur, periyodik olarak register'ları
doğrular (POR tespiti) ve istendiğinde dahili self-test yapar. Board test tarafı driver'ı düz
sinyallerle sürer; sonuç düz sinyal olarak döner (AXI yok).

Datasheet: `docs/datasheet/HI-8436.pdf` (DS8436 Rev. L). Analiz ve onaylı arayüz: `docs/ANALIZ.md`.
Blok diyagram: `docs/hi8436_blok_diyagram.drawio` (6 sayfa, `python3 -I docs/gen_drawio.py` ile üretilir).
Sunum notları: `docs/KONUSMA_NOTLARI.md`.

## Dosyalar
| Dosya | İçerik |
|---|---|
| `rtl/hi8436_drv.vhd` | Driver: kontrol FSM'i, paket tanımı, packer, timer'lar, init politikası, çıkış register'ı |
| `rtl/hi8436_top.vhd` | Driver + `spi_exec` + `p_core_resetn`; gnt = '1', sdi_data_ready = sync_ready = '1' |
| `tb/hi8436_model.v` | HI-8436 modeli: protokol, register'lar, sense / hysteresis / test modu, AC timing kontrolleri, hata kancaları |
| `tb/tb_hi8436_drv.v` | T01–T28 + G (genel kontroller) |
| `sim/run_hi8436_drv_vhdl.sh` | GHDL synth → Icarus. `[T_SO] [DATA_WIDTH] [RTL] [UNUSED_STORE] [HAS_MR] [INIT_EVERY_START]` |
| `sim/run_flop_check.sh`, `sim/check_flops.py` | Netlist flop yapısı (düz posedge clk / türetilmiş async reset) |
| `sim/run_drv_mutation.sh` | 12 mutation + sync reset negatif kontrolü |
| `sim/run_questa_hi8436_drv_vhdl.do` | Questa akışı (VHDL kaynak doğrudan) |
| `sim/SONUCLAR.txt`, `sim/log/` | Sonuçlar, SHA-256 kontrol çıktısı |
| `docs/ANALIZ.md`, `docs/analiz/` | Faz 1 analizi, paket zamanlama ölçümü |

## Arayüz (`hi8436_top`)
**Girişler** (clk ile senkron)
| Sinyal | Genişlik | Anlam |
|---|---|---|
| clk, rst_n | 1 | 100 MHz; async aktif-düşük reset (reset synchronizer'dan) |
| start | 1 | IDLE'da: ayarlar latch'lenir; init politikasına göre tam init / kısmi güncelleme / doğrudan okuma. busy iken yok sayılır |
| stop | 1 | Launch olmamış paket iptal, başlamış paket biter (≤ 1 paket), sonra IDLE. Self-test sırasında ertelenir |
| continuous | 1 | 1: okuma period_us aralıkla tekrarlanır; 0: start başına bir okuma |
| period_us | 16 | F8 okuma launch'ları arası µs (her okumada örneklenir). 0 ya da < 2,8 µs: arka arkaya |
| bank_mode | 4 | PSEN<3:0>: bit n = 1 → bank n Supply/Open (s.6 Tbl 4) |
| go_center / go_hyst | 6 / 6 | GND/Open eşiği: center 0,1 V/LSB, hysteresis 0,2 V/LSB (s.7 Tbl 6) |
| so_center / so_hyst | 6 / 6 | Supply/Open eşiği (s.8 Tbl 7) |
| self_test_req | 1 | IDLE'da: (gerekirse init) + self-test, start yoksa okuma yok. Çalışırken: sıradaki okuma yerine |

**Çıkışlar**
| Sinyal | Genişlik | Anlam |
|---|---|---|
| sense | 32 | Son okuma, ham SO<31:0> (kalıcı register) |
| sense_valid | 1 | 1 clk: sense / sense_chg / sense_act yeni |
| sense_chg | 32 | yeni sense xor önceki sense (reset sonrası 0'a göre) |
| sense_act | 32 | normalize: 1 = aktif (GND/Open'da toprak, Supply/Open'da besleme var) |
| cfg_done | 1 | init_done: entegre programlı, geri okumayla doğrulandı, içeriği biliniyor |
| busy | 1 | IDLE dışı |
| err / err_code | 1 / 4 | Sticky; ilk hata (aşağıda). start / self_test_req ile temizlenir |
| st_done / st_fail | 1 / 1 | Self-test bitti (1 clk) / başarısız (sticky) |
| spi_sclk, spi_mosi, spi_cs_n, spi_miso, spi_mr_n | | HI-8436 SCK, SI, nCS, SO, nMR |

**Generic'ler**
| Generic | Varsayılan | Not |
|---|---|---|
| CLKS_PER_US | 100 | 100 MHz |
| CLK_DIV | 2 | SCLK 16,67 MHz (≤ 20 MHz, s.19 tCYC ≥ 50 ns) |
| CS_T | 1 | tCEH / tCPH marjı |
| DATA_WIDTH | 8 | core kelime genişliği 8..32 (paylaşılan core 16/32 test edildi) |
| SDI_DELAY | 0 | MISO örnekleme ek gecikmesi |
| HAS_MR | true | nMR bağlı değilse false |
| MR_CLKS / MR_WAIT_CLKS | 20 / 100 | nMR 200 ns (≥ 100), sonrası 1 µs bekleme |
| SETTLE_CLKS | 200 | yazma → F8 en az 2 µs (s.19 ≤ 1 µs) |
| SYNC_TO_CLKS / CORE_RST_CLKS | 1000 / 4 | SYNC timeout 10 µs, core_rst pulse |
| ERR_LIMIT | 4 | art arda veri hatası |
| VERIFY_EVERY | 16 | her 16 okumada bir register doğrulaması (POR tespiti); 0 = kapalı |
| INIT_EVERY_START | false | true: her start'ta nMR + tam init (eski davranış) |
| CFG_FROM_GENERIC | false | true: ayarlar DEF_* generic'lerinden (kart testi) |
| DEF_BANK_MODE / DEF_GO_* / DEF_SO_* | 0 / 9,5 / 35,15 | GND/Open 1,4 / 0,4 V (`3A 05 09`), Supply/Open 5,0 / 2,0 V (`3C 0F 23`) |

## Mimari
```
start/stop/ayar --> Control FSM --frm_go + paket tanımı--> Packer --cmd/sdo--> spi_exec --> HI-8436
  (latch, shadow)      ^                                    |  ^
                       |                      pk_ok (SYNC)  |  | sdi / sync
sense, sense_chg <-- Output reg <-- rx_sh <-----------------+--+
```
- **Control FSM (p_ctrl)**: init politikası, init / güncelleme, geri okuma karşılaştırması, settle,
  self-test, okuma döngüsü, periyodik doğrulama ve hata yönetimi.
- **Paket tanımı (p_dsc)**: state ve adım → opcode, byte sayısı, yazılacak veri, beklenen geri okuma.
- **Packer (p_pack, p_cmd)**: core komutlarını üretir, sdo byte kuyruğunu, SYNC id'yi, SYNC timeout'u
  ve beklenen sdi kelime sayısını yönetir. Her paket = tek CS çerçevesi = tek HI-8436 instruction
  (s.5: chaining yok).
- **Timer'lar**: settle (yazma SYNC'inden), period (okuma launch'ından, 4 clk gecikme telafili),
  SYNC timeout, nMR.
- **Çıkış register'ı (p_out)**: sense, sense_chg, sense_act, sense_valid.
- Her byte bir core kelimesi (word_length = 8): sdo kelimesi = byte, sdi'nin [7:0]'ı kullanılır.
  Bu yüzden core'un DATA_WIDTH'inden bağımsızdır.

## FSM
| Durum | İş | Çıkış |
|---|---|---|
| ST_IDLE | start / self_test_req bekler, ayarları latch'ler, eşik kodlarını kontrol eder | init politikasına göre MR_PULSE / CFG_WR / SETTLE |
| ST_MR_PULSE, ST_MR_WAIT | nMR 200 ns, sonra 1 µs | CFG_WR |
| ST_CFG_WR | upd maskesindeki register'ları yazar | CFG_RD |
| ST_CFG_RD | upd'dekileri geri okur, tam byte karşılaştırır (vfy = 1: periyodik doğrulama, 5 register) | eşleşti: SETTLE (ya da doğrulamadan sonra PERIOD / TEST / IDLE); uyuşmazlık: tam init ya da IDLE (ERR_LIMIT) |
| ST_SETTLE | son yazmadan beri 2 µs | TEST (st_pend) / READ |
| ST_TEST | self-test alt adımları | SETTLE / IDLE |
| ST_READ | F8 okuma | PERIOD / CFG_RD (doğrulama) / TEST / IDLE |
| ST_PERIOD | period bekleme | READ / TEST / IDLE (stop) |
| ST_CORE_RST | SYNC timeout sonrası core_rst 4 clk | IDLE |

Yapısal hata her durumdan önceliklidir. Ayrıntı: diyagram sayfa 4.

## Init politikası (`INIT_EVERY_START = false`)
Driver, entegreye son yazdığı ve geri okumayla doğruladığı ayarları shadow register'larda tutar
(`init_done` = `cfg_done`). start'ta:

| Durum | nMR | Yazma / geri okuma | Sonra | start → sense_valid |
|---|---|---|---|---|
| rst_n sonrası ilk start | evet (HAS_MR) | 5 register yazılır, 5'i geri okunur | settle, okuma | 19,3 µs (HAS_MR = false: 18,1) |
| Yapısal hata (8 / 9 / A / B) sonrası | evet | tam | settle, okuma | 19,3 µs |
| Geri okuma hatası, ERR_LIMIT ile durma sonrası | evet | tam | settle, okuma | 19,3 µs |
| Periyodik doğrulama uyuşmazlığı (kod 3, POR) | evet (hemen) | tam | okuma sürer | – |
| Self-test başarısız olduktan sonra | evet | tam | settle, okuma | 19,3 µs |
| Yazma dizisi stop ile yarıda kesildiyse | evet | tam | settle, okuma | 19,3 µs |
| init_done = 1, bank_mode / eşik(ler) farklı | **hayır** | yalnız değişen PSEN / GOCENHYS / SOCENHYS | settle, okuma | 6,2–6,7 µs (tek register), 12,8 µs (üçü) |
| init_done = 1, ayarlar aynı | **hayır** | yok | doğrudan okuma | 2,8 µs |
| Geçersiz eşik kodu | – | yok (start reddedilir, kod 1) | IDLE, init_done değişmez | – |

Kısmi güncellemenin geri okuması tutmazsa entegre içeriği bilinmez sayılır, tam init ile yeniden
denenir. `INIT_EVERY_START = true`: her start'ta nMR + tam init.

### Periyodik doğrulama ve POR tespiti (VERIFY_EVERY = 16)
- Ayarlar aynıyken start doğrudan okumaya gittiği için, entegre POR / besleme kesintisiyle 0x00'a
  dönerse bunu yalnız periyodik doğrulama fark eder.
- Her 16 F8 okumada bir, okumanın hemen ardından 5 register (82, 84, BA, BC, 9E) geri okunur. Eşik
  register'ları (GOCENHYS, SOCENHYS) her turda okunur. Geçerli bir eşik kodu asla 0x00 değildir
  (HYS ≥ 1), POR kesin yakalanır. CTRL / TMDATA tek başına yetmez: reset değerleri programlanan
  değerle aynıdır.
- Sayaç start'lar arasında sıfırlanmaz: tek okuma kullanımında (start başına bir okuma) da çalışır.
  Başarılı bir init / güncelleme geri okumasında 0'lanır. stop ile kesilen doğrulama kaybolmaz.
- Uyuşmazlık: err, kod 3, init_done = 0, hemen nMR + tam init; okumalar devam eder.
- **POR tespit gecikmesi = en fazla VERIFY_EVERY okuma**, yani VERIFY_EVERY × okuma periyodu.
  - Sürekli modda period_us = 1000 için ≤ 16 ms. Arka arkaya okumada ≤ 16 × 2,8 µs + doğrulama.
  - Tek okuma kullanımında ≤ 16 start.
  - T28'de ölçülen: sürekli 13, 2 ve 16 okuma (16 = POR doğrulamadan hemen sonra, en kötü durum);
    tek okumada 12. start.
- Doğrulama maliyeti: 16 okumada bir ≈ 7,6 µs (5 geri okuma paketi).
- **VERIFY_EVERY = 0'ın riski:** POR / besleme kesintisinden sonra entegre reset değerleriyle çalışır.
  Bütün banklar GND/Open olur, eşik kodları 0 (geçersiz) kalır. Driver bunu fark etmez ve anlamsız
  sense verisini geçerli diye vermeye devam eder (sense verisinde parity yok). Ancak bir hata, rst_n
  ya da ayar değişikliği tam init'i tetikler. Kapatılacaksa sistem tarafı periyodik self-test ya da
  stop / rst_n ile yeniden init planlamalıdır.

## Paket türleri (CLK_DIV = 2, CS_T = 1; ölçülen)
Ortak başlık `2002 2100 2208 11FE` (CONFIG clk_div, CONFIG mode 0, CONFIG word length 8, CS aktif),
ortak son `11FF 30nn` (CS pasif, SYNC id).

| Paket | Opcode'lar | Orta komutlar | sdo kelimeleri | SCK | CS low | launch → SYNC |
|---|---|---|---|---|---|---|
| Yazma 1 byte | 02 CTRL, 04 PSEN, 1E TMDATA | `0101` | op, DB0 | 16 | 1120 ns | 1300 ns |
| Yazma 2 byte | 3A GOCENHYS, 3C SOCENHYS | `0102` | op, DB1 (hyst), DB0 (center) | 24 | 1600 ns | 1780 ns |
| Okuma 1 byte | 82, 84, 9E | `0100 0200` | op | 16 | 1140 ns | 1320 ns |
| Okuma 2 byte | BA, BC | `0100 0201` | op | 24 | 1620 ns | 1800 ns |
| Read All Banks | F8 | `0100 0203` | op | 40 | 2580 ns | 2760 ns |

- F8 cevabı DB3..DB0 = SO<31:24>..SO<7:0> → sense[31:0] (s.10 Tbl 12, T23).
- Arka arkaya okuma aralığı 2800 ns, yani ≈ 357 kHz.
- Ölçülen en dar timing değerleri: tCYC 60 (≥ 50), tSCKH/L 30 (≥ 20), tCES 120, tCHH 100, tCEH 70
  (≥ 5), tCPH 210 (≥ 55), tDS/tDH 30 (≥ 10), tMR 200 (≥ 100) ns.
- MISO: SO, SCK düşen kenarından < 40 ns içinde değişmeli (t_DV ≤ 20 ns + kart/IO ≤ 20 ns).

## Register ayarları
| Register | Opcode W / R | Driver'ın yazdığı | Kaynak |
|---|---|---|---|
| CTRL | 02 / 82 | 00 (init), 01 (self-test TEST=1), 00 (çıkış) | s.6 Tbl 3 |
| PSEN | 04 / 84 | 0000 & bank_mode | s.6 Tbl 4 |
| GOCENHYS | 3A / BA | DB1 = 00 & go_hyst, DB0 = 00 & go_center | s.7 Tbl 6 |
| SOCENHYS | 3C / BC | DB1 = 00 & so_hyst, DB0 = 00 & so_center | s.8 Tbl 7 |
| TMDATA | 1E / 9E | 00 (init), 02 ALL1 / 01 ALL0 (self-test), 00 (çıkış) | s.6 Tbl 5 |

- Eşik: VTHI = 0,1 V × (CVAL + HYS), VTLO = 0,1 V × (CVAL − HYS).
- Geçerlilik (yalnız kullanılan mod için): HYS ≥ 1, CVAL + HYS ≤ 52, CVAL − HYS ≥ 4. Aksi halde start
  reddedilir (kod 1).
- Kullanılmayan bitlere 0 yazılır, geri okumada tam byte karşılaştırılır.
- Polarite (s.9, s.11 Tbl 14):
  - GND/Open bankında SO = 1 toprak demektir.
  - Supply/Open bankında SO = 1 açık, SO = 0 besleme var demektir.
  - `sense_act` bu farkı normalize eder.
- Self-test: ALL1 → F8 = 0x00000000, ALL0 → 0xFFFFFFFF (bank modundan bağımsız).

## Hata kodları
| err_code | Ad | Sınıf | Davranış |
|---|---|---|---|
| 1 | CFG_RANGE | parametre | start reddedilir, SPI trafiği yok |
| 2 | RB_MISMATCH | veri | init / güncelleme geri okuması uyuşmuyor → tam init ile tekrar, ERR_LIMIT kez → durur |
| 3 | VERIFY_MISMATCH | veri | periyodik doğrulamada uyuşmazlık (POR) → hemen tam init |
| 4 | SELFTEST_FAIL | veri | self-test sonucu yanlış → test modundan çıkılır, durur |
| 8 | SYNC_TIMEOUT | yapısal | SYNC 10 µs içinde gelmedi → core_rst, durur |
| 9 | SYNC_ID | yapısal | beklenmeyen / yanlış id'li SYNC → durur |
| A | SDI_UNEXPECTED | yapısal | beklenmeyen sdi kelimesi (FIFO underflow karşılığı) → durur |
| B | SDI_MISSING | yapısal | SYNC geldi, sdi kelimesi eksik → durur |

err ve err_code ilk hatayı tutar. Yapısal hata ve kod 2/3/4 sonrası init_done = 0, yani sonraki start
tam init yapar. Sense okumasında veri kontrolü yoktur: 32 bitin hepsi veridir.

## Kullanım notları
- **DS-9 (self-test sonrası hysteresis):** Test modu comparator latch'lerini zorlar. VTLO–VTHI bandı
  içindeki bir giriş, test modundan çıkınca son test değerini korur (ALL0 → SO = 1). Datasheet test
  modundan çıkarken ve yeniden programlarken girişlerin net high/low olmasını ister (s.11, s.12
  NOTE). Self-test'i ve ayar değişikliğini girişlerin bandda olmadığı bir anda verin. (T13)
- **DS-10 (nMR ve hysteresis):** nMR'ın latch'i sıfırlayıp sıfırlamadığı datasheet'te açık değil;
  model sıfırlandığını varsayar. Politika ile nMR yalnız açılışta ve hata sonrasında verilir. Normal
  kullanımda band içindeki kanallar durumunu korur (T24). Etki, açılış ve hata sonrası ilk okumayla
  sınırlıdır.

## Doğrulama özeti (ayrıntı: `sim/SONUCLAR.txt`)
- **T01–T28 + G:** Bütün köşelerde **29/29**, model timing ihlali **0**. Köşeler: T_SO 5 / 35 ns,
  DATA_WIDTH 16 / 32, HAS_MR = false, UNUSED_STORE = 1, INIT_EVERY_START = true (5 / 35 ns, nMR'sız).
  Negatif köşe T_SO = 45 ns beklendiği gibi başarısız.
- Ana DUT'ta periyodik doğrulama kapalı (deterministik paket sayımı için). İkinci DUT varsayılan
  generic'lerle çalışır ve T14 / T28'i koşar.
- **Flop kontrolü:** 100 grup / 505 bit, düz posedge clk 0, türetilmiş async reset 0.
- **Mutation:** 12/12 yakalandı. Negatif kontrol: sync reset kopyasında T20–T22 kalıyor, flop kontrolü
  başarısız.
- Core SHA-256 başta ve sonda aynı; `AD7923/` ve `common/` değişmedi.

## Çalıştırma
```
cd HI8436/sim
./run_hi8436_drv_vhdl.sh 5.0                  # hızlı köşe (T_SO = 5 ns)
./run_hi8436_drv_vhdl.sh 35.0                 # yavaş köşe
./run_hi8436_drv_vhdl.sh 35.0 16              # paylaşılan core, DATA_WIDTH 16
./run_hi8436_drv_vhdl.sh 35.0 8 ../rtl 0 0    # HAS_MR = false
./run_hi8436_drv_vhdl.sh 35.0 8 ../rtl 0 1 1  # INIT_EVERY_START = true
./run_hi8436_drv_vhdl.sh 45.0                 # negatif köşe (başarısız olmalı)
./run_flop_check.sh
./run_drv_mutation.sh                         # 12 mutation + N1 sync reset negatif kontrolü
vsim -c -do run_questa_hi8436_drv_vhdl.do     # Questa
../../common/sim/run_sha_check.sh             # core değişmezlik
python3 -I ../docs/gen_drawio.py              # blok diyagramı yeniden üret
```
Gerekenler: GHDL ≥ 4 (`--synth`), Icarus Verilog ≥ 12, Python 3.

## Açık işler
| # | Konu | Durum |
|---|---|---|
| K-12 | Girişlerde debounce / filtre gereksinimi (datasheet'te filtre yok) | v1'de yok; kart tarafına sorulacak |
| DS-4 | 0xF8'de 32 bitin tek anda yakalanıp yakalanmadığı | Bit bazında geçerli kabul edildi |
| DS-10 | nMR'ın hysteresis latch'ine etkisi | Model 0x00 varsayar; yalnız açılış ve hata sonrası etkiler. Holt'a / kartta doğrulanacak |
| K-16 | FPGA I/O bankası 3,3 V mu (VIH ≥ 0,7 × VLOGIC, s.18) | RTL'i etkilemez; kart tarafına sorulacak |
| – | Questa koşusu | `.do` hazır, bu ortamda Questa yok, koşulmadı |
| – | Libero / Synplify sentezi, kaynak raporu, reset ağacı ve recovery/removal timing'i | yapılmadı |
| – | Kart testi: gerçek HI-8436 ile init, okuma, polarite, eşik, self-test, MISO zamanlaması | yapılmadı |
| – | Arbiter (iki HI-8436 ve AD7923 paylaşılan hatta) | driver req/gnt hazır; arbiter yazılmadı |
| DS-1, 2, 3, 5–9 | Faz 1'de kabul edilen varsayımlar | `docs/ANALIZ.md` G |
