-- ============================================================================
-- hi8436_drv.vhd  -  HI-8436 (32 kanal GND/Open - Supply/Open discrete sensör) driver'ı
--
-- Hedef: Microchip PolarFire / Libero SoC, 100 MHz tek clock, asenkron aktif-düşük
-- reset (rst_n). SPI tarafı ortak core spi_exec'in (common/rtl/async) komut arayüzüdür.
-- Datasheet: Holt HI-8436, DS8436 Rev. L (06/26). Analiz ve onaylı arayüz:
-- HI8436/docs/ANALIZ.md. Aşağıda "s.N" = datasheet sayfası.
--
-- GENEL AKIŞ
--   start ile ayarlar (bank_mode, eşik kodları) latch'lenir ve kontrol edilir; driver
--   entegreyi programlar, geri okuyup doğrular, sonra 0xF8 (Read All Banks) ile 32 bitlik
--   sense kelimesini okur. continuous = '1' ise okuma period_us aralıkla tekrarlanır.
--
--     start/stop/ayar --> Control FSM --frm_go + paket tanımı--> Packer --cmd/sdo--> spi_exec
--                            ^                                    |  ^
--                            |                     pk_ok (SYNC)   |  | sdi_data / sync
--     sense/sense_chg <-- Output reg <-- rx_sh (alınan byte'lar) <-+--+
--
-- PAKETLER (her paket = tek CS çerçevesi = tek HI-8436 instruction, s.5 "chaining yok")
--   CONFIG clk_div, CONFIG mode (Mode 0, s.4), CONFIG word_length (8), CS aktif,
--   TRANSFER W (opcode [+ veri byte'ları]) [, TRANSFER R (veri byte'ları)], CS pasif, SYNC id.
--   Her byte bir core kelimesi (word_length = 8); sdo kelimesi = byte (sıfırla genişletilmiş,
--   core MSB'ye hizalar), sdi kelimesinin yalnız [7:0]'ı kullanılır (ANALIZ.md D.1).
--   Yazma: opcode, (DB1), DB0 tek TRANSFER'de. Okuma: opcode TRANSFER W, veri TRANSFER R.
--   0xF8 cevabı DB3..DB0 = SO<31:24>..SO<7:0> sırasıyla gelir (s.10 Tbl 12).
--
-- INIT SIRASI (start'ta; ANALIZ.md E.3)
--   [nMR pulse (HAS_MR) + bekleme] -> yazma: CTRL=00, PSEN=bank_mode, GOCENHYS, SOCENHYS,
--   TMDATA=00 (s.6-8 Tbl 3-7) -> geri okuma 82, 84, BA, BC, 9E ve tam byte karşılaştırma
--   -> settle (son yazmadan itibaren SETTLE_CLKS, s.19 "change of threshold <= 1 us")
--   -> cfg_done -> okuma(lar).
--
-- SELF-TEST (self_test_req; s.6 Tbl 5, s.12 Test Mode)
--   TMDATA=ALL1 -> CTRL.TEST=1 -> settle -> F8 = 0x00000000 bekle -> TMDATA=ALL0 -> settle
--   -> F8 = 0xFFFFFFFF bekle -> CTRL=00 -> TMDATA=00. Test "high" girişi her iki modda SO=0,
--   "low" girişi SO=1 verir (s.11 Tbl 14), beklenen değer bank modundan bağımsızdır.
--   Self-test atomiktir: stop, test modundan çıkış yazmaları bitene kadar bekletilir.
--   Başarısızsa st_fail, err (SELFTEST_FAIL) ve driver durur (test modundan çıkılarak).
--
-- ZAMANLAMA (varsayılan generic'lerle, 100 MHz; ANALIZ.md D.3)
--   SCLK 16,67 MHz (CLK_DIV = 2, s.19 tCYC >= 50 ns). Paket (launch -> SYNC): yazma
--   1/2 byte 1,31/1,79 us, okuma 1/2 byte 1,33/1,81 us, F8 2,77 us. Init ~15 us (+1,2 us nMR).
--   Sürekli modda okuma launch'ları arası tam period_us (period_us küçükse arka arkaya).
--
-- RESET STRATEJİSİ
--   * rst_n kaynağı: projedeki reset synchronizer. Async assert, sync deassert (clk'a göre),
--     PLL lock'a bağlı.
--   * Bütün clocked process'ler kalıbı:
--       process(clk, rst_n) begin
--         if rst_n = '0' then <bütün register'lar>
--         elsif rising_edge(clk) then ...
--     Process içinde atanan her register reset listesindedir; initial value yoktur.
--   * Async reset olarak YALNIZCA rst_n port'u kullanılır. İç soft reset'ler (settle timer
--     clear'ı, period timer clear'ı, core_rst) senkron mantıktır.
--   * core_rst (SYNC timeout sonrası) senkron bir register'dır; core'a hi8436_top'taki
--     p_core_resetn flop'u üzerinden bir clock gecikmeli ve senkron ulaşır.
--   * rst_n düşer düşmez (clock beklemeden) busy, err, err_code, cfg_done, sense*,
--     sense_valid, st_done, st_fail, req, core_rst '0' ve mr_n '1' olur. Reset kalkınca
--     driver ST_IDLE'da start bekler, kendiliğinden başlamaz.
--
-- HATALAR (err_code, bit 3 = yapısal; ANALIZ.md E.4)
--   0x1 CFG_RANGE       : eşik kodu geçersiz (HYS >= 1, CVAL+HYS <= 52, CVAL-HYS >= 4;
--                         s.7 Tbl 6 Note), yalnız kullanılan mod için. start reddedilir.
--   0x2 RB_MISMATCH     : init geri okuma uyuşmazlığı. Veri hatası: init tekrarlanır,
--                         art arda ERR_LIMIT kez -> durur.
--   0x3 VERIFY_MISMATCH : periyodik doğrulamada uyuşmazlık (VERIFY_EVERY > 0) -> yeniden init.
--   0x4 SELFTEST_FAIL   : self-test sonucu beklenenden farklı -> durur.
--   0x8 SYNC_TIMEOUT    : launch'tan SYNC_TO_CLKS içinde SYNC yok -> core_rst, durur.
--   0x9 SYNC_ID         : beklenmeyen anda ya da yanlış id'li SYNC -> durur.
--   0xA SDI_UNEXPECTED  : beklenmeyen sdi kelimesi (FIFO underflow karşılığı) -> durur.
--   0xB SDI_MISSING     : SYNC geldi ama beklenen sayıda sdi kelimesi gelmedi -> durur.
--   err ve err_code ilk hatayı tutar (sticky), yeni start / self_test_req ile temizlenir.
--   Sense okumasında veri kontrolü yoktur: 32 bitin hepsi veridir (s.10 Tbl 12).
--
-- Kodlama: VHDL-2008, muhafazakâr yazım (numeric_std, process(all) yok, port tipleri
-- std_logic / std_logic_vector, iç aritmetik unsigned / integer).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hi8436_drv is
  generic (
    CLKS_PER_US   : integer := 100;   -- 100 MHz -> 1 us = 100 clk
    CLK_DIV       : integer := 2;     -- SCLK = 100 MHz / (2*(CLK_DIV+1)) = 16,67 MHz (<= 20 MHz, s.19)
    CS_T          : integer := 1;     -- CS komutundaki bekleme (SCLK periyodu), tCEH/tCPH marjı
    CS_IDX        : integer := 0;     -- kullanılan chip select numarası (0..7)
    DATA_WIDTH    : integer := 8;     -- core kelime genişliği (8..32); word_length her zaman 8
    HAS_MR        : boolean := true;  -- true: init başında nMR pulse'ı verilir
    MR_CLKS       : integer := 20;    -- nMR low süresi (200 ns >= 100 ns, s.19 tMR)
    MR_WAIT_CLKS  : integer := 100;   -- nMR sonrası bekleme (1 us; datasheet vermiyor, DS-2)
    SETTLE_CLKS   : integer := 200;   -- yazma -> F8 okuma arası min (2 us >= 1 us, s.19)
    SYNC_TO_CLKS  : integer := 1000;  -- paket launch -> SYNC timeout (10 us; en uzun paket 2,77 us)
    CORE_RST_CLKS : integer := 4;     -- SYNC timeout sonrası core_rst pulse genişliği
    ERR_LIMIT     : integer := 4;     -- art arda veri hatası limiti
    VERIFY_EVERY  : integer := 0      -- >0: her VERIFY_EVERY okumada bir config geri okuması
  );
  port (
    clk           : in  std_logic;                      -- 100 MHz sistem clock'u
    rst_n         : in  std_logic;                      -- async aktif-düşük reset (synchronizer)
    -- kontrol (sistem tarafı, clk ile senkron)
    start         : in  std_logic;                      -- ST_IDLE'da init + okuma başlatır
    stop          : in  std_logic;                      -- launch olmamış paket iptal, sonra IDLE
    continuous    : in  std_logic;                      -- '1': okuma period_us aralıkla tekrarlanır
    period_us     : in  std_logic_vector(15 downto 0);  -- okuma launch'ları arası us (her okumada örneklenir)
    bank_mode     : in  std_logic_vector(3 downto 0);   -- PSEN<3:0>: 1 = Supply/Open (s.6 Tbl 4), start'ta latch
    go_center     : in  std_logic_vector(5 downto 0);   -- GOCVAL (0,1 V/LSB, s.7 Tbl 6), start'ta latch
    go_hyst       : in  std_logic_vector(5 downto 0);   -- GOHYS  (0,2 V/LSB)
    so_center     : in  std_logic_vector(5 downto 0);   -- SOCVAL (s.8 Tbl 7)
    so_hyst       : in  std_logic_vector(5 downto 0);   -- SOHYS
    self_test_req : in  std_logic;                      -- self-test isteği (IDLE'da init ile, çalışırken sıradaki okuma yerine)
    -- sonuç
    sense         : out std_logic_vector(31 downto 0);  -- son okuma, ham SO<31:0> (kalıcı register)
    sense_valid   : out std_logic;                      -- 1 clk: sense / sense_chg / sense_act yeni
    sense_chg     : out std_logic_vector(31 downto 0);  -- yeni sense xor önceki sense
    sense_act     : out std_logic_vector(31 downto 0);  -- normalize: 1 = aktif (sense xor bank modu)
    cfg_done      : out std_logic;                      -- entegre programlandı ve doğrulandı
    busy          : out std_logic;                      -- '1': ST_IDLE dışında
    err           : out std_logic;                      -- sticky hata
    err_code      : out std_logic_vector(3 downto 0);   -- ilk hatanın kodu
    st_done       : out std_logic;                      -- 1 clk: self-test bitti
    st_fail       : out std_logic;                      -- self-test başarısız (sticky)
    mr_n          : out std_logic;                      -- HI-8436 nMR (aktif-düşük)
    -- SPI master (spi_exec) tarafı
    req           : out std_logic;                      -- SPI master isteği (arbiter için)
    gnt           : in  std_logic;                      -- arbiter izni (hi8436_top'ta sabit '1')
    cmd           : out std_logic_vector(15 downto 0);  -- spi_exec komut kelimesi
    cmd_valid     : out std_logic;
    cmd_ready     : in  std_logic;
    sdo_data      : out std_logic_vector(DATA_WIDTH - 1 downto 0);  -- MOSI kelimesi (byte, [7:0])
    sdo_valid     : out std_logic;
    sdo_ready     : in  std_logic;
    sdi_data      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);  -- MISO kelimesi ([7:0] kullanılır)
    sdi_valid     : in  std_logic;                      -- (sdi_data_ready top'ta '1')
    sync          : in  std_logic_vector(7 downto 0);   -- SYNC komutunun id'si (paket sonu)
    sync_valid    : in  std_logic;                      -- (sync_ready top'ta '1')
    core_rst      : out std_logic                       -- SYNC timeout sonrası core reset isteği
  );
end entity hi8436_drv;

architecture rtl of hi8436_drv is

  -- --------------------------------------------------------------------------
  -- spi_exec komut kodlaması: cmd = op(15:12) & "00" & arg(9:8) & val(7:0)
  -- --------------------------------------------------------------------------
  constant C_OP_TRANSFER : std_logic_vector(3 downto 0) := "0000";
  constant C_OP_CS       : std_logic_vector(3 downto 0) := "0001";
  constant C_OP_CONFIG   : std_logic_vector(3 downto 0) := "0010";
  constant C_OP_MISC     : std_logic_vector(3 downto 0) := "0011";
  constant C_CFG_CLK_DIV : std_logic_vector(1 downto 0) := "00";
  constant C_CFG_MODE    : std_logic_vector(1 downto 0) := "01";
  constant C_CFG_WORDLEN : std_logic_vector(1 downto 0) := "10";
  constant C_XFER_W      : std_logic_vector(1 downto 0) := "01";  -- TRANSFER: yalnız yazma
  constant C_XFER_R      : std_logic_vector(1 downto 0) := "10";  -- TRANSFER: yalnız okuma
  constant C_MISC_SYNC   : std_logic_vector(1 downto 0) := "00";
  constant C_CS_ALL_OFF  : std_logic_vector(7 downto 0) := x"FF";
  constant C_SPI_MODE0   : std_logic_vector(7 downto 0) := x"00";  -- CPHA=0, CPOL=0, SDO idle=0 (s.4)
  constant C_WORD_LEN    : integer := 8;                             -- her HI-8436 byte'ı bir kelime

  function mk_cmd(op : std_logic_vector(3 downto 0); arg : std_logic_vector(1 downto 0);
                  val : std_logic_vector(7 downto 0)) return std_logic_vector is
  begin
    return op & "00" & arg & val;
  end function;

  -- CS komutu değeri: yalnız idx numaralı CS hattı aktif ('0')
  function cs_on_mask(idx : integer) return std_logic_vector is
    variable m : std_logic_vector(7 downto 0) := C_CS_ALL_OFF;
  begin
    m(idx) := '0';
    return m;
  end function;

  function imax(a, b : integer) return integer is
  begin
    if a > b then return a; else return b; end if;
  end function;

  -- Paketin sabit komutları (yorumdaki değerler varsayılan generic'lerle)
  constant C_CMD_CLK_DIV : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CONFIG, C_CFG_CLK_DIV, std_logic_vector(to_unsigned(CLK_DIV, 8)));     -- 0x2002
  constant C_CMD_MODE    : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CONFIG, C_CFG_MODE, C_SPI_MODE0);                                      -- 0x2100
  constant C_CMD_WORDLEN : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CONFIG, C_CFG_WORDLEN, std_logic_vector(to_unsigned(C_WORD_LEN, 8)));  -- 0x2208
  constant C_CMD_CS_ON   : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CS, std_logic_vector(to_unsigned(CS_T, 2)), cs_on_mask(CS_IDX));       -- 0x11FE
  constant C_CMD_CS_OFF  : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CS, std_logic_vector(to_unsigned(CS_T, 2)), C_CS_ALL_OFF);             -- 0x11FF

  -- Paket indeksleri (pk_idx). Yazma paketinde 5 (TRANSFER R) atlanır:
  --   0 CONFIG clk_div (handshake'i = launch), 1 CONFIG mode, 2 CONFIG word length,
  --   3 CS aktif, 4 TRANSFER W, 5 TRANSFER R, 6 CS pasif, 7 SYNC id
  constant C_PK_CLK_DIV : integer := 0;
  constant C_PK_XFER_W  : integer := 4;
  constant C_PK_XFER_R  : integer := 5;
  constant C_PK_CS_OFF  : integer := 6;
  constant C_PK_SYNC    : integer := 7;

  -- HI-8436 opcode'ları (s.3 Tbl 2)
  constant C_OP_W_CTRL  : std_logic_vector(7 downto 0) := x"02";
  constant C_OP_W_PSEN  : std_logic_vector(7 downto 0) := x"04";
  constant C_OP_W_GO    : std_logic_vector(7 downto 0) := x"3A";
  constant C_OP_W_SO    : std_logic_vector(7 downto 0) := x"3C";
  constant C_OP_W_TM    : std_logic_vector(7 downto 0) := x"1E";
  constant C_OP_R_CTRL  : std_logic_vector(7 downto 0) := x"82";
  constant C_OP_R_PSEN  : std_logic_vector(7 downto 0) := x"84";
  constant C_OP_R_GO    : std_logic_vector(7 downto 0) := x"BA";
  constant C_OP_R_SO    : std_logic_vector(7 downto 0) := x"BC";
  constant C_OP_R_TM    : std_logic_vector(7 downto 0) := x"9E";
  constant C_OP_R_ALL   : std_logic_vector(7 downto 0) := x"F8";
  -- CTRL ve TMDATA değerleri (s.6 Tbl 3, Tbl 5)
  constant C_CTRL_NORM  : std_logic_vector(7 downto 0) := x"00";  -- SRST=0, TEST=0
  constant C_CTRL_TEST  : std_logic_vector(7 downto 0) := x"01";  -- TEST=1
  constant C_TM_NONE    : std_logic_vector(7 downto 0) := x"00";
  constant C_TM_ALL1    : std_logic_vector(7 downto 0) := x"02";  -- bütün girişler high -> SO=0
  constant C_TM_ALL0    : std_logic_vector(7 downto 0) := x"01";  -- bütün girişler low  -> SO=1
  constant C_ST_EXP_ALL1 : std_logic_vector(31 downto 0) := x"00000000";
  constant C_ST_EXP_ALL0 : std_logic_vector(31 downto 0) := x"FFFFFFFF";

  -- Eşik kodu geçerliliği (s.7 Tbl 6 Note): VTHI-VTLO >= 0,2 V -> HYS >= 1,
  -- VTHI <= 5,2 V -> CVAL+HYS <= 52, VTLO >= 0,4 V -> CVAL-HYS >= 4.
  -- Bu üçü VTHI >= 0,6 V ve VTLO <= 5,0 V sınırlarını da sağlar (ANALIZ.md C.1).
  function thr_ok(c, h : std_logic_vector(5 downto 0)) return boolean is
    variable ci, hi : integer;
  begin
    ci := to_integer(unsigned(c));
    hi := to_integer(unsigned(h));
    return hi >= 1 and ci + hi <= 52 and ci - hi >= 4;
  end function;

  -- Bank modunu 32 bite genişletir: bit (8b+k) = bank_mode(b)
  function expand_bm(bm : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(31 downto 0);
  begin
    for b in 0 to 3 loop
      r(8 * b + 7 downto 8 * b) := (others => bm(b));
    end loop;
    return r;
  end function;

  -- Period timer: ST_PERIOD'da per_ok görülmesinden okuma paketinin launch'ına kadar
  -- 4 clk FSM/packer gecikmesi var (per_ok -> ST_READ -> frm_go -> PK_CMD -> handshake);
  -- prescaler'ın launch'taki başlangıç değeriyle telafi edilir. Launch'lar arası tam
  -- period_us * CLKS_PER_US clk olur (tb T06 ölçer).
  constant C_PER_LAT : integer := 4;

  constant C_TMR_MAX : integer := imax(imax(MR_CLKS, MR_WAIT_CLKS), 1);
  constant C_VFY_MAX : integer := imax(VERIFY_EVERY, 1);
  constant C_TEST_LAST : integer := 9;     -- self-test alt adımları 0..9

  -- err_code değerleri
  constant C_E_NONE     : std_logic_vector(3 downto 0) := x"0";
  constant C_E_RANGE    : std_logic_vector(3 downto 0) := x"1";
  constant C_E_RB       : std_logic_vector(3 downto 0) := x"2";
  constant C_E_VERIFY   : std_logic_vector(3 downto 0) := x"3";
  constant C_E_SELFTEST : std_logic_vector(3 downto 0) := x"4";
  constant C_E_TIMEOUT  : std_logic_vector(3 downto 0) := x"8";
  constant C_E_SYNC_ID  : std_logic_vector(3 downto 0) := x"9";
  constant C_E_SDI_UNEX : std_logic_vector(3 downto 0) := x"A";
  constant C_E_SDI_MISS : std_logic_vector(3 downto 0) := x"B";

  -- --------------------------------------------------------------------------
  -- Control FSM durumları
  --   ST_IDLE     : start / self_test_req bekler; ayarları latch'ler ve kontrol eder
  --   ST_MR_PULSE : nMR low (MR_CLKS)             ST_MR_WAIT : nMR sonrası bekleme
  --   ST_CFG_WR   : 5 yazma paketi (idx 0..4)      ST_CFG_RD  : 5 geri okuma paketi
  --   ST_SETTLE   : son yazmadan itibaren SETTLE_CLKS bekleme
  --   ST_TEST     : self-test alt adımları (idx 0..9)
  --   ST_READ     : F8 okuma paketi               ST_PERIOD  : period bekleme
  --   ST_CORE_RST : SYNC timeout sonrası core_rst pulse'ı
  -- --------------------------------------------------------------------------
  type st_t is (ST_IDLE, ST_MR_PULSE, ST_MR_WAIT, ST_CFG_WR, ST_CFG_RD, ST_SETTLE,
                ST_TEST, ST_READ, ST_PERIOD, ST_CORE_RST);
  signal state       : st_t;
  signal idx         : integer range 0 to C_TEST_LAST;      -- paket / alt adım indeksi
  signal tmr         : integer range 0 to C_TMR_MAX - 1;     -- nMR pulse / bekleme sayacı

  -- start'ta latch'lenen ayarlar
  signal bm_r        : std_logic_vector(3 downto 0);
  signal goc_r       : std_logic_vector(5 downto 0);
  signal goh_r       : std_logic_vector(5 downto 0);
  signal soc_r       : std_logic_vector(5 downto 0);
  signal soh_r       : std_logic_vector(5 downto 0);
  signal period_cur  : unsigned(15 downto 0);                -- bu okumanın period'u

  signal err_r       : std_logic;
  signal err_code_r  : std_logic_vector(3 downto 0);
  signal err_cnt     : integer range 0 to ERR_LIMIT - 1;     -- art arda veri hatası
  signal cfg_done_r  : std_logic;
  signal st_done_r   : std_logic;
  signal st_fail_r   : std_logic;
  signal st_bad      : std_logic;                            -- bu self-test'te uyuşmazlık görüldü
  signal st_pend     : std_logic;                            -- self-test istendi, bekliyor
  signal rd_owed     : std_logic;                            -- start'ın istediği okuma henüz yapılmadı
  signal vfy         : std_logic;                            -- ST_CFG_RD periyodik doğrulama için
  signal rb_bad      : std_logic;                            -- bu geri okuma turunda uyuşmazlık
  signal rd_cnt      : integer range 0 to C_VFY_MAX - 1;     -- doğrulamaya kadar okuma sayısı
  signal stop_pend   : std_logic;
  signal mr_n_r      : std_logic;
  signal core_rst_r  : std_logic;
  signal rst_cnt     : integer range 0 to CORE_RST_CLKS - 1;

  -- FSM -> packer paket isteği; paket tanımı (dsc_*) state/idx'ten kombinasyonel çıkar
  -- ve frm_pend boyunca sabittir
  signal frm_go      : std_logic;                            -- 1 clk: packer'a paket başlat
  signal frm_pend    : std_logic;                            -- paket istendi, sonuç bekleniyor
  signal frm_cancel  : std_logic;                            -- launch öncesi stop: paket iptali
  signal dsc_rd      : std_logic;                            -- '1': okuma paketi
  signal dsc_n       : integer range 1 to 4;                 -- veri byte sayısı (Tbl 2)
  signal dsc_op      : std_logic_vector(7 downto 0);         -- opcode
  signal dsc_d1      : std_logic_vector(7 downto 0);         -- yazma DB1 (2 byte'lık yazmada)
  signal dsc_d0      : std_logic_vector(7 downto 0);         -- yazma DB0
  signal rb_exp      : std_logic_vector(15 downto 0);        -- geri okumada beklenen {DB1, DB0}
  signal st_exp      : std_logic_vector(31 downto 0);        -- self-test F8'de beklenen
  signal start_ok    : std_logic;                            -- giriş eşik kodları geçerli

  -- timer'lar
  signal stl_cnt     : integer range 0 to SETTLE_CLKS - 1;   -- son yazmadan beri clk
  signal stl_ok      : std_logic;
  signal per_pre     : integer range 0 to CLKS_PER_US - 1;   -- us prescaler
  signal per_us      : unsigned(15 downto 0);                -- okuma launch'ından beri us
  signal per_rst     : std_logic;
  signal per_ok      : std_logic;

  -- packer
  type pk_st_t is (PK_IDLE, PK_CMD, PK_WAIT);
  signal pk_st       : pk_st_t;
  signal pk_idx      : integer range 0 to C_PK_SYNC;
  signal pk_rd       : std_logic;
  signal pk_n        : integer range 1 to 4;
  signal pk_op       : std_logic_vector(7 downto 0);
  signal pk_d1       : std_logic_vector(7 downto 0);
  signal pk_d0       : std_logic_vector(7 downto 0);
  signal pk_launched : std_logic;                            -- launch oldu, SYNC bekleniyor
  signal sync_id     : unsigned(7 downto 0);                 -- paket başına 1 artan SYNC id
  signal cmd_i       : std_logic_vector(15 downto 0);
  signal cmd_valid_i : std_logic;
  signal cmd_hs      : std_logic;
  signal frm_launch  : std_logic;                            -- ilk komut kabul edildi (1 clk)
  signal sq0, sq1, sq2 : std_logic_vector(7 downto 0);       -- sdo byte kuyruğu
  signal sq_cnt      : integer range 0 to 3;
  signal sdo_valid_r : std_logic;
  signal to_cnt      : integer range 0 to SYNC_TO_CLKS - 1;  -- SYNC timeout sayacı
  signal exp_cnt     : integer range 0 to 4;                 -- beklenen sdi kelimesi
  signal rx_sh       : std_logic_vector(31 downto 0);        -- alınan byte'lar (son byte [7:0])
  signal frm_done    : std_logic;                            -- doğru id'li SYNC (1 clk)
  signal pk_ok       : std_logic;                            -- paket hatasız bitti (1 clk)

  -- yapısal hatalar
  signal to_hit      : std_logic;
  signal sync_err    : std_logic;
  signal sdi_unexp   : std_logic;
  signal sdi_miss    : std_logic;
  signal struct_err  : std_logic;
  signal struct_code : std_logic_vector(3 downto 0);

  -- çıkış register'ları
  signal sense_r     : std_logic_vector(31 downto 0);
  signal sense_chg_r : std_logic_vector(31 downto 0);
  signal sense_act_r : std_logic_vector(31 downto 0);
  signal sense_vld_r : std_logic;
  signal rd_done     : std_logic;                            -- F8 okuma paketi bitti (1 clk)

  signal stop_now    : std_logic;

begin

  -- ==========================================================================
  -- Yardımcı kombinasyonel sinyaller
  -- ==========================================================================
  stop_now <= stop or stop_pend;

  -- giriş eşik kodlarının geçerliliği: yalnız kullanılan mod kontrol edilir
  -- (bank_mode = 1111 ise GND/Open, 0000 ise Supply/Open kullanılmaz)
  start_ok <= '1' when (bank_mode = "1111" or thr_ok(go_center, go_hyst)) and
                       (bank_mode = "0000" or thr_ok(so_center, so_hyst))
              else '0';

  -- yapısal hata ve kodu (aynı anda birden fazlaysa öncelik sırası)
  struct_err  <= to_hit or sync_err or sdi_unexp or sdi_miss;
  struct_code <= C_E_TIMEOUT  when to_hit = '1' else
                 C_E_SYNC_ID  when sync_err = '1' else
                 C_E_SDI_UNEX when sdi_unexp = '1' else
                 C_E_SDI_MISS;

  -- stop, launch olmamış paketi iptal eder (self-test hariç: test modundan çıkış atomik)
  frm_cancel <= '1' when frm_pend = '1' and stop_pend = '1' and state /= ST_TEST and
                         pk_st = PK_CMD and pk_idx = C_PK_CLK_DIV
                else '0';

  -- ==========================================================================
  -- Paket tanımı (combinational): state / idx -> opcode, byte sayısı, veri, beklenen
  --   ST_CFG_WR idx: 0 CTRL=00, 1 PSEN=bank_mode, 2 GOCENHYS, 3 SOCENHYS, 4 TMDATA=00
  --   ST_CFG_RD idx: 0 82, 1 84, 2 BA, 3 BC, 4 9E (beklenen = yazılan)
  --   ST_TEST   idx: 0 TM=ALL1, 1 CTRL=TEST, 3 F8 (=0), 4 TM=ALL0, 6 F8 (=FFFFFFFF),
  --                  7 CTRL=00, 8 TM=00 (2, 5 settle, 9 bitiş)
  --   ST_READ      : F8
  -- Kullanılmayan register bitlerine 0 yazılır (s.6-8; DS-3).
  -- ==========================================================================
  p_dsc : process (state, idx, bm_r, goc_r, goh_r, soc_r, soh_r)
  begin
    dsc_rd <= '0';
    dsc_n  <= 1;
    dsc_op <= C_OP_R_ALL;
    dsc_d1 <= x"00";
    dsc_d0 <= x"00";
    rb_exp <= x"0000";
    st_exp <= C_ST_EXP_ALL1;
    case state is
      when ST_CFG_WR | ST_CFG_RD =>
        case idx is
          when 0 =>
            dsc_op <= C_OP_W_CTRL;  rb_exp <= x"00" & C_CTRL_NORM;
          when 1 =>
            dsc_op <= C_OP_W_PSEN;  dsc_d0 <= "0000" & bm_r;
            rb_exp <= x"00" & "0000" & bm_r;
          when 2 =>
            dsc_op <= C_OP_W_GO;    dsc_n <= 2;
            dsc_d1 <= "00" & goh_r; dsc_d0 <= "00" & goc_r;
            rb_exp <= "00" & goh_r & "00" & goc_r;
          when 3 =>
            dsc_op <= C_OP_W_SO;    dsc_n <= 2;
            dsc_d1 <= "00" & soh_r; dsc_d0 <= "00" & soc_r;
            rb_exp <= "00" & soh_r & "00" & soc_r;
          when others =>
            dsc_op <= C_OP_W_TM;    rb_exp <= x"00" & C_TM_NONE;
        end case;
        if state = ST_CFG_RD then
          dsc_rd <= '1';
          dsc_op(7) <= '1';         -- okuma opcode'u = yazma opcode'u + 0x80 (s.4 Fig 4)
        end if;
      when ST_TEST =>
        case idx is
          when 0      => dsc_op <= C_OP_W_TM;   dsc_d0 <= C_TM_ALL1;
          when 1      => dsc_op <= C_OP_W_CTRL; dsc_d0 <= C_CTRL_TEST;
          when 3      => dsc_op <= C_OP_R_ALL;  dsc_rd <= '1'; dsc_n <= 4; st_exp <= C_ST_EXP_ALL1;
          when 4      => dsc_op <= C_OP_W_TM;   dsc_d0 <= C_TM_ALL0;
          when 6      => dsc_op <= C_OP_R_ALL;  dsc_rd <= '1'; dsc_n <= 4; st_exp <= C_ST_EXP_ALL0;
          when 7      => dsc_op <= C_OP_W_CTRL; dsc_d0 <= C_CTRL_NORM;
          when others => dsc_op <= C_OP_W_TM;   dsc_d0 <= C_TM_NONE;
        end case;
      when others =>                -- ST_READ (ve paket istemeyen durumlar)
        dsc_op <= C_OP_R_ALL;
        dsc_rd <= '1';
        dsc_n  <= 4;
    end case;
  end process p_dsc;

  -- ==========================================================================
  -- Control FSM
  -- Paket isteği kalıbı (ST_CFG_WR / ST_CFG_RD / ST_TEST paket adımları / ST_READ):
  --   frm_pend = '0' : (stop yoksa) frm_go ile paket istenir
  --   frm_pend = '1' : frm_cancel -> ST_IDLE; pk_ok (SYNC geldi) -> sonraki adım
  -- Yapısal hata her durumda (ST_CORE_RST hariç) önceliklidir.
  -- ==========================================================================
  p_ctrl : process (clk, rst_n)
  begin
    if rst_n = '0' then
      state      <= ST_IDLE;
      idx        <= 0;
      tmr        <= 0;
      bm_r       <= (others => '0');
      goc_r      <= (others => '0');
      goh_r      <= (others => '0');
      soc_r      <= (others => '0');
      soh_r      <= (others => '0');
      period_cur <= (others => '0');
      err_r      <= '0';
      err_code_r <= C_E_NONE;
      err_cnt    <= 0;
      cfg_done_r <= '0';
      st_done_r  <= '0';
      st_fail_r  <= '0';
      st_bad     <= '0';
      st_pend    <= '0';
      rd_owed    <= '0';
      vfy        <= '0';
      rb_bad     <= '0';
      rd_cnt     <= 0;
      stop_pend  <= '0';
      mr_n_r     <= '1';
      core_rst_r <= '0';
      rst_cnt    <= 0;
      frm_go     <= '0';
      frm_pend   <= '0';
    elsif rising_edge(clk) then
      frm_go    <= '0';
      st_done_r <= '0';

      -- stop çalışırken beklemede tutulur; self_test_req çalışırken pending olur
      if state /= ST_IDLE then
        if stop = '1' then
          stop_pend <= '1';
        end if;
        if self_test_req = '1' then
          st_pend <= '1';
        end if;
      end if;

      if struct_err = '1' and state /= ST_CORE_RST then
        -- yapısal hata: hemen dur; timeout'ta core reset'lenir
        err_r <= '1';
        if err_code_r = C_E_NONE then
          err_code_r <= struct_code;
        end if;
        cfg_done_r <= '0';
        frm_pend   <= '0';
        mr_n_r     <= '1';
        stop_pend  <= '0';
        st_pend    <= '0';
        if to_hit = '1' then
          core_rst_r <= '1';
          rst_cnt    <= 0;
          state      <= ST_CORE_RST;
        else
          state <= ST_IDLE;
        end if;
      else
        case state is

          -- bekleme: start / self_test_req ile ayarlar latch'lenir ve kontrol edilir
          when ST_IDLE =>
            stop_pend <= '0';
            st_pend   <= '0';
            frm_pend  <= '0';
            idx       <= 0;
            tmr       <= 0;
            vfy       <= '0';
            if start = '1' or self_test_req = '1' then
              err_r      <= '0';
              err_code_r <= C_E_NONE;
              err_cnt    <= 0;
              cfg_done_r <= '0';
              st_fail_r  <= '0';
              bm_r       <= bank_mode;
              goc_r      <= go_center;
              goh_r      <= go_hyst;
              soc_r      <= so_center;
              soh_r      <= so_hyst;
              st_pend    <= self_test_req;
              rd_owed    <= start;
              rd_cnt     <= 0;
              if start_ok = '0' then
                -- geçersiz eşik kodu: start reddedilir, SPI'a hiçbir şey gönderilmez
                err_r      <= '1';
                err_code_r <= C_E_RANGE;
                st_pend    <= '0';
                rd_owed    <= '0';
              elsif HAS_MR then
                mr_n_r <= '0';
                state  <= ST_MR_PULSE;
              else
                state <= ST_CFG_WR;
              end if;
            end if;

          -- nMR low MR_CLKS clk (s.11, s.19 tMR >= 100 ns)
          when ST_MR_PULSE =>
            if tmr = MR_CLKS - 1 then
              tmr    <= 0;
              mr_n_r <= '1';
              state  <= ST_MR_WAIT;
            else
              tmr <= tmr + 1;
            end if;

          -- nMR sonrası bekleme (hazır olma süresi datasheet'te yok, DS-2)
          when ST_MR_WAIT =>
            if stop_now = '1' then
              state <= ST_IDLE;
            elsif tmr = MR_WAIT_CLKS - 1 then
              tmr   <= 0;
              idx   <= 0;
              state <= ST_CFG_WR;
            else
              tmr <= tmr + 1;
            end if;

          -- init yazmaları (idx 0..4)
          when ST_CFG_WR =>
            if frm_pend = '0' then
              if stop_now = '1' then
                state <= ST_IDLE;
              else
                frm_go   <= '1';
                frm_pend <= '1';
              end if;
            elsif frm_cancel = '1' then
              frm_pend <= '0';
              state    <= ST_IDLE;
            elsif pk_ok = '1' then
              frm_pend <= '0';
              if idx = 4 then
                idx    <= 0;
                rb_bad <= '0';
                vfy    <= '0';
                state  <= ST_CFG_RD;
              else
                idx <= idx + 1;
              end if;
            end if;

          -- geri okuma (idx 0..4): init doğrulaması (vfy = 0) veya periyodik (vfy = 1)
          when ST_CFG_RD =>
            if frm_pend = '0' then
              if stop_now = '1' then
                state <= ST_IDLE;
              else
                frm_go   <= '1';
                frm_pend <= '1';
              end if;
            elsif frm_cancel = '1' then
              frm_pend <= '0';
              state    <= ST_IDLE;
            elsif pk_ok = '1' then
              frm_pend <= '0';
              if idx /= 4 then
                idx <= idx + 1;
                if rx_sh(15 downto 0) /= rb_exp then
                  rb_bad <= '1';
                end if;
              elsif rb_bad = '1' or rx_sh(15 downto 0) /= rb_exp then
                -- veri hatası: err sticky, entegre baştan programlanır (ERR_LIMIT'e kadar)
                idx        <= 0;
                err_r      <= '1';
                cfg_done_r <= '0';
                if err_code_r = C_E_NONE then
                  if vfy = '1' then
                    err_code_r <= C_E_VERIFY;
                  else
                    err_code_r <= C_E_RB;
                  end if;
                end if;
                vfy <= '0';
                if err_cnt = ERR_LIMIT - 1 then
                  err_cnt <= 0;
                  state   <= ST_IDLE;
                elsif stop_now = '1' then
                  err_cnt <= err_cnt + 1;
                  state   <= ST_IDLE;
                else
                  err_cnt <= err_cnt + 1;
                  if HAS_MR then
                    tmr    <= 0;
                    mr_n_r <= '0';
                    state  <= ST_MR_PULSE;
                  else
                    state <= ST_CFG_WR;
                  end if;
                end if;
              else
                idx     <= 0;
                err_cnt <= 0;
                if vfy = '1' then
                  vfy   <= '0';
                  state <= ST_PERIOD;
                else
                  cfg_done_r <= '1';
                  state      <= ST_SETTLE;
                end if;
              end if;
            end if;

          -- son yazmadan itibaren SETTLE_CLKS; sonra self-test (istenmişse) ya da okuma
          when ST_SETTLE =>
            if stop_now = '1' then
              state <= ST_IDLE;
            elsif stl_ok = '1' then
              idx <= 0;
              if st_pend = '1' then
                st_bad <= '0';
                state  <= ST_TEST;
              else
                state <= ST_READ;
              end if;
            end if;

          -- self-test (atomik: stop beklemede kalır). 2 ve 5: settle bekleme.
          when ST_TEST =>
            if idx = 2 or idx = 5 then
              if stl_ok = '1' then
                idx <= idx + 1;
              end if;
            elsif idx = C_TEST_LAST then
              st_done_r <= '1';
              st_pend   <= '0';
              idx       <= 0;
              if st_bad = '1' then
                st_fail_r  <= '1';
                err_r      <= '1';
                cfg_done_r <= '0';
                if err_code_r = C_E_NONE then
                  err_code_r <= C_E_SELFTEST;
                end if;
                state <= ST_IDLE;
              elsif stop_now = '1' then
                state <= ST_IDLE;
              elsif rd_owed = '1' or continuous = '1' then
                state <= ST_SETTLE;
              else
                state <= ST_IDLE;
              end if;
            elsif frm_pend = '0' then
              frm_go   <= '1';
              frm_pend <= '1';
            elsif pk_ok = '1' then
              frm_pend <= '0';
              idx      <= idx + 1;
              if (idx = 3 or idx = 6) and rx_sh /= st_exp then
                st_bad <= '1';
              end if;
            end if;

          -- F8 okuması; sonuç p_out'ta. Sonra: self-test / IDLE / doğrulama / period
          when ST_READ =>
            if frm_pend = '0' then
              if stop_now = '1' then
                state <= ST_IDLE;
              else
                frm_go     <= '1';
                frm_pend   <= '1';
                period_cur <= unsigned(period_us);
              end if;
            elsif frm_cancel = '1' then
              frm_pend <= '0';
              state    <= ST_IDLE;
            elsif pk_ok = '1' then
              frm_pend <= '0';
              rd_owed  <= '0';
              if continuous = '0' or stop_now = '1' then
                if st_pend = '1' and stop_now = '0' then
                  idx    <= 0;
                  st_bad <= '0';
                  state  <= ST_TEST;
                else
                  state <= ST_IDLE;
                end if;
              elsif VERIFY_EVERY > 0 and rd_cnt = C_VFY_MAX - 1 then
                rd_cnt <= 0;
                idx    <= 0;
                rb_bad <= '0';
                vfy    <= '1';
                state  <= ST_CFG_RD;
              else
                if VERIFY_EVERY > 0 then
                  rd_cnt <= rd_cnt + 1;
                end if;
                state <= ST_PERIOD;
              end if;
            end if;

          -- sürekli mod: period dolunca okuma (ya da bekleyen self-test)
          when ST_PERIOD =>
            if stop_now = '1' then
              state <= ST_IDLE;
            elsif per_ok = '1' then
              idx <= 0;
              if st_pend = '1' then
                st_bad <= '0';
                state  <= ST_TEST;
              else
                state <= ST_READ;
              end if;
            end if;

          -- core_rst_r CORE_RST_CLKS clk '1' tutulur, sonra ST_IDLE
          when ST_CORE_RST =>
            if rst_cnt = CORE_RST_CLKS - 1 then
              core_rst_r <= '0';
              state      <= ST_IDLE;
            else
              rst_cnt <= rst_cnt + 1;
            end if;

        end case;
      end if;
    end if;
  end process p_ctrl;

  busy     <= '0' when state = ST_IDLE else '1';
  err      <= err_r;
  err_code <= err_code_r;
  cfg_done <= cfg_done_r;
  st_done  <= st_done_r;
  st_fail  <= st_fail_r;
  core_rst <= core_rst_r;

  g_mr : if HAS_MR generate
    mr_n <= mr_n_r;
  end generate;
  g_nomr : if not HAS_MR generate
    mr_n <= '1';
  end generate;

  -- ==========================================================================
  -- Timer'lar
  -- ==========================================================================
  -- settle timer: her yazma paketinin SYNC'inde sıfırlanır (SYNC, CS yükseldikten sonra
  -- gelir; register'ın yüklendiği andan geç olduğu için güvenli taraftadır), doyumlu sayar.
  -- rst_n async; yazma SYNC'i ile sıfırlama senkron.
  p_stl : process (clk, rst_n)
  begin
    if rst_n = '0' then
      stl_cnt <= 0;
    elsif rising_edge(clk) then
      if pk_ok = '1' and pk_rd = '0' then
        stl_cnt <= 0;
      elsif stl_cnt < SETTLE_CLKS - 1 then
        stl_cnt <= stl_cnt + 1;
      end if;
    end if;
  end process p_stl;
  stl_ok <= '1' when stl_cnt = SETTLE_CLKS - 1 else '0';

  -- period timer: F8 okuma paketinin launch'ında sıfırlanır, us sayar
  -- rst_n async; per_rst (okuma launch'ı) senkron.
  per_rst <= '1' when frm_launch = '1' and state = ST_READ else '0';
  p_per : process (clk, rst_n)
  begin
    if rst_n = '0' then
      per_pre <= 0;
      per_us  <= (others => '0');
    elsif rising_edge(clk) then
      if per_rst = '1' then
        per_pre <= C_PER_LAT;
        per_us  <= (others => '0');
      elsif per_pre = CLKS_PER_US - 1 then
        per_pre <= 0;
        if per_us /= x"FFFF" then
          per_us <= per_us + 1;
        end if;
      else
        per_pre <= per_pre + 1;
      end if;
    end if;
  end process p_per;
  per_ok <= '1' when per_us >= period_cur else '0';

  -- SYNC timeout: launch'tan itibaren (gnt bekleme dahil değil)
  to_hit <= '1' when pk_launched = '1' and to_cnt = SYNC_TO_CLKS - 1 and sync_valid = '0'
            else '0';

  -- ==========================================================================
  -- Command packer
  --   PK_IDLE : frm_go bekler; paket tanımı (dsc_*) alınır
  --   PK_CMD  : komutlar sırayla (pk_idx 0..7, yazmada 5 atlanır). İlk komut gnt bekler;
  --             kabulü (frm_launch) launch'tır: sdo byte kuyruğu kurulur, beklenen sdi
  --             kelime sayısı yazılır, SYNC timeout sayacı başlar.
  --   PK_WAIT : SYNC beklenir; gelince sync_id artar, PK_IDLE.
  --   Yapısal hatada paket bırakılır (PK_IDLE).
  -- ==========================================================================
  pk_launched <= '1' when (pk_st = PK_CMD and pk_idx /= C_PK_CLK_DIV) or pk_st = PK_WAIT
                 else '0';

  -- komut mux'u
  p_cmd : process (pk_idx, pk_rd, pk_n, sync_id)
  begin
    case pk_idx is
      when 0 => cmd_i <= C_CMD_CLK_DIV;
      when 1 => cmd_i <= C_CMD_MODE;
      when 2 => cmd_i <= C_CMD_WORDLEN;
      when 3 => cmd_i <= C_CMD_CS_ON;
      when 4 =>                     -- opcode (+ yazmada veri byte'ları): kelime sayısı - 1
        if pk_rd = '1' then
          cmd_i <= mk_cmd(C_OP_TRANSFER, C_XFER_W, x"00");
        else
          cmd_i <= mk_cmd(C_OP_TRANSFER, C_XFER_W, std_logic_vector(to_unsigned(pk_n, 8)));
        end if;
      when 5 =>                     -- okuma verisi: n kelime
        cmd_i <= mk_cmd(C_OP_TRANSFER, C_XFER_R, std_logic_vector(to_unsigned(pk_n - 1, 8)));
      when 6 => cmd_i <= C_CMD_CS_OFF;
      when others => cmd_i <= mk_cmd(C_OP_MISC, C_MISC_SYNC, std_logic_vector(sync_id));
    end case;
  end process p_cmd;

  cmd_valid_i <= '1' when pk_st = PK_CMD and gnt = '1' and frm_cancel = '0' else '0';
  cmd_hs      <= cmd_valid_i and cmd_ready;
  frm_launch  <= '1' when cmd_hs = '1' and pk_idx = C_PK_CLK_DIV else '0';

  -- SYNC ve sdi kontrolleri
  frm_done  <= '1' when pk_st = PK_WAIT and sync_valid = '1' and sync = std_logic_vector(sync_id)
               else '0';
  sync_err  <= '1' when sync_valid = '1' and
                        (pk_st /= PK_WAIT or sync /= std_logic_vector(sync_id))
               else '0';
  sdi_unexp <= '1' when sdi_valid = '1' and exp_cnt = 0 else '0';
  sdi_miss  <= '1' when frm_done = '1' and exp_cnt /= 0 else '0';
  pk_ok     <= frm_done and not sdi_miss;

  p_pack : process (clk, rst_n)
  begin
    if rst_n = '0' then
      pk_st       <= PK_IDLE;
      pk_idx      <= C_PK_CLK_DIV;
      pk_rd       <= '0';
      pk_n        <= 1;
      pk_op       <= (others => '0');
      pk_d1       <= (others => '0');
      pk_d0       <= (others => '0');
      sync_id     <= (others => '0');
      sq0         <= (others => '0');
      sq1         <= (others => '0');
      sq2         <= (others => '0');
      sq_cnt      <= 0;
      sdo_valid_r <= '0';
      to_cnt      <= 0;
      exp_cnt     <= 0;
      rx_sh       <= (others => '0');
    elsif rising_edge(clk) then
      -- sdo byte kuyruğu: core bir kelime aldıkça kayar
      if sdo_valid_r = '1' and sdo_ready = '1' then
        sq0 <= sq1;
        sq1 <= sq2;
        if sq_cnt = 1 then
          sdo_valid_r <= '0';
        end if;
        if sq_cnt /= 0 then
          sq_cnt <= sq_cnt - 1;
        end if;
      end if;

      -- MISO byte'ları: beklenen sayıda kelime toplanır (yalnız [7:0])
      if sdi_valid = '1' and exp_cnt /= 0 then
        rx_sh   <= rx_sh(23 downto 0) & sdi_data(7 downto 0);
        exp_cnt <= exp_cnt - 1;
      end if;

      -- SYNC timeout sayacı (launch'ta 0'lanır, doyumlu)
      if pk_launched = '1' and to_cnt < SYNC_TO_CLKS - 1 then
        to_cnt <= to_cnt + 1;
      end if;

      if struct_err = '1' then
        pk_st       <= PK_IDLE;
        pk_idx      <= C_PK_CLK_DIV;
        sdo_valid_r <= '0';
        sq_cnt      <= 0;
        exp_cnt     <= 0;
        if sync_valid = '1' then
          sync_id <= sync_id + 1;
        end if;
      else
        case pk_st is
          when PK_IDLE =>
            pk_idx <= C_PK_CLK_DIV;
            if frm_go = '1' then
              pk_rd <= dsc_rd;
              pk_n  <= dsc_n;
              pk_op <= dsc_op;
              pk_d1 <= dsc_d1;
              pk_d0 <= dsc_d0;
              pk_st <= PK_CMD;
            end if;

          when PK_CMD =>
            if frm_cancel = '1' then
              pk_st <= PK_IDLE;
            elsif cmd_hs = '1' then
              if pk_idx = C_PK_CLK_DIV then
                -- launch: sdo kuyruğu, beklenen sdi sayısı, timeout
                to_cnt      <= 0;
                rx_sh       <= (others => '0');
                sdo_valid_r <= '1';
                sq0         <= pk_op;
                if pk_rd = '1' then
                  sq_cnt  <= 1;
                  exp_cnt <= pk_n;
                elsif pk_n = 2 then
                  sq1    <= pk_d1;      -- 2 byte'lık yazma: önce DB1 (s.7 Tbl 6, s.5 Fig 6)
                  sq2    <= pk_d0;
                  sq_cnt <= 3;
                else
                  sq1    <= pk_d0;
                  sq_cnt <= 2;
                end if;
              end if;
              if pk_idx = C_PK_SYNC then
                pk_st <= PK_WAIT;
              elsif pk_idx = C_PK_XFER_W and pk_rd = '0' then
                pk_idx <= C_PK_CS_OFF;  -- yazma paketinde TRANSFER R yok
              else
                pk_idx <= pk_idx + 1;
              end if;
            end if;

          when PK_WAIT =>
            if sync_valid = '1' then
              sync_id <= sync_id + 1;
              pk_st   <= PK_IDLE;
              pk_idx  <= C_PK_CLK_DIV;
            end if;
        end case;
      end if;
    end if;
  end process p_pack;

  -- req: paket bekliyor veya sürüyor (SYNC'e kadar; arbiter paketi bölmez)
  req       <= '0' when pk_st = PK_IDLE else '1';
  cmd       <= cmd_i;
  cmd_valid <= cmd_valid_i;
  sdo_data  <= std_logic_vector(resize(unsigned(sq0), DATA_WIDTH));
  sdo_valid <= sdo_valid_r;

  -- ==========================================================================
  -- Çıkış register'ı: F8 okuması hatasız bitince sense, sense_chg, sense_act ve
  -- 1 clk sense_valid. sense = DB3..DB0 = SO<31:0> (s.10 Tbl 12). sense_chg önceki
  -- sense register'ına göre (reset sonrası 0'a göre). sense_act, start'ta latch'lenen
  -- bank moduyla normalize edilir (s.9: GND/Open'da 1 = toprak, Supply/Open'da 0 = besleme).
  -- ==========================================================================
  rd_done <= '1' when pk_ok = '1' and state = ST_READ else '0';

  p_out : process (clk, rst_n)
  begin
    if rst_n = '0' then
      sense_r     <= (others => '0');
      sense_chg_r <= (others => '0');
      sense_act_r <= (others => '0');
      sense_vld_r <= '0';
    elsif rising_edge(clk) then
      sense_vld_r <= rd_done;
      if rd_done = '1' then
        sense_r     <= rx_sh;
        sense_chg_r <= rx_sh xor sense_r;
        sense_act_r <= rx_sh xor expand_bm(bm_r);
      end if;
    end if;
  end process p_out;

  sense       <= sense_r;
  sense_valid <= sense_vld_r;
  sense_chg   <= sense_chg_r;
  sense_act   <= sense_act_r;

end architecture rtl;
