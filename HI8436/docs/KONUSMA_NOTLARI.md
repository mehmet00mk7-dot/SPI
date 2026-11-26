# HI-8436 driver: konuşma notları

## 60 saniyelik özet
"HI-8436, 32 discrete girişi okuyan bir Holt entegresi: 4 bank × 8, her bank GND/Open ya da
Supply/Open. Bunun için ortak SPI core'umuzu (spi_exec) kullanan bir VHDL driver yazdık. Driver
entegreyi programlıyor, yazdığını geri okuyup doğruluyor ve 32 bitin hepsini tek bir 0xF8 komutuyla
2,8 µs'de okuyor. Sürekli modda okumalar tam period_us aralıkla gidiyor. Ayarlar değişmediyse start
doğrudan okumaya gidiyor, entegre her okumada reset'lenmiyor. 16 okumada bir eşik register'larını
geri okuyarak entegrenin POR ile sıfırlanmasını yakalıyor. Dahili self-test'i de destekliyor.
Doğrulama: datasheet'e göre yazdığımız bir entegre modeline karşı 28 senaryo testi ve genel
kontroller koştu. İki MISO gecikme köşesinde, core genişliği 8/16/32 ve generic varyantlarında
hepsi geçti, timing ihlali 0. RTL'e bilerek konan 12 hatanın 12'si yakalandı. Netlist'te reset'siz
flop yok. Henüz yapılmayanlar: Questa koşusu, Libero sentezi ve gerçek kartta test."

## Bölüm bölüm anlatım

### 1. Entegre ve SPI (diyagram sayfa 1, 5)
- 32 giriş, 4 bank × 8. PSEN biti 0 = GND/Open, 1 = Supply/Open (s.6 Tbl 4).
- Eşikler mod başına ortak, bank başına değil: GOCENHYS ve SOCENHYS. 6 bit center (0,1 V/LSB) ve
  6 bit hysteresis (0,2 V/LSB).
- SPI Mode 0 zorunlu (s.4), en fazla 20 MHz. CLK_DIV = 2 ile 16,67 MHz kullanıyoruz; bir altı
  (25 MHz) ihlal olurdu.
- Her CS çerçevesinde tek instruction (s.5). Bizim paket yapımıza birebir uyuyor.
- Polarite: GND/Open bankında 1 = toprak, Supply/Open bankında 1 = açık (besleme yok). Bu yüzden
  ham `sense`'in yanında normalize `sense_act` de veriyoruz.

### 2. Core ile eşleme (sayfa 2, 5)
- Her byte bir core kelimesi (word_length 8). Opcode bir TRANSFER, veri ayrı bir TRANSFER; CS arada
  aktif kalıyor.
- Sonuç: driver core'un DATA_WIDTH'inden bağımsız. Paylaşılan core 16 bit (AD7923) olsa da çalışır;
  8/16/32 test edildi.
- Paket: `2002 2100 2208 11FE` + TRANSFER(ler) + `11FF 30nn`. CONFIG her pakette yeniden yazılıyor,
  hat paylaşılsa bile güvenli.

### 3. Driver iç yapısı (sayfa 3, 4)
- **Kontrol FSM'i** neyin yapılacağına karar verir. **Paket tanımı** opcode ve veriyi seçer.
  **Packer** core komutlarını üretir, SYNC id'yi ve beklenen sdi kelime sayısını kontrol eder.
- Timer'lar: settle 2 µs, period, SYNC timeout 10 µs, nMR.
- Reset: async aktif-düşük rst_n. Core reset'i tek bir flop'tan geliyor (p_core_resetn).
- Hata sınıfları:
  - Veri hatası (geri okuma, doğrulama, self-test): tekrar dene ya da dur.
  - Yapısal hata (SYNC timeout, yanlış SYNC, beklenmeyen ya da eksik sdi): hemen dur. Timeout'ta
    core reset'lenir.

### 4. Init politikası (sayfa 6)
- Tam init (nMR + 5 yaz + 5 geri oku) yalnız şu durumlarda: açılış, hata sonrası, POR tespiti,
  self-test hatası.
- Ayar değiştiyse yalnız değişen register yazılıp geri okunuyor; nMR yok.
- Ayarlar aynıysa start doğrudan okumaya gidiyor: 2,8 µs.
- Neden: tek okuma kullanımında her okumada 16,5 µs init olmasın, entegre reset'lenmesin, band
  içindeki kanalların hysteresis durumu korunsun.
- Eski davranış INIT_EVERY_START = true ile seçilebiliyor.

### 5. POR tespiti
- Doğrudan okuma yolu açıldığı için, entegre besleme kesintisiyle sıfırlanırsa bunu periyodik
  doğrulama yakalıyor.
- 16 okumada bir 5 register geri okunuyor, eşikler dahil. Geçerli bir eşik asla 0x00 değil, bu
  yüzden POR kesin yakalanıyor.
- Tespit gecikmesi en fazla 16 okuma. Tek okuma kullanımında sayaç start'lar arasında sürüyor.
- Yakalanınca kod 3 ve hemen tam init.

### 6. Doğrulama
- **Model:** Datasheet'teki protokolü, register'ları, sense / hysteresis / test modunu uyguluyor.
  Ayrıca AC timing tablosunun hepsini kontrol ediyor: tCYC, tSCKH/L, tCES, tCHH, tCEH, tCPH, tDS,
  tDH, tMR, Mode 0, reserved opcode, chaining, settle. Hata enjeksiyon kancaları var.
- **Testler:** T01–T28 + genel kontroller. Normal akış, polarite, hysteresis, period, ayar
  değişikliği, stop, her hata türü, self-test, POR, init politikası; reset frame ortasında, clock
  dururken ve 1 clock'luk.
- **Köşeler:**
  - MISO gecikmesi 5 / 35 ns,
  - DATA_WIDTH 16 / 32,
  - HAS_MR = false,
  - model kullanılmayan bitleri saklıyor (UNUSED_STORE = 1),
  - INIT_EVERY_START = true.
  - Negatif köşe 45 ns kalıyor; testler gecikmeye duyarlı.
- **Mutation:** 12/12 yakalandı.
- **Negatif kontrol:** Reset'i sync yapılmış kopyada reset testleri kalıyor, flop kontrolü başarısız.
- **Flop kontrolü:** Sentez netlist'inde 100 grup / 505 bit; reset'siz ya da türetilmiş reset'li
  flop yok.
- Simülasyon GHDL'nin sentezlediği netlist üzerinde (Icarus) koştu.

## Ezber sayılar
| Ne | Değer |
|---|---|
| SCLK | 16,67 MHz (CLK_DIV = 2), datasheet ≤ 20 MHz |
| F8 okuma | 40 SCK, CS low 2,58 µs, paket 2,76 µs, arka arkaya 2,8 µs (~357 kHz) |
| start → veri | doğrudan 2,8 µs; kısmi 6,2–6,7 µs (tek register) / 12,8 µs (üçü); tam init 19,3 µs |
| Tam init | ≈ 16,5 µs cfg_done (nMR 0,2 + 1 µs dahil) |
| Self-test | ≈ 18 µs (ANALIZ tahmini, ölçülmedi); ALL1 → 0, ALL0 → FFFFFFFF |
| En dar timing marjı | tCYC 60 / 50 ns (+%20); MISO penceresi 40 ns, bütçe 20 ns |
| Diğer timing | tCES 120, tCHH 100, tCEH 70, tCPH 210 ns (datasheet ≥ 5 / 5 / 5 / 55) |
| Settle | 2 µs (datasheet ≤ 1 µs) |
| SYNC timeout | 10 µs (en uzun paket 2,76 µs) |
| POR tespiti | ≤ 16 okuma (T28: 13 / 2 / 16; tek okumada 12. start) |
| Test / köşe | 28 test + G, 9 köşe, hepsi 29/29, ihlal 0 |
| Mutation | 12/12 + sync reset negatif kontrolü |
| Flop | 100 grup / 505 bit, düz flop 0 |
| Varsayılan eşikler | GND/Open 1,4 / 0,4 V (9 / 5); Supply/Open 5,0 / 2,0 V (35 / 15) |

## Gelebilecek sorular

**S: Neden 0xF8, bank bank okuma değil?**
C: Tek frame 2,76 µs. Dört bank ayrı ayrı okunsa 4 frame, ≈ 5,3 µs. Bank bank okumada 32 bitin aynı
anda okunmaması da eklenirdi.

**S: Sense verisinde hata tespiti var mı?**
C: Yok, olamaz: 32 bitin hepsi veri, parity ya da sabit bit yok (s.10 Tbl 12). Korumalar dolaylı:
init geri okuması, 16 okumada bir register doğrulaması (POR) ve self-test. Bunu açıkça yazdık.

**S: Entegre takılı değilse ya da MISO kopuksa?**
C: Init geri okuması tutmaz. Eşik register'ı hiçbir zaman 0x00 olmadığı için MISO sabit 0 da olsa
fark edilir. Kod 2 verilir, 4 denemeden sonra driver durur.

**S: Neden her start'ta init yapmıyorsunuz?**
C: Tek okumada 16,5 µs boşa gidiyordu ve nMR hysteresis latch'ini sıfırlıyorsa band içindeki
kanallar her seferinde 0 okunuyordu. Artık init yalnız açılışta, hatadan sonra ve POR tespitinde.
Gerekirse INIT_EVERY_START = true ile eski davranış seçilir.

**S: Entegre besleme kesintisiyle sıfırlanırsa?**
C: 16 okuma içinde periyodik doğrulama yakalar (kod 3) ve hemen tam init yapar. VERIFY_EVERY = 0
yapılırsa fark edilmez; README'de risk olarak yazılı.

**S: MISO zamanlaması yeter mi?**
C: Core, SO'yu SCK düşen kenarından 40 ns sonra örnekliyor. Datasheet t_DV ≤ 20 ns, yani kart ve
FPGA I/O için 20 ns kalıyor. 5 ve 35 ns köşelerinde test edildi; 45 ns'de bilerek kaldığını
gösterdik. Kart gecikmesi büyükse SDI_DELAY generic'i var.

**S: İki HI-8436 nasıl bağlanacak?**
C: Top tek entegre için. Sistemde iki instance olacak. Driver'da arbiter için req/gnt hazır, ama
arbiter henüz yazılmadı.

**S: Self-test ne kontrol ediyor?**
C: Comparator girişleri test desenine zorlanıyor: ALL1 → 0x00000000, ALL0 → 0xFFFFFFFF. Bu,
comparator, latch ve SPI okuma yolunu test eder; giriş pinlerinin kendisini test etmez (datasheet:
pin 200 kΩ ile izole). ODD desenlerinde çift girişlerin durumu datasheet'te yazmadığı için onları
kullanmadık.

**S: Bu Questa'da ya da donanımda koştu mu?**
C: Hayır. GHDL'nin sentezlediği netlist Icarus'ta simüle edildi. Questa `.do` dosyası hazır ama
koşulmadı. Libero sentezi ve kart testi de yapılmadı. Sıradaki adımlar bunlar.

**S: Model sizin yazdığınız bir model; model yanlışsa?**
C: Doğru, model datasheet yorumumuza dayanıyor; kart testi bunu doğrulayacak. Belirsiz noktaları
(DS-1..DS-10) listeledik. Modelin kendi hatalarını da bulup düzelttik: nMR X → 1 geçişi, ölçüm
örnekleme anı. Bunlar SONUCLAR.txt'de.

**S: DS-10 nedir?**
C: nMR'ın hysteresis latch'ini sıfırlayıp sıfırlamadığı datasheet'te açık değil. Model sıfırladığını
varsayıyor. Yeni politikayla nMR yalnız açılışta ve hata sonrasında verildiği için etki o ilk
okumayla sınırlı.

## Söyleme / söyle
| Söyleme | Söyle |
|---|---|
| "Driver doğrulandı, hazır" | "Modele karşı simülasyonda doğrulandı; Questa, Libero ve kart testi yapılmadı" |
| "Questa'da geçti" | "GHDL netlist + Icarus'ta geçti; Questa `.do` hazır, koşulmadı" |
| "Sentezlenebilir, kaynak kullanımı X" | "GHDL sentezinde temiz, flop yapısı kontrol edildi; Libero raporu yok" |
| "Gerçek entegrede çalışıyor" | "Datasheet'e göre yazdığımız modelde çalışıyor; kart testi bekliyor" |
| "Sense verisi hatalara karşı korumalı" | "Sense verisinde kontrol yok; geri okuma, periyodik doğrulama ve self-test var" |
| "İki entegreyi ve AD7923'ü aynı hatta sürüyor" | "req/gnt arayüzü hazır; arbiter henüz yazılmadı, top'ta gnt = '1'" |
| "Self-test girişleri test ediyor" | "Self-test comparator, latch ve okuma yolunu test ediyor; pinleri değil" |
| "nMR latch'i sıfırlıyor" | "Belirsiz (DS-10); model öyle varsayıyor, kartta doğrulanacak" |
| "Debounce var" | "Debounce yok (K-12); datasheet'te de filtre yok, gerekirse sistem tarafında" |
| "Bütün hatalar yakalanıyor" | "Yapısal hatalar ve register uyuşmazlıkları yakalanıyor; 12 mutation'ın 12'si yakalandı" |
