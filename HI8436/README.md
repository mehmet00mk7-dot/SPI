# HI8436: Holt HI-8436 (32 kanal discrete sensör) SPI driver'ı

Microchip PolarFire üzerinde, CPU'suz FADEC sensör okuma sisteminin bir parçası. Driver, ortak SPI
master core'u `common/rtl/async/spi_exec` ile HI-8436'yı programlar, doğrular ve 32 sense girişini okur.
Datasheet: `docs/datasheet/HI-8436.pdf` (DS8436 Rev. L). Analiz ve onaylı arayüz: `docs/ANALIZ.md`.

## Dosyalar
| Dosya | İçerik |
|---|---|
| `rtl/hi8436_drv.vhd` | Driver: kontrol FSM'i, paket üretici (packer), timer'lar, çıkış register'ı |
| `rtl/hi8436_top.vhd` | Driver + `spi_exec` + `p_core_resetn`; gnt = '1', sdi_data_ready = sync_ready = '1' |
| `tb/hi8436_model.v` | HI-8436 modeli: protokol, register'lar, sense / hysteresis / test modu, timing kontrolleri, hata kancaları |
| `tb/tb_hi8436_drv.v` | T01–T27 + G (genel kontroller) |
| `sim/run_hi8436_drv_vhdl.sh` | GHDL synth → Icarus. Argümanlar: `[T_SO] [DATA_WIDTH] [RTL] [UNUSED_STORE] [HAS_MR] [INIT_EVERY_START]` |
| `sim/run_flop_check.sh`, `sim/check_flops.py` | Netlist flop yapısı (düz posedge clk / türetilmiş async reset) |
| `sim/run_drv_mutation.sh` | 11 mutation + sync reset negatif kontrolü |
| `sim/run_questa_hi8436_drv_vhdl.do` | Questa akışı (VHDL kaynak doğrudan) |
| `sim/SONUCLAR.txt`, `sim/log/` | Sonuçlar, SHA-256 kontrol çıktısı |
| `docs/ANALIZ.md`, `docs/analiz/` | Faz 1 analizi, paket zamanlama ölçümü |

## Arayüz (`hi8436_top`)
**Girişler** (clk ile senkron)
| Sinyal | Genişlik | Anlam |
|---|---|---|
| clk, rst_n | 1 | 100 MHz; async aktif-düşük reset (reset synchronizer'dan) |
| start | 1 | IDLE'da: ayarlar latch'lenir; init politikasına göre (aşağıda) tam init / kısmi güncelleme / doğrudan okuma. busy iken yok sayılır |
| stop | 1 | Launch olmamış paket iptal, başlamış paket biter (≤ 1 paket), sonra IDLE. Self-test sırasında ertelenir |
| continuous | 1 | 1: okuma period_us aralıkla tekrarlanır; 0: tek okuma |
| period_us | 16 | F8 okuma launch'ları arası µs (her okumada örneklenir). 0 ya da < 2,8 µs: arka arkaya |
| bank_mode | 4 | PSEN<3:0>: bit n = 1 → bank n Supply/Open (start'ta latch) |
| go_center / go_hyst | 6 / 6 | GND/Open eşiği: center 0,1 V/LSB, hysteresis 0,2 V/LSB (start'ta latch) |
| so_center / so_hyst | 6 / 6 | Supply/Open eşiği |
| self_test_req | 1 | IDLE'da: (gerekirse init / güncelleme) + self-test (start yoksa okuma yapılmaz). Çalışırken: sıradaki okuma yerine |

**Çıkışlar**
| Sinyal | Genişlik | Anlam |
|---|---|---|
| sense | 32 | Son okuma, ham SO<31:0> (kalıcı) |
| sense_valid | 1 | 1 clk: sense / sense_chg / sense_act yeni |
| sense_chg | 32 | yeni sense xor önceki sense (reset sonrası 0'a göre) |
| sense_act | 32 | normalize: 1 = aktif (GND/Open'da toprak, Supply/Open'da besleme var) |
| cfg_done | 1 | init_done: entegre programlı, geri okumayla doğrulandı, içeriği biliniyor |
| busy | 1 | IDLE dışı |
| err / err_code | 1 / 4 | Sticky; ilk hata (aşağıda). start / self_test_req ile temizlenir |
| st_done / st_fail | 1 / 1 | Self-test bitti (1 clk) / başarısız (sticky) |
| spi_sclk, spi_mosi, spi_cs_n, spi_miso, spi_mr_n | | HI-8436 SCK, SI, nCS, SO, nMR |

**Generic'ler**: CLKS_PER_US 100, CLK_DIV 2 (16,67 MHz), CS_T 1, DATA_WIDTH 8 (8…32), SDI_DELAY 0,
HAS_MR true, MR_CLKS 20 (200 ns), MR_WAIT_CLKS 100 (1 µs), SETTLE_CLKS 200 (2 µs), SYNC_TO_CLKS 1000,
CORE_RST_CLKS 4, ERR_LIMIT 4, VERIFY_EVERY 0 (kapalı), INIT_EVERY_START false, CFG_FROM_GENERIC false,
DEF_BANK_MODE 0, DEF_GO_CENTER/HYST 9/5 (1,4 / 0,4 V → `3A 05 09`), DEF_SO_CENTER/HYST 35/15
(5,0 / 2,0 V → `3C 0F 23`).

**err_code**: 1 CFG_RANGE (geçersiz eşik kodu, start reddedilir), 2 RB_MISMATCH (init geri okuma),
3 VERIFY_MISMATCH (periyodik doğrulama), 4 SELFTEST_FAIL, 8 SYNC_TIMEOUT (core_rst), 9 SYNC_ID,
A SDI_UNEXPECTED, B SDI_MISSING. Bit 3 = yapısal hata (hemen durur). Veri hatalarında (2, 3) init
ERR_LIMIT kez tekrarlanır. Self-test hatasında test modundan çıkılır ve driver durur.

## Mimari ve çalışma
```
start/stop/ayar --> Control FSM --frm_go + paket tanımı--> Packer --cmd/sdo--> spi_exec --> HI-8436
                       ^                                    |  ^
                       |                      pk_ok (SYNC)  |  | sdi / sync
sense, sense_chg <-- Output reg <-- rx_sh <-----------------+--+
```
- **Paket** = tek CS çerçevesi = tek HI-8436 instruction (s.5: chaining yok):
  CONFIG clk_div → CONFIG mode (Mode 0) → CONFIG word_length (8) → CS aktif → TRANSFER W (opcode
  [+ veri]) → [TRANSFER R (veri)] → CS pasif → SYNC id. Her byte bir core kelimesi. Bu yüzden driver
  core'un DATA_WIDTH değerinden bağımsız çalışır (8/16/32 test edildi).
- **Tam init**: [nMR 200 ns + 1 µs] → CTRL=00, PSEN, GOCENHYS, SOCENHYS, TMDATA=00 →
  82, 84, BA, BC, 9E geri okuma (tam byte) → settle 2 µs → cfg_done → F8 okuma(lar). ≈ 16,5 µs.
  Ne zaman yapıldığı aşağıdaki init politikasında.
- **Okuma**: F8, 2,76 µs. sense = DB3..DB0 = SO<31:24>..SO<7:0>.
- **Self-test**: TMDATA=ALL1 → CTRL.TEST=1 → settle → F8 = 0 → TMDATA=ALL0 → settle → F8 = FFFFFFFF →
  CTRL=00 → TMDATA=00 (≈ 18 µs).
- **Periyodik doğrulama** (VERIFY_EVERY > 0): her N okumada bir 5 register geri okunur. Uyuşmazlık
  (ör. POR glitch'i) olursa yeniden init yapılır.
- Ayarlar yalnız start'ta uygulanır (çalışırken değişen ayar için stop → start).

### Init politikası (`INIT_EVERY_START = false`, varsayılan)
Driver, entegreye son yazdığı ve geri okumayla doğruladığı ayarları shadow register'larda tutar
(`init_done` = bu bilgi geçerli; `cfg_done` çıkışı). start'ta:

| Durum | nMR | Yazma / geri okuma | Sonra | start → sense_valid |
|---|---|---|---|---|
| rst_n sonrası ilk start | evet (HAS_MR) | 5 register yazılır, 5'i geri okunur | settle, okuma | ≈ 19,3 µs (HAS_MR = false: 18,1) |
| Yapısal hata (8 / 9 / A / B) sonrası | evet | tam | settle, okuma | ≈ 19,3 µs |
| Geri okuma hatası, ERR_LIMIT ile durma sonrası | evet | tam | settle, okuma | ≈ 19,3 µs |
| Periyodik doğrulama uyuşmazlığı (kod 3, POR glitch'i) | evet (hemen, çalışırken) | tam | okumalar sürer | – |
| Self-test başarısız olduktan sonra | evet | tam | settle, okuma | ≈ 19,3 µs |
| Yazma dizisi stop ile yarıda kesildiyse (ek güvenlik) | evet | tam | settle, okuma | ≈ 19,3 µs |
| init_done = 1, bank_mode / eşik(ler) son yazılandan farklı | **hayır** | yalnız değişen register'lar (PSEN / GOCENHYS / SOCENHYS) yazılır ve geri okunur | settle (2 µs), okuma | 6,2–6,7 µs (tek register), 12,8 µs (üçü) |
| init_done = 1, ayarlar aynı | **hayır** | yok | doğrudan okuma | ≈ 2,8 µs |
| Geçersiz eşik kodu (CFG_RANGE) | – | yok (start reddedilir) | IDLE, init_done değişmez | – |

Kısmi güncelleme geri okumasında uyuşmazlık olursa entegre içeriği bilinmez sayılır: init_done = 0 ve
tam init ile yeniden denenir (ERR_LIMIT'e kadar). `INIT_EVERY_START = true` eski davranıştır: her
start'ta nMR + tam init.

## Kullanım notları
- **DS-9: Self-test sonrası hysteresis.** Test modu comparator latch'lerini zorlar. VTLO–VTHI bandı
  içindeki bir giriş, test modundan çıkınca son test değerini korur (son desen ALL0 → SO = 1). Datasheet
  bu yüzden test modundan çıkarken girişlerin net high/low olmasını ister (s.12 Test Mode NOTE).
  Register yeniden programlanırken de aynısı geçerlidir (s.11 NOTE). Self-test'i ve stop/start'ı
  girişlerin bandda olmadığı bir anda verin; sonuç band kanalları için anlamlı değilse bir sonraki
  net geçişe kadar bekleyin. (T13'te gösterildi.)
- **DS-10: nMR ve hysteresis.** Datasheet SO register'ının reset değerini 0x00 veriyor (s.9–10
  Tbl 8–12). Gerçek entegrede comparator latch'inin nMR ile sıfırlanıp sıfırlanmadığı açık değil;
  model sıfırlandığını varsayar. Init politikasıyla nMR artık yalnız **açılışta (rst_n sonrası ilk
  start) ve hata sonrası** verilir. Normal tek okuma / continuous kullanımında ve ayar değişiminde
  entegre reset'lenmez, band içindeki kanallar durumunu start'lar arasında korur (T24). Etki,
  açılıştan ve hatadan sonraki ilk okumayla sınırlıdır: o anda band içinde olan bir kanal, bir sonraki
  net geçişe kadar 0 okunabilir. `INIT_EVERY_START = true` seçilirse eski etki (her start'ta) geri gelir.
- MISO örnekleme penceresi: SO, SCK düşen kenarından sonra < 40 ns içinde değişmeli (t_DV ≤ 20 ns +
  kart/IO ≤ 20 ns). Gerekirse SDI_DELAY = 1.

## Doğrulama özeti (ayrıntı: `sim/SONUCLAR.txt`)
- T01–T27 + G: T_SO 5 ns ve 35 ns'de **28/28**, model timing ihlali **0**. DATA_WIDTH 16/32, HAS_MR = false,
  UNUSED_STORE = 1 ve INIT_EVERY_START = true (5 / 35 ns, nMR'sız) köşeleri de 28/28. Negatif köşe
  T_SO = 45 ns: beklendiği gibi başarısız.
- Flop kontrolü: 99 grup / 501 bit, düz posedge clk 0, türetilmiş async reset 0.
- Mutation: 11/11 yakalandı. Negatif kontrol: sync reset kopyasında T20–T22 kalıyor, flop kontrolü başarısız.
- Core SHA-256 başta ve sonda aynı; `AD7923/` ve `common/` değişmedi.

```
cd HI8436/sim
./run_hi8436_drv_vhdl.sh 5.0          # hızlı köşe
./run_hi8436_drv_vhdl.sh 35.0         # yavaş köşe
./run_hi8436_drv_vhdl.sh 35.0 16      # paylaşılan core (DATA_WIDTH 16)
./run_flop_check.sh
./run_hi8436_drv_vhdl.sh 35.0 8 ../rtl 0 1 1   # INIT_EVERY_START = true (eski davranış)
./run_drv_mutation.sh                 # 11 mutation + N1 sync reset negatif kontrolü
vsim -c -do run_questa_hi8436_drv_vhdl.do
../../common/sim/run_sha_check.sh     # core değişmezlik
```

## Açık noktalar
| # | Konu | Durum |
|---|---|---|
| K-12 | Girişlerde debounce / filtre gereksinimi (datasheet'te filtre yok) | v1'de yok, kart tarafına sorulacak |
| DS-4 | 0xF8'de 32 bitin tek anda yakalanıp yakalanmadığı | Bit bazında geçerli kabul edildi |
| K-16 | FPGA I/O bankası 3,3 V mu (VIH ≥ 0,7 × VLOGIC, s.18) | RTL'i etkilemez, kart tarafına sorulacak |
| DS-10 | nMR'ın hysteresis latch'ine etkisi | Model 0x00 varsayar; init politikasıyla yalnız açılış ve hata sonrasını etkiler. Holt'a / kartta doğrulanacak |
| DS-1, 2, 3, 5–9 | Faz 1'de kabul edilen varsayımlar | `docs/ANALIZ.md` G |
| – | Questa koşusu (`.do` hazır, bu ortamda Questa yok) | yapılacak |
| – | Libero / Synplify sentezi, kaynak raporu, reset ağacı timing'i | yapılacak |
| – | `docs/`: blok diyagram (.drawio), FSM diyagramı, toplantı notları | teslim fazında |
