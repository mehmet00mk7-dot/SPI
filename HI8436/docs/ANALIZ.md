# HI-8436 driver: datasheet analizi ve arayüz önerisi (Faz 1)

Kaynak: Holt **HI-8436 datasheet, DS8436 Rev. L (06/26)**, `docs/datasheet/HI-8436.pdf`, 23 sayfa.
Referanslar "s.N" (sayfa), "Tbl N" (tablo), "Fig N" (şekil) biçiminde verilmiştir.
Zamanlama değerleri, önerilen paketlerin `common/rtl/async/spi_exec` ile **simülasyonda ölçülmüş**
halidir (core'a dokunulmadı): `docs/analiz/run_olcum.sh`, çıktısı `docs/analiz/olcum_sonuc.txt`.

Bu fazda RTL yazılmadı. Bölüm E (arayüz) ve G (açık sorular) onay bekliyor.

---

## A) Entegre özeti

### A.1 Ne yapar
- 32 kanallı discrete → dijital sensör. **4 bank × 8 giriş** (s.1 General Description, s.11 Overview).
- Her bank SPI ile ayrı ayrı **GND/Open** ya da **Supply/Open** (28V/Open) olarak programlanır:
  PSEN<3:0> biti 0 = GND/Open, 1 = Supply/Open (s.3 Tbl 1, s.6 Tbl 4).
- Her girişte window comparator + hysteresis latch'i var (s.2 Fig 2: iki comparator, NOR SR latch).
  Eşikler **iki ayrı register çiftiyle** programlanır: GND/Open bankları için GOCENHYS, Supply/Open
  bankları için SOCENHYS. Yani eşikler mod başına ortaktır, bank başına değil (s.7 Tbl 6, s.8 Tbl 7, s.11).
- Eşik aralığı 0,4 V…5,2 V, DAC çözünürlüğü 0,1 V/LSB (s.1 Features, s.11 Programming Thresholds, s.17 DC tablo).
- **Internal self-test**: CTRL.TEST = 1 iken comparator girişleri TMDATA desenine zorlanır. Pin'in
  gerçek durumu bozulmaz (200 kΩ izolasyon) (s.6 Tbl 3/5, s.12 Test Mode).
- Lightning korumalı girişler (DO-160G Sec. 22), driver'ı ilgilendirmez (s.15).

### A.2 Pinler (s.1 pin diyagramı, s.3 Tbl 1)
| Pin | Yön | FPGA'ya bağlanır mı | Not |
|---|---|---|---|
| nCS | giriş | **evet** | aktif-düşük, dahili 30 kΩ pull-up |
| SCK | giriş | **evet** | SPI clock, en fazla 20 MHz |
| SI | giriş | **evet** (MOSI) | dahili 30 kΩ pull-down |
| SO | çıkış | **evet** (MISO) | yalnız okuma byte'larında sürülür, diğer zamanlarda **high-Z** (s.4) |
| nMR | giriş | **isteğe bağlı** | Master reset, aktif-düşük, dahili 30 kΩ pull-up. Bağlı değilse pasif kalır |
| SENSE<31:0> | discrete giriş | hayır | sensör hatları |
| VWET0..3 | besleme | hayır | GND/Open wetting beslemesi, 50 kΩ ile GND'ye |
| VLOGIC | besleme | hayır | 3,0…3,6 V (s.17). Logic seviyeleri VLOGIC'e göre: VIH ≥ %70, VIL ≤ %30 (s.18) → FPGA bankası 3,3 V LVCMOS olmalı |

Interrupt / data-ready pini **yok**. Sense durumu yalnız SPI okumasıyla alınır.

### A.3 Power-up ve reset (s.11 "Initialization and Reset")
- **POR**: besleme gelince tam reset, bütün register'lar varsayılan değere döner.
- **nMR**: en az **100 ns** aktif-düşük pulse tam reset yapar (s.11; s.19 AC tablo t_MR ≥ 100 ns).
- **Software reset**: CTRL<1> (SRST) = 1. Tam reset ile aynı, ama SRST tekrar 0 yazılana kadar
  register'lar reset'te tutulur (s.6 Tbl 3, s.11).
- **Reset değerleri**: CTRL, PSEN, GOCENHYS, SOCENHYS, TMDATA ve SO register'larının hepsi **0x00**
  (s.6–10 Tbl 3–12). Sonuç: reset sonrası 4 bank da GND/Open, eşik kodları 0. Bu kod, VTHI − VTLO ≥ 0,2 V
  kuralını sağlamadığı için **geçersiz** (s.7 Tbl 6 Note). Yani entegre reset sonrası mutlaka programlanmalı.
- **Hazır olma süresi**: POR ya da nMR sonrası SPI'ın ne zaman kullanılabileceği datasheet'te **verilmemiş**.
  → AÇIK SORU DS-2.
- **Eşik değişiminden geçerli SO'ya**: ≤ 1 µs (s.19 Sensor Timings).

---

## B) SPI

### B.1 Mod ve hız
- **Mode 0 zorunlu** (CPOL = 0, CPHA = 0): "The host SPI logic **must** be set for Mode 0" (s.4 SPI Basics).
  SI yükselen kenarda örneklenir, SO düşen kenarda değişir (s.4, Fig 3).
- SCK ≤ 20 MHz (s.1 Features, s.4). t_CYC ≥ 50 ns (s.19).
- Core: SCLK = 100 MHz / (2 × (CLK_DIV + 1)).
  - CLK_DIV = 1 → 25 MHz: **ihlal**.
  - **CLK_DIV = 2 → 16,67 MHz** (60 ns): izin verilen en hızlı değer.
- Half duplex: entegre SO'yu sürerken SI'yı yok sayar (s.4).
- Byte'lar MSB önce gider. CS paket bitmeden kalkarsa yarım byte atılır (s.4).
- **Bir CS çerçevesinde tek instruction olur**: "Two instruction bytes cannot be chained; nCS must be
  negated after each instruction" (s.5). Driver kalıbındaki "her paket = tek frame" yapısına birebir uyar.
- Tablo 2 dışındaki opcode'lar reserved, kullanılmamalı (s.5 Note).

### B.2 Timing (s.19 AC tablo, Fig 12/13)
"Bizim" sütunu: 100 MHz, CLK_DIV = 2, **CS_T = 1** (önerilen). Değerler FPGA pininde, simülasyonda
ölçüldü (`olcum_sonuc.txt`). Parantez içi: CS_T = 0.

| Parametre | Sembol | Datasheet | Bizim | Marj |
|---|---|---|---|---|
| SCK periyodu | t_CYC | ≥ 50 ns | 60 ns | +10 ns (%20) |
| SCK high | t_SCKH | ≥ 20 ns | 30 ns | +10 ns |
| SCK low | t_SCKL | ≥ 20 ns | 30 ns | +10 ns |
| Son SCK yükselen kenarından sonra nCS aktif | t_CHH | ≥ 5 ns | 100 ns (40) | +95 ns |
| nCS ↓ → ilk SCK yükselen kenarı | t_CES | ≥ 5 ns | 120 ns (60) | +115 ns |
| Son SCK düşen kenarı → nCS ↑ | t_CEH | ≥ 5 ns | 70 ns (10) | +65 ns |
| İki instruction arası nCS high | t_CPH | ≥ 55 ns | ≥ 190 ns (70) arka arkaya paketlerde | +135 ns |
| SI setup (SCK ↑ öncesi) | t_DS | ≥ 10 ns | 30 ns | +20 ns (kart skew'i hariç) |
| SI hold (SCK ↑ sonrası) | t_DH | ≥ 10 ns | 30 ns | +20 ns |
| SCK rise / fall | t_SCKR/F | ≤ 10 ns | FPGA I/O + kart | driver kontrol etmez (AÇIK SORU K-6) |
| SCK ↓ → SO geçerli | t_DV | ≤ 20 ns | Core, SO'yu düşen kenar + 40 ns'de örnekler (yükselen kenar + 1 clk). SO_DLY < 40 ns ise doğru okunur (tarama: 39 ns OK, 40 ns FAIL) | **20 ns**: SCK çıkış + kart gidiş-dönüş + FPGA giriş gecikmesi için |
| SO hold (SCK ↓ sonrası) | – | **verilmemiş** | Sonraki değişim en erken düşen kenar + 60 ns'de, örneklemeden 20 ns sonra | +20 ns (hold = 0 varsayımı, AÇIK SORU DS-8) |
| nCS ↑ → SO high-Z | t_CHZ | ≤ 20 ns | Sonraki CS ↓ ≥ 190 ns sonra | SO, sonraki çerçeveden önce high-Z olur |
| nMR pulse | t_MR | ≥ 100 ns | MR_CLKS = 20 → 200 ns | +100 ns |
| Sense değişimi → SO | – | ≤ 1 µs | bilgi (okuma gecikmesine eklenir) | – |
| Eşik değişimi → SO | – | ≤ 1 µs | SETTLE_CLKS = 200 → 2 µs | +1 µs |

**SDI_DELAY = 0 önerilir.** SDI_DELAY = 1 yapılırsa örnekleme 10 ns kayar: setup marjı 30 ns olur,
hold marjı 10 ns'ye düşer. Kart gecikmesi büyükse (AÇIK SORU K-6) generic ile değiştirilebilir.

**CS_T = 1 önerilir.** CS_T = 0'da t_CEH yalnız 10 ns (marj 5 ns) ve t_CPH 70 ns (marj 15 ns) kalıyor;
SCK/nCS hatları arasındaki kart skew'i bu marjları yiyebilir. CS_T = 1'in maliyeti paket başına
0,24 µs.

### B.3 Instruction set (s.3 Tbl 2, s.4 Fig 4)
Opcode'un bit 7'si R/W' (1 = okuma) (s.4 Fig 4).

| Opcode | Ad | R/W | Veri byte | Açıklama | Driver kullanımı |
|---|---|---|---|---|---|
| 0x02 | Write CTRL | W | 1 | SRST, TEST | init, self-test |
| 0x04 | Write PSEN | W | 1 | bank modları | init |
| 0x3A | Write GOCENHYS | W | 2 | GND/Open eşik + hysteresis | init |
| 0x3C | Write SOCENHYS | W | 2 | Supply/Open eşik + hysteresis | init |
| 0x1E | Write TMDATA | W | 1 | test deseni | init, self-test |
| 0x82 | Read CTRL | R | 1 | | geri okuma |
| 0x84 | Read PSEN | R | 1 | | geri okuma |
| 0xBA | Read GOCENHYS | R | 2 | | geri okuma |
| 0xBC | Read SOCENHYS | R | 2 | | geri okuma |
| 0x9E | Read TMDATA | R | 1 | | geri okuma |
| 0x90 | Read Bank 0 | R | 1 | SO<7:0> | kullanılmaz |
| 0x92 | Read Bank 1 | R | 1 | SO<15:8> | kullanılmaz |
| 0x94 | Read Bank 2 | R | 1 | SO<23:16> | kullanılmaz |
| 0x96 | Read Bank 3 | R | 1 | SO<31:24> | kullanılmaz |
| 0xF8 | Read All Banks | R | 4 | SO<31:0> | **periyodik okuma**, self-test |

Bank bank okuma kullanılmaz: 4 bank için 4 frame (4 × 1,33 µs) gerekir, 0xF8 tek frame'de 2,77 µs sürer.

### B.4 Çerçeve yapısı (s.4–5 Fig 3, 5, 6, 7; s.10 Tbl 13)
**Yazma** (ör. 0x3A, 2 byte, Fig 6):
```
nCS ‾‾\________________________________________________________/‾‾
SI       [op7..op0 = 0x3A] [DB1: 0 0 H5..H0] [DB0: 0 0 C5..C0]      (MSB önce, SCK ↑'de örneklenir)
SO   Z ............................................................ Z (yazmada hiç sürülmez)
SCK      24 pulse (Mode 0, boşta low)
```
Her veri byte'ının 8. yükselen kenarında hedef register yüklenir (s.4). 2 byte'lık yazmada önce DB1
(hysteresis), sonra DB0 (center) gider (s.7 Tbl 6 "[opcode, DB1, DB0]", s.10 Tbl 13 Örnek 2).

**Okuma** (ör. 0x84, 1 byte, Fig 5):
```
SI       [op = 0x84]  (sonrası yok sayılır)
SO   Z ............ [D7..D0] Z
```
D7, 8. opcode bitinin yükselen kenarından sonraki **düşen kenarda** çıkar. Sonraki bitler düşen
kenarlarda değişir, master yükselen kenarda örnekler (s.4).

**Read All Banks, 0xF8** (40 SCK; s.5 Fig 7, s.10 Tbl 12, Tbl 13 Örnek 3):
```
SI   [1111 1000]
SO              [DB3 = SO31..SO24][DB2 = SO23..SO16][DB1 = SO15..SO8][DB0 = SO7..SO0]
```
32 bitlik sense kelimesi = DB3 & DB2 & DB1 & DB0. Byte sırası MSB banktan (bank 3) başlar.

---

## C) Register haritası

| Opcode W/R | Register | Bit alanları | Reset | Kaynak |
|---|---|---|---|---|
| 0x02 / 0x82 | CTRL | [7:2] kullanılmıyor (R/W, 0); [1] SRST; [0] TEST | 0x00 | s.6 Tbl 3 |
| 0x04 / 0x84 | PSEN | [7:4] kullanılmıyor; [3:0] BANK3..0 (0 = GND/Open, 1 = Supply/Open). Bank n = SENSE<8n+7:8n> | 0x00 | s.6 Tbl 4 |
| 0x1E / 0x9E | TMDATA | [7:4] kullanılmıyor; [3] ODD1, [2] ODD0, [1] ALL1, [0] ALL0. **Tek bit seçilmeli**: birden fazla bit 1 ise bütün girişler low olur | 0x00 | s.6 Tbl 5 |
| 0x3A / 0xBA | GOCENHYS | DB1: [7:6] –, [5:0] GOHYS; DB0: [7:6] –, [5:0] GOCVAL | 0x00, 0x00 | s.7 Tbl 6 |
| 0x3C / 0xBC | SOCENHYS | DB1: [5:0] SOHYS; DB0: [5:0] SOCVAL | 0x00, 0x00 | s.8 Tbl 7 |
| – / 0x90…0x96, 0xF8 | SO<31:0> | salt okunur sense durumu | 0x00 | s.9–10 Tbl 8–12 |

### C.1 Eşik kodlaması (s.7 Tbl 6, s.8 Tbl 7, s.11, s.16 Tbl 16)
- Center = 0,1 V × CVAL (6 bit, 0…63). Hysteresis = **0,2 V** × HYS (6 bit).
- VTHI = Center + ½ Hyst = 0,1 V × (CVAL + HYS). VTLO = Center − ½ Hyst = 0,1 V × (CVAL − HYS).
- Sınırlar: VTHI ≤ 5,2 V ve ≥ 0,6 V; VTLO ≥ 0,4 V ve ≤ 5,0 V; VTHI − VTLO ≥ 0,2 V (s.7 Tbl 6 Note).
  Kod cinsinden: **HYS ≥ 1, CVAL + HYS ≤ 52, CVAL − HYS ≥ 4**. Bu üçü sağlanınca diğer sınırlar da sağlanır.
- GND/Open'da VWETn açık (open) bırakılırsa programlanabilir VTHI en fazla 1,4 V olur (s.16 Tbl 16
  satır 1). VTHI > 1,4 V için VWETn > 1,3 × VTHI + 2,25 V gerekir (s.11 Tbl 14 dipnotu, s.12).
  Bu kart bilgisi → AÇIK SORU K-3/K-4.
- Supply/Open bankında VWETn açık bırakılmalı (s.12).
- Datasheet örnekleri: GND/Open VTHI 3,0 / VTLO 1,0 V → GOHYS = 10, GOCVAL = 20 → `3A 0A 14` (s.7).
  Supply/Open 5,0 / 2,0 V → SOHYS = 15, SOCVAL = 35 → `3C 0F 23` (s.8).
- Datasheet hatası: s.11 "c) Center Value = (VTHI − VTLO)/2 / 0,1" yazıyor, doğrusu Tbl 6'daki
  (VTHI + VTLO)/2. Tbl 6 esas alınır (DS-6).
- Garanti edilen eşik toleransı Fig 11'de (s.16): yaklaşık ±%20. Bu analog bilgi; seçimi sistem tarafı yapar.

### C.2 Sense polaritesi (s.9 üst kısım, s.11 Tbl 14)
| Bank modu | SO<n> = 1 | SO<n> = 0 |
|---|---|---|
| GND/Open (PSEN = 0) | pin ≤ VTLO (**toprağa çekilmiş**) | pin açık ya da > VTHI |
| Supply/Open (PSEN = 1) | pin açık ya da < VTLO | pin ≥ VTHI (**besleme var**) |

- VTLO ile VTHI arasında latch önceki durumu korur (hysteresis, s.2 Fig 2'deki SR latch).
- "Aktif" durum (kontak kapalı: toprak ya da besleme) GND/Open'da 1, Supply/Open'da **0** olarak okunur.
  Bunun için normalize edilmiş bir çıkış öneriyorum: `sense_act = sense xor (bank modunun 8'e genişletilmişi)`
  (E.1, AÇIK SORU K-10).
- Test modunda "high" giriş her iki modda SO = 0, "low" giriş SO = 1 verir (Tbl 14'e göre high > VTHI → 0,
  low < VTLO → 1). Bu yüzden self-test'te beklenen değer bank modundan bağımsızdır:
  ALL1 → 0x00000000, ALL0 → 0xFFFFFFFF.

### C.3 Filtre / gecikme
- Datasheet'te girişte digital filtre ya da debounce **tarif edilmiyor**. Yalnız comparator hysteresis'i
  ve lightning koruma devresi var (s.2, s.15). Debounce gerekiyorsa FPGA / sequencer tarafında yapılır (K-12).
- Sense değişiminden SO'ya: **≤ 1 µs** (s.19). Uçtan uca gecikme ≤ 1 µs + okuma periyodu + frame süresi (2,77 µs).
- 32 bitlik SO kelimesinin okuma başında bir kerede yakalanıp yakalanmadığı (atomik snapshot) belirtilmemiş (DS-4).

---

## D) Core ile eşleme

### D.1 DATA_WIDTH ve word_length
- Bütün HI-8436 çerçeveleri 8 bitin katı: opcode + 1/2/4 byte, toplam 16/24/40 bit. 40 bit core'un
  en fazla 32 bitlik kelimesine sığmıyor.
- **Öneri: word_length = 8, her byte bir kelime.** Opcode bir TRANSFER (W, 1 kelime), veri bir TRANSFER
  (yazmada W, okumada R, N kelime). CS iki CHIPSELECT arasında aktif kalır. İki TRANSFER arasındaki boşluk
  Mode 0'da sorun değil: SCK low bekler ve entegre statiktir. Ölçülen ek süre 20 ns.
- Driver core'un DATA_WIDTH'inden bağımsız olur (generic, 8…32):
  - sdo kelimesi = byte, sıfırla genişletilmiş. Core, word_length < DATA_WIDTH iken kelimeyi
    `left_aligned = DATA_WIDTH − word_length` kadar MSB'ye kaydırır (spi_exec.vhd WRITE komutu,
    spi_exec_shiftreg.vhd ALIGNER).
  - sdi kelimesinin **yalnız [7:0]'ı** kullanılır. Core'un SDI shift register'ı kelimeler arasında
    temizlenmez (yalnız cs_activate'te), üst bitlerde önceki byte'lar kalır.
  - Bu sayede aynı driver, core DATA_WIDTH = 16 veya 32 ile kullanılsa da çalışır.
- Kendi top'umuzda: DATA_WIDTH = 8, NUM_OF_CS = 1, SDI_DELAY = "00", SDO_DEFAULT = "0", DEFAULT_SPI_CFG = 0.

### D.2 Komutlar (CLK_DIV = 2, CS_T = 1, CS_IDX = 0)
| Komut | Hex | Not |
|---|---|---|
| CONFIG clk_div | 0x2002 | |
| CONFIG mode | 0x2100 | CPHA = 0, CPOL = 0, SDO idle = 0 (SI'da dahili pull-down var, s.3) |
| CONFIG word_length | 0x2208 | 8 bit |
| CHIPSELECT aktif | 0x11FE | genel: 0x1000 \| CS_T<<8 \| ~(1<<CS_IDX) |
| CHIPSELECT pasif | 0x11FF | |
| TRANSFER W, 1 kelime | 0x0100 | opcode |
| TRANSFER W, 2 / 3 kelime | 0x0101 / 0x0102 | opcode + 1 / 2 veri byte (tek TRANSFER) |
| TRANSFER R, 1 / 2 / 4 kelime | 0x0200 / 0x0201 / 0x0203 | okuma verisi |
| SYNC id | 0x30nn | id her pakette artar |

### D.3 Paket türleri (süreler ölçüldü, `olcum_sonuc.txt`; launch = ilk komutun kabulü)
| Paket | Komut listesi | sdo kelimeleri | sdi | SCK | CS low | launch → SYNC |
|---|---|---|---|---|---|---|
| Yazma 1 byte (CTRL, PSEN, TMDATA) | 2002 2100 2208 11FE **0101** 11FF 30nn | op, DB0 | – | 16 | 1,12 µs | **1,31 µs** |
| Yazma 2 byte (GOCENHYS, SOCENHYS) | 2002 2100 2208 11FE **0102** 11FF 30nn | op, DB1, DB0 | – | 24 | 1,60 µs | **1,79 µs** |
| Okuma 1 byte (82, 84, 9E) | 2002 2100 2208 11FE **0100 0200** 11FF 30nn | op | 1 | 16 | 1,14 µs | **1,33 µs** |
| Okuma 2 byte (BA, BC) | 2002 2100 2208 11FE **0100 0201** 11FF 30nn | op | 2 | 24 | 1,62 µs | **1,81 µs** |
| Read All (F8) | 2002 2100 2208 11FE **0100 0203** 11FF 30nn | 0xF8 | 4 | 40 | 2,58 µs | **2,77 µs** |

Paketler arasına driver birkaç clock ekler. Toplam süreler (yaklaşık):
- **Init yazma**: CTRL 00, PSEN, GOCENHYS, SOCENHYS, TMDATA 00 → 1,31 + 1,31 + 1,79 + 1,79 + 1,31 = **7,5 µs**.
- **Geri okuma**: 82, 84, BA, BC, 9E → 1,33 + 1,33 + 1,81 + 1,81 + 1,33 = **7,6 µs**.
  Son eşik yazmasından ilk sense okumasına kadar geçen süre zaten > 1 µs. Settle timer yine de ayrıca
  tutulur (sıra değişirse güvence olsun).
- **nMR** (HAS_MR): 0,2 µs pulse + MR_WAIT 1 µs.
- **Init toplam ≈ 15,1 µs (nMR ile ≈ 16,3 µs).**
- **Periyodik okuma**: 2,77 µs → en yüksek okuma hızı ≈ 360 kHz (period_us = 0, arka arkaya).
- **Self-test** (ALL1 + ALL0): TMDATA(ALL1) → CTRL(TEST = 1) → settle 2 µs → F8 → TMDATA(ALL0) →
  settle → F8 → CTRL(0) → TMDATA(0) → settle 2 µs. Süre: 1,31 × 5 + 2,77 × 2 + 2 × 3 ≈ **18,1 µs**.
- **Periyodik doğrulama** (öneri, VERIFY_EVERY): 82 + 84 + BA + BC ≈ 6,3 µs.

---

## E) Driver arayüz önerisi

### E.1 Portlar (`hi8436_drv`; `hi8436_top` SPI pinlerini ekler)
**Girişler** (clk ile senkron)
| Sinyal | Genişlik | Anlam | Ne zaman örneklenir |
|---|---|---|---|
| clk, rst_n | 1 | 100 MHz, async aktif-düşük reset (synchronizer'dan) | – |
| start | 1 | IDLE'da init + okuma başlatır. busy iken yok sayılır | IDLE |
| stop | 1 | Henüz launch olmamış paket iptal edilir, başlamış olan biter (≤ 1 paket), sonra IDLE | her zaman (pending) |
| continuous | 1 | 1: period_us aralıkla sürekli okuma; 0: tek okuma sonra IDLE | start'ta ve her okuma sonunda (0 olursa döngü biter) |
| period_us | 16 | Okuma başları (launch) arası µs. 0 ya da frame süresinden küçükse arka arkaya | her okuma başında |
| bank_mode | 4 | PSEN<3:0>: bit n = 1 → bank n Supply/Open (s.6 Tbl 4) | **start'ta latch** |
| go_center, go_hyst | 6 + 6 | GOCVAL, GOHYS (s.7 Tbl 6 kodlaması) | start'ta latch |
| so_center, so_hyst | 6 + 6 | SOCVAL, SOHYS (s.8 Tbl 7) | start'ta latch |
| self_test_req | 1 | Self-test isteği (pulse, pending olarak tutulur), bkz. E.2 | |
| gnt | 1 | arbiter izni (top'ta '1') | |

**Çıkışlar**
| Sinyal | Genişlik | Anlam |
|---|---|---|
| sense | 32 | Son geçerli okuma, **kalıcı register**, datasheet polaritesi (SO<31:0>) |
| sense_valid | 1 | 1 clk pulse: sense / sense_chg / sense_act yeni |
| sense_chg | 32 | yeni sense xor önceki sense register'ı (sense_valid ile geçerli) |
| sense_act | 32 | normalize: 1 = aktif (GND/Open'da toprak, Supply/Open'da besleme var) = sense xor genişletilmiş bank_mode (öneri, K-10) |
| cfg_done | 1 | Init + geri okuma doğrulaması başarılı, entegre programlı. start, hata ya da reset ile 0 |
| busy | 1 | IDLE dışındaki her state |
| err | 1 | Sticky hata, yeni start ile temizlenir |
| err_code | 4 | İlk hatanın kodu (E.4), err ile birlikte sticky |
| st_done, st_fail | 1 + 1 | Self-test bitti (1 clk), sonuç (st_fail kalıcı, start'ta temizlenir) |
| req | 1 | arbiter isteği (paket boyunca, SYNC'e kadar) |
| cmd / cmd_valid / cmd_ready, sdo_data / sdo_valid / sdo_ready, sdi_data / sdi_valid, sync / sync_valid, core_rst | | CLAUDE.md'deki standart core arayüzü (sdo/sdi genişliği = DATA_WIDTH) |
| **top**: spi_sclk, spi_mosi, spi_cs_n, spi_miso, spi_mr_n | | spi_mr_n: HAS_MR = true ise sürülür, reset değeri '1' |

### E.2 Ayarlar ne zaman uygulanır
- **Öneri: start'ta latch'lenir.** Çalışırken değişen ayar dikkate alınmaz; yeni ayar için stop → start.
  Gerekçe: Datasheet, register yeniden yazılırken girişlerin net high/low olması gerektiğini söylüyor,
  yoksa hysteresis latch'i yanlış duruma geçebilir (s.11 NOTE, s.12). Çalışırken otomatik yeniden
  programlama bu riski sistemden habersiz alır; ne zaman yapılacağına sequencer karar vermeli.
- Her start'ta tam init yapılır (≈ 15 µs). Tek okuma modunda her start'a init eklenir. İstenirse
  "ayar değişmediyse ve cfg_done = 1 ise init'i atla" seçeneği eklenebilir (K-15).
- Eşik kodları start'ta kontrol edilir (C.1: HYS ≥ 1, CVAL + HYS ≤ 52, CVAL − HYS ≥ 4). Bu kontrol
  yalnız **kullanılan** mod için yapılır: bank_mode = 0000 ise SOCENHYS kontrol edilmez, 1111 ise GOCENHYS
  edilmez. Geçersizse start reddedilir: err = 1, err_code = CFG_RANGE, SPI'a hiçbir şey gönderilmez.
  Kullanılmayan moda ait register'a gelen değer yine de yazılır (geri okuma tutarlılığı için).
- self_test_req:
  - IDLE'da gelirse start gibi davranır: init → self-test → (continuous ise) okuma döngüsü, değilse IDLE.
  - Çalışırken gelirse bir sonraki okuma zamanında okuma yerine self-test yapılır, sonra döngü devam eder.

### E.3 Init sırası
1. `HAS_MR` ise nMR = 0, MR_CLKS süre (200 ns), sonra MR_WAIT_CLKS bekleme (1 µs, DS-2).
2. Yazmalar: CTRL ← 0x00, PSEN ← bank_mode, GOCENHYS ← (go_hyst, go_center), SOCENHYS ← (so_hyst, so_center),
   TMDATA ← 0x00. Kullanılmayan bitlere 0 yazılır. CTRL ve TMDATA her init'te açıkça sıfırlanır; nMR
   bağlı olmasa da önceki bir self-test'ten kalan TEST biti temizlenmiş olur.
3. Geri okuma: 82, 84, BA, BC, 9E. **Bütün byte** yazılanla karşılaştırılır. Kullanılmayan bitlere 0
   yazıldığı için entegre bunları saklasa da saklamasa da beklenen 0'dır (DS-3).
   Bir uyuşmazlık veri hatasıdır: err_cnt artar, ERR_LIMIT'e kadar init 1. adımdan tekrarlanır.
4. Settle: son yazmadan itibaren ≥ SETTLE_CLKS geçmiş olmalı (s.19: ≤ 1 µs).
5. cfg_done = 1 → periyodik okuma (0xF8).

### E.4 Hata sınıfları ve err_code
| Kod | Ad | Sınıf | Davranış |
|---|---|---|---|
| 0x0 | – | – | hata yok |
| 0x1 | CFG_RANGE | parametre | start reddedilir, SPI trafiği yok |
| 0x2 | RB_MISMATCH | veri | init geri okuması uyuşmuyor. ERR_LIMIT kez art arda → durur |
| 0x3 | VERIFY_MISMATCH | veri | periyodik doğrulamada uyuşmazlık (entegre reset'lenmiş olabilir) → yeniden init. ERR_LIMIT kez → durur |
| 0x4 | SELFTEST_FAIL | veri | F8 sonucu beklenenden farklı → st_fail = 1, durur (K-14) |
| 0x8 | SYNC_TIMEOUT | yapısal | core_rst pulse, durur |
| 0x9 | SYNC_ID | yapısal | durur |
| 0xA | SDI_UNEXPECTED | yapısal | beklenmeyen sdi kelimesi (FIFO underflow karşılığı) → durur |
| 0xB | SDI_MISSING | yapısal | SYNC geldi ama beklenen sayıda sdi kelimesi gelmedi → durur |

Kodun bit 3'ü = yapısal. Veri hatasında sense basılmaz. Sticky err ilk hatayı tutar.

**Okunan sense verisinde kontrol edilebilecek bir şey yok.** 0xF8 cevabının 32 bitinin hepsi gerçek veri:
sabit bit, parity ya da adres alanı yok (s.10 Tbl 12). Sense okumasında veri hatası tespit **edilemez**,
yalnız yapısal hatalar yakalanır. Dolaylı kontroller:
- Init geri okuması: entegre takılı değilse ya da MISO kopuksa yakalanır. HYS ≥ 1 olduğu için eşik
  register'ı hiçbir zaman 0x00 değil, bu yüzden MISO sürekli 0 olsa da fark edilir.
- Öneri olarak **VERIFY_EVERY** okumada bir config geri okuması. POR glitch'i ile kendiliğinden
  reset'lenmiş bir entegreyi (register'lar 0x00) yakalar.
- Self-test.

### E.5 FSM (öneri)
```
IDLE --start/self_test_req (cfg geçerli)--> [MR_PULSE --> MR_WAIT]? --> CFG_WR(0..4) --> CFG_RD(0..4)
   ^                                                                       | uyuşmazlık: err_cnt++
   |                                                                       v  (< ERR_LIMIT: MR/CFG_WR'ye)
   |<---- stop / continuous=0 / hata ---------------------- SETTLE --> [SELFTEST(...)]? --> READ
   |                                                                         ^             |
   |                                                                         |   PERIOD <--+ (continuous)
   |                                                                         +--- VERIFY (her VERIFY_EVERY okumada)
   +<-- CORE_RST <-- SYNC timeout
```
| State | İş | Çıkış |
|---|---|---|
| IDLE | start bekler, cfg latch + aralık kontrolü | start, geçersiz cfg (err), self_test_req |
| MR_PULSE / MR_WAIT | nMR pulse, bekleme | timer |
| CFG_WR | 5 yazma paketi (idx) | 5. SYNC |
| CFG_RD | 5 okuma paketi, karşılaştırma | 5. SYNC / uyuşmazlık |
| SETTLE | son yazmadan itibaren SETTLE_CLKS | timer |
| ST_* | self-test alt adımları (TMDATA, CTRL, settle, F8, karşılaştırma, geri alma) | bitti / fail |
| READ | F8 paketi → sense, sense_valid, sense_chg | SYNC |
| PERIOD | period timer (launch'tan itibaren) | timer, stop, self_test_req, verify sayacı |
| VERIFY | 82, 84, BA, BC geri okuma | SYNC / uyuşmazlık |
| CORE_RST | core_rst pulse (CORE_RST_CLKS) | → IDLE |

Paket gönderimi (packer) AD7923'teki gibi ayrı bir process olur: req/gnt kilidi, CONFIG×3 → CS → TRANSFER(ler)
→ CS → SYNC, launch'ta timeout başlar, SYNC id kontrolü yapılır, beklenen sdi kelime sayacı tutulur.
Aynı anda tek paket uçuşta olduğu ve AD7923'teki kanal pipeline'ı olmadığı için expectation FIFO'ya
gerek yok; yerine "beklenen kelime sayısı" sayacı kullanılır. Select frame ve dummy frame de taşınmaz.

### E.6 Generic'ler
| Generic | Varsayılan | Gerekçe |
|---|---|---|
| CLKS_PER_US | 100 | 100 MHz (K-13) |
| CLK_DIV | 2 | 16,67 MHz, ≤ 20 MHz olan en hızlı değer (B.1) |
| CS_IDX | 0 | core'da bu entegrenin CS hattı (kartta her entegre kendi hattında, tek CS: 0) |
| CS_T | 1 | t_CEH / t_CPH marjı (B.2) |
| DATA_WIDTH | 8 | core kelime genişliği (8…32). Driver 16/32 ile de çalışır (D.1) |
| SDI_DELAY | 0 (top) | MISO marjı (B.2) |
| HAS_MR | true | nMR bağlı değilse zararsız (dahili pull-up, K-1) |
| MR_CLKS | 20 | 200 ns ≥ 100 ns (s.19) |
| MR_WAIT_CLKS | 100 | 1 µs, datasheet vermiyor (DS-2) |
| SETTLE_CLKS | 200 | 2 µs ≥ 1 µs (s.19) |
| SYNC_TO_CLKS | 1000 | 10 µs; en uzun paket 2,77 µs (3,6× marj) |
| CORE_RST_CLKS | 4 | AD7923 ile aynı |
| ERR_LIMIT | 4 | AD7923 ile aynı |
| VERIFY_EVERY | 0 (kapalı) | K-9; açılırsa ör. 1000 okumada bir |
| ST_PATTERNS | "0011" | Self-test'te koşulacak TMDATA desenleri (bit = TMDATA biti). Yalnız beklenen değeri kesin olan ALL1/ALL0 (DS-1) |
| CFG_FROM_GENERIC (top) | false | true ise bank_mode ve eşikler aşağıdaki generic'lerden alınır, portlar yok sayılır (kart testi için) |
| DEF_BANK_MODE | "0000" | POR değeri (K-2) |
| DEF_GO_CENTER / DEF_GO_HYST | 20 / 10 | Datasheet örneği: GND/Open 3,0 / 1,0 V (s.7). VWET ≥ 6,15 V ister (K-3/K-4). VWET açıksa 9 / 5 (1,4 / 0,4 V) |
| DEF_SO_CENTER / DEF_SO_HYST | 35 / 15 | Datasheet örneği: Supply/Open 5,0 / 2,0 V (s.8) |

### E.7 Sistem seviyesi
- Kartta iki HI-8436 ve bir AD7923 var. **Her entegre ayrı SPI hattında ve hattındaki tek entegre**
  (K-5 cevabı): hat A = AD7923, hat B = HI-8436 #1, hat C = HI-8436 #2.
- `hi8436_top` **tek entegre, tek hat** içindir (driver + kendi spi_exec'i). İki HI-8436 için sistem
  seviyesinde iki `hi8436_top` instance'ı kullanılır. Arbiter yok; her top'ta `gnt = '1'`.
- req/gnt arayüzü driver'da korunur: ileride paylaşılan bir hat olursa arbiter bağlanabilir
  (gnt, paketin SYNC'i gelene kadar tutulur).
- Datasheet'in çoklu entegre önerisi (ortak SCK/SI/SO, ayrı nCS; s.14 Fig 9) bu kartta kullanılmıyor.

---

## F) Model ve test planı

### F.1 `hi8436_model.v` (Verilog)
- **Portlar**: ncs, sck, si, so (high-Z destekli), nmr. `sense_lvl[63:0]`: kanal başına 2 bit
  (00 = GND/low < VTLO, 01 = band içi (hysteresis, önceki durum korunur), 10 = high/supply > VTHI, 11 = open).
  Analog voltaj yerine seviye: polarite, mod ve hysteresis davranışını Tbl 14'e göre kurmaya yeter.
- **Protokol**: Tbl 2'deki 15 opcode. Mode 0. Opcode'un ardından byte sayısı Tbl 2'ye göre. Yazmada her
  byte'ın 8. yükselen kenarında register yüklenir. Okumada SO düşen kenarlarda T_SO gecikmeyle sürülür,
  diğer zamanlarda 'z'.
- **Register'lar**: CTRL, PSEN, GOCENHYS, SOCENHYS, TMDATA. Reset değeri 0x00 (POR, nMR ≥ 100 ns, SRST).
  Kullanılmayan bitler parametreye göre saklanır ya da 0 okunur (DS-3, iki durum da test edilir).
- **Sense**: Kanal başına seviye → latch → SO<n> (Tbl 14). Sense değişimi SO'ya T_SENSE (≤ 1 µs, parametre)
  gecikmeyle yansır. Test modunda giriş TMDATA desenine zorlanır (ODD desenlerinde çift girişlerin
  davranışı parametre, DS-1).
- **Timing kontrolleri** (her ihlal sayılır ve raporlanır): t_CYC, t_SCKH, t_SCKL, t_CES, t_CHH, t_CEH,
  t_CPH, t_DS, t_DH, t_MR. Mode kontrolü: CS kenarlarında SCK = 0 olmalı. Yarım byte (CS ↑ byte ortasında).
  Reserved opcode. Fazla byte (chaining). Eksik byte'lı yazma. Settle ihlali: eşik / PSEN / CTRL / TMDATA
  yazmasından sonraki SETTLE_NS içinde başlayan F8 okuması.
- **Hata enjeksiyonu kancaları**: sonraki register okumasında bit çevirme (`inj_rb_flip`), SO'yu X / z /
  sabit sürme, POR glitch'i (`inj_por`: register'lar 0x00), self-test cevabını bozma.
  Core tarafı hataları (SYNC id bozma, SYNC bastırma, fazladan / eksik sdi_valid) TB'de AD7923'teki gibi
  core sinyallerine force ile verilir.

### F.2 Test listesi (`tb_hi8436_drv.v`)
| Test | Ne kontrol eder |
|---|---|
| T01 | Reset sonrası çıkışlar. start yokken SPI trafiği yok, cs_n = 1, mr_n = 1 |
| T02 | Init: nMR pulse ≥ 100 ns, 5 yazma + 5 geri okuma, model register'ları = ayarlar, cfg_done, paket sayısı ve sırası |
| T03 | Tek okuma (continuous = 0): sense = model, sense_valid 1 clk, sonra busy = 0 |
| T04 | Polarite: karışık bank_mode, her kanal için GND / high / open seviyeleri → Tbl 14. sense_act |
| T05 | Hysteresis: band'e giren kanal önceki durumunu korur |
| T06 | Sürekli + period_us: launch aralığı = period (ölçülür). period = 0 ve period < frame süresi |
| T07 | Sense değişimi ve sense_chg: rastgele değişimler, chg = xor, T_SENSE gecikmesi hesaba katılır |
| T08 | Ayar değişikliği: çalışırken uygulanmaz. stop/start sonrası yeni değerler yazılır ve doğrulanır |
| T09 | stop: launch olmamış paket iptal, ≤ 1 paket. Init sırasında stop |
| T10 | busy iken start yok sayılır |
| T11 | Geri okuma hatası (inj_rb_flip): err, err_code = 2, retry. ERR_LIMIT kez → durur |
| T12 | CFG_RANGE: geçersiz eşik kodları → start reddedilir, SPI trafiği yok. Kullanılmayan modun kodları kontrol edilmez |
| T13 | Self-test: IDLE'dan ve çalışırken. ALL1 → 0, ALL0 → FFFFFFFF. Bozuk cevap → st_fail, err_code = 4. Sonrasında TEST = 0 |
| T14 | VERIFY_EVERY + inj_por → VERIFY_MISMATCH → yeniden init → okumalar devam |
| T15 | SYNC timeout (SYNC bastırma) → core_rst pulse, err_code = 8. Sonraki start'ta normal çalışma |
| T16 | Yanlış SYNC id → err_code = 9 |
| T17 | Beklenmeyen sdi kelimesi (0xA), eksik sdi kelimesi (0xB) |
| T18 | Settle: init ve self-test sonrası ilk F8 ≥ SETTLE. Model settle ihlali = 0 |
| T19 | gnt = 0 iken paket başlamaz, gnt gelince başlar, req SYNC'e kadar tutulur |
| T20 | rst_n frame ortasında (SCK aktif): çıkışlar anında reset değerinde, cs_n = 1, mr_n = 1, kendiliğinden başlamaz |
| T21 | rst_n clock dururken |
| T22 | 1 clock'luk rst_n |

- **Timing köşeleri**: Bütün testler T_SO = **5 ns** ve **35 ns** ile koşulur (t_DV ≤ 20 + 15 ns kart/IO).
  Ayrıca T_SO = 45 ns negatif kontrol: okuma bozulmalı (testin gecikmeye duyarlı olduğunu gösterir).
- **DATA_WIDTH köşesi**: Testler bir kez de DATA_WIDTH = 16 (ve 32) core ile koşulur (driver'ın core genişliğinden bağımsızlığı).
- **Negatif kontrol**: reset testleri (T20–T22), reset'i sync yapılmış bir kopyada **kalmalı**.

### F.3 Mutation adayları (≥ 4)
| ID | Mutation | Yakalaması beklenen |
|---|---|---|
| M1 | F8 byte sırası ters (DB0 → sense[31:24]) | T03, T04, T07 |
| M2 | GOCENHYS byte sırası ters (DB1/DB0 yer değiştirmiş) | T02 (model register'ı), geri okuma |
| M3 | Settle timer clear kaybı | T18 (model settle ihlali) |
| M4 | sense_chg için önceki değer güncellenmiyor | T07 |
| M5 | Async reset değeri: cfg_done reset'te '1' ya da mr_n reset'te '0' | T01, T20 |
| M6 | CONFIG mode CPHA = 1 | model mode ihlali, okuma hatası |
| M7 | Geri okuma karşılaştırmasında bir register atlanmış | T11 |
| M8 | Beklenen sdi kelime sayısı kontrolü yok | T17 |

---

## G) Açık sorular

### Kart / sistem tarafına (K)
| # | Soru | Bilinmiyorsa varsayılan | Generic / port |
|---|---|---|---|
| K-1 | nMR FPGA'ya bağlı mı? | Bağlı varsay, sür. Bağlı değilse dahili pull-up ile pasif kalır, zararsız | HAS_MR = true |
| K-2 | Her iki entegrede her bankın modu (GND/Open mu Supply/Open mu)? | "0000" (POR değeri) | bank_mode / DEF_BANK_MODE |
| K-3 | Eşikler: GND/Open ve Supply/Open için VTHI / VTLO? | Datasheet örnekleri: GO 3,0/1,0 V (20/10), SO 5,0/2,0 V (35/15) | go_* / so_*, DEF_* |
| K-4 | VWET0..3 pinleri açık mı, hangi gerilimde? | GND/Open'da VWET açıksa VTHI ≤ 1,4 V olmalı → DEF_GO 9/5 | DEF_GO_* |
| K-5 | SPI hattı: iki HI-8436 SCK/SI/SO'yu ortak mı kullanıyor (Fig 9)? Başka entegreyle paylaşım var mı? | **Cevaplandı:** paylaşım yok. Her entegre ayrı hatta, hattındaki tek entegre (A: AD7923, B: HI-8436 #1, C: HI-8436 #2). Arbiter yok, gnt = '1', CS_IDX = 0 | CS_IDX, gnt |
| K-6 | SCK ve SO hatlarında buffer / level shifter / uzun iz var mı? Toplam gidiş-dönüş gecikmesi? | ≤ 20 ns bütçe (B.2). Aşarsa SDI_DELAY = 1 | SDI_DELAY |
| K-7 | Okuma periyodu ve kullanım: sürekli mi, sequencer tek tek mi tetikliyor? | Sequencer belirler, port | period_us, continuous |
| K-8 | Self-test ne zaman: power-up BIT, periyodik, komutla? | Komutla (self_test_req) | ST_PATTERNS |
| K-9 | Periyodik register doğrulaması / yeniden programlama politikası (s.11 NOTE)? | Doğrulama kapalı, yeniden programlama yok | VERIFY_EVERY = 0 |
| K-10 | Sequencer ham SO polaritesini mi yoksa normalize "aktif" bilgisini mi istiyor? | İkisi de çıkar (sense, sense_act) | – |
| K-11 | MISO hattında pull-up / pull-down var mı? (entegre yokken okunan değer) | Bilinmiyor; geri okuma iki durumu da yakalar | – |
| K-12 | Girişlerde debounce / filtre gereksinimi var mı? (datasheet'te yok) | Driver'da yok | – |
| K-13 | Sistem clock'u 100 MHz mi? | 100 MHz | CLKS_PER_US, CLK_DIV |
| K-14 | Self-test başarısız olunca: dur mu, işaretleyip devam mı? | Dur (err, st_fail) | – |
| K-15 | Tek okuma modunda her start'ta init istenir mi, ayar değişmediyse atlansın mı? | Her start'ta init | – |
| K-16 | FPGA I/O bankası 3,3 V mu? (VIH ≥ 0,7 × VLOGIC, s.18) | 3,3 V LVCMOS | – |

### Datasheet'te bulunamayan / belirsiz (DS), uydurulmadı
| # | Konu | Driver / model varsayımı |
|---|---|---|
| DS-1 | TMDATA ODD1 / ODD0'da **çift** girişlerin durumu yazmıyor (s.6 Tbl 5) | Self-test'te yalnız ALL1/ALL0. ODD desenleri ST_PATTERNS ile açılabilir, beklenen değer "çiftler tersi" varsayımıyla parametre |
| DS-2 | POR ve nMR sonrası SPI'ın hazır olma süresi verilmemiş | MR_WAIT_CLKS = 1 µs. Power-up sonrası start sistem tarafından verilir |
| DS-3 | Kullanılmayan register bitleri saklanıyor mu, 0 mı okunuyor? | Driver 0 yazar ve tam byte karşılaştırır, iki durumda da doğru |
| DS-4 | 0xF8 okumasında 32 bitin aynı anda yakalanıp yakalanmadığı | Bit bazında geçerli kabul edilir |
| DS-5 | PSEN değişimi ve test moduna giriş/çıkış için settle süresi (yalnız "change of threshold ≤ 1 µs" var, s.19) | Hepsi için SETTLE_CLKS (2 µs) |
| DS-6 | s.11 center formülü yazım hatası ((VTHI − VTLO)/2) | Tbl 6/7 formülü: (VTHI + VTLO)/2 |
| DS-7 | Test modundaki "high/low" iç seviyelerin programlı eşiklere göre konumu ("valid thresholds" gerekli, s.12) | ALL1 → SO = 0, ALL0 → SO = 1 varsayımı |
| DS-8 | SO için hold süresi (SCK ↓ sonrası) verilmemiş | 0 ns varsayımı. Örnekleme yine de sonraki değişimden 20 ns önce |
| DS-9 | Test modundan çıkışta band içindeki girişlerin latch durumu (s.12 NOTE: girişler net high/low olmalı) | Driver bilgilendirir. Self-test sonrası band içindeki kanallar test değerini koruyabilir (README'ye not) |
