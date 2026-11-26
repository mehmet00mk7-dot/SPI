-- ============================================================================
-- hi8436_top.vhd  -  HI-8436 okuma bloğu: hi8436_drv + spi_exec (ortak core)
--
-- 1 driver -> 1 spi_exec -> 1 HI-8436. Arbiter yok, gnt = '1'. Kartta iki HI-8436 varsa
-- sistem seviyesinde iki instance kullanılır (ANALIZ.md E.7). Paylaşılan bir SPI hattında
-- driver'ın req/gnt arayüzü arbiter'a bağlanır (bu top'ta req kullanılmaz).
--
--                     +--------------+  cmd/valid/ready   +--------------+
--   start, stop  ---->|              |------------------->|              |---> spi_sclk
--   continuous   ---->|    u_drv     |  sdo_data/valid    |    u_spi     |---> spi_mosi
--   period_us    ---->|  hi8436_drv  |------------------->|   spi_exec   |---> spi_cs_n
--   bank_mode    ---->|              |  sdi_data/valid    | (common/rtl/ |<--- spi_miso
--   go_*/so_*    ---->|              |<-------------------|   async)     |
--   self_test_req --->|              |  sync/valid        |              |
--                     |              |<-------------------|              |
--   sense*, cfg_done, |              |                    +--------------+
--   busy, err   <-----|              |---> spi_mr_n               ^ resetn
--                     +--------------+ core_rst  +---------------+
--                                      --------->| p_core_resetn |<--- rst_n
--                                                +---------------+
--   rst_n ayrıca u_drv'nin async reset'idir.
--
-- Ayar kaynağı: CFG_FROM_GENERIC = false ise bank_mode / eşik kodları portlardan, true ise
-- DEF_* generic'lerinden gelir (portlar yok sayılır; kart testi için).
-- Varsayılanlar (onaylı, ANALIZ.md K-2..K-4): bank_mode 0000 (hepsi GND/Open), GND/Open
-- 1,4 V / 0,4 V (center 9, hysteresis 5 -> 3A 05 09; VWET açıkken de geçerli, s.16 Tbl 16),
-- Supply/Open 5,0 V / 2,0 V (center 35, hysteresis 15 -> 3C 0F 23, s.8 Tbl 7).
--
-- Core kullanımı:
--   * DATA_WIDTH generic (8..32), word_length her pakette 8 (driver CONFIG'le yazar).
--   * NUM_OF_CS = 1, NUM_OF_SDI = 1, SDO_DEFAULT = '0' (SI'da dahili pull-down, s.3 Tbl 1),
--     DEFAULT_SPI_CFG = 0 (Mode 0, s.4), SDI_DELAY generic (varsayılan 0, ANALIZ.md B.2).
--   * sdi_data_ready = sync_ready = '1' (driver her zaman kabul eder), echo_sclk = '0'.
--   * sdo_t / three_wire açık: MOSI her zaman sürülür.
--   * Core config'i her pakette CONFIG komutlarıyla yeniden yazılır; generic'ler yalnız
--     reset değeridir.
--
-- RESET STRATEJİSİ
--   * rst_n kaynağı: projedeki reset synchronizer. Async assert, sync deassert, PLL lock'a
--     bağlı. Bu modülde async reset olarak YALNIZCA rst_n kullanılır.
--   * Driver rst_n'yi doğrudan async reset olarak alır. Core'un resetn'i p_core_resetn
--     flop'undan gelir: rst_n ile async clear (rst_n düşünce clock beklemeden core reset'te,
--     spi_cs_n = '1'), D = not core_rst (core_rst senkron, bir clock gecikmeli).
--   * spi_mr_n reset anında '1' (driver'ın mr_n register'ı async reset değeri).
--
-- Datasheet: Holt HI-8436 DS8436 Rev. L. Pinler s.3 Tbl 1, SPI s.4-5, AC timing s.19.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity hi8436_top is
  generic (
    CLKS_PER_US      : integer := 100;    -- 100 MHz
    CLK_DIV          : integer := 2;      -- SCLK = 100 MHz / (2*(CLK_DIV+1)) = 16,67 MHz
    CS_T             : integer := 1;      -- CS komutundaki bekleme (SCLK periyodu)
    DATA_WIDTH       : integer := 8;      -- core kelime genişliği (8..32)
    SDI_DELAY        : integer := 0;      -- core MISO örnekleme ek gecikmesi (0..3 clk)
    HAS_MR           : boolean := true;   -- nMR FPGA'ya bağlı (K-1)
    MR_CLKS          : integer := 20;     -- nMR pulse (200 ns)
    MR_WAIT_CLKS     : integer := 100;    -- nMR sonrası bekleme (1 us)
    SETTLE_CLKS      : integer := 200;    -- yazma -> F8 okuma arası (2 us)
    SYNC_TO_CLKS     : integer := 1000;   -- SYNC timeout (10 us)
    CORE_RST_CLKS    : integer := 4;      -- core_rst pulse
    ERR_LIMIT        : integer := 4;      -- art arda veri hatası limiti
    VERIFY_EVERY     : integer := 0;      -- periyodik config doğrulaması (0 = kapalı, K-9)
    INIT_EVERY_START : boolean := false;  -- true: her start'ta nMR + tam init (eski davranış)
    CFG_FROM_GENERIC : boolean := false;  -- true: ayarlar DEF_* generic'lerinden
    DEF_BANK_MODE    : integer := 0;      -- 0..15, PSEN<3:0>
    DEF_GO_CENTER    : integer := 9;      -- GND/Open 1,4 / 0,4 V
    DEF_GO_HYST      : integer := 5;
    DEF_SO_CENTER    : integer := 35;     -- Supply/Open 5,0 / 2,0 V
    DEF_SO_HYST      : integer := 15
  );
  port (
    clk           : in  std_logic;                      -- 100 MHz sistem clock'u
    rst_n         : in  std_logic;                      -- async aktif-düşük reset (synchronizer)
    -- kontrol
    start         : in  std_logic;
    stop          : in  std_logic;
    continuous    : in  std_logic;
    period_us     : in  std_logic_vector(15 downto 0);
    bank_mode     : in  std_logic_vector(3 downto 0);
    go_center     : in  std_logic_vector(5 downto 0);
    go_hyst       : in  std_logic_vector(5 downto 0);
    so_center     : in  std_logic_vector(5 downto 0);
    so_hyst       : in  std_logic_vector(5 downto 0);
    self_test_req : in  std_logic;
    -- sonuç
    sense         : out std_logic_vector(31 downto 0);
    sense_valid   : out std_logic;
    sense_chg     : out std_logic_vector(31 downto 0);
    sense_act     : out std_logic_vector(31 downto 0);
    cfg_done      : out std_logic;
    busy          : out std_logic;
    err           : out std_logic;
    err_code      : out std_logic_vector(3 downto 0);
    st_done       : out std_logic;
    st_fail       : out std_logic;
    -- HI-8436 pinleri
    spi_sclk      : out std_logic;                      -- SCK
    spi_mosi      : out std_logic;                      -- SI
    spi_cs_n      : out std_logic;                      -- nCS
    spi_miso      : in  std_logic;                      -- SO
    spi_mr_n      : out std_logic                       -- nMR
  );
end entity hi8436_top;

architecture rtl of hi8436_top is

  signal core_resetn : std_logic;                     -- core async reset'i (p_core_resetn flop'u)
  signal core_rst    : std_logic;                     -- driver: core reset isteği (senkron)
  signal req         : std_logic;                     -- driver isteği (arbiter yok, kullanılmaz)
  signal gnt         : std_logic;                     -- arbiter izni (sabit '1')
  signal cmd         : std_logic_vector(15 downto 0);
  signal cmd_valid   : std_logic;
  signal cmd_ready   : std_logic;
  signal sdo_data    : std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal sdo_valid   : std_logic;
  signal sdo_ready   : std_logic;
  signal sdi_data    : std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal sdi_valid   : std_logic;
  signal sync        : std_logic_vector(7 downto 0);
  signal sync_valid  : std_logic;
  signal miso_v      : std_logic_vector(0 downto 0);
  signal cs_v        : std_logic_vector(0 downto 0);
  -- driver'a giden ayarlar (port ya da generic)
  signal bm_i        : std_logic_vector(3 downto 0);
  signal goc_i       : std_logic_vector(5 downto 0);
  signal goh_i       : std_logic_vector(5 downto 0);
  signal soc_i       : std_logic_vector(5 downto 0);
  signal soh_i       : std_logic_vector(5 downto 0);

begin

  gnt <= '1';                               -- tek driver, arbiter yok

  -- Core reset'i: tek flop. rst_n ile async clear, D = not core_rst (senkron, 1 clk gecikmeli).
  -- Kombinasyonel "rst_n and not core_rst" async reset hattında glitch üretebilir.
  p_core_resetn : process (clk, rst_n)
  begin
    if rst_n = '0' then
      core_resetn <= '0';
    elsif rising_edge(clk) then
      core_resetn <= not core_rst;
    end if;
  end process p_core_resetn;

  -- ayar kaynağı seçimi (elaboration-time)
  g_cfg_gen : if CFG_FROM_GENERIC generate
    bm_i  <= std_logic_vector(to_unsigned(DEF_BANK_MODE, 4));
    goc_i <= std_logic_vector(to_unsigned(DEF_GO_CENTER, 6));
    goh_i <= std_logic_vector(to_unsigned(DEF_GO_HYST, 6));
    soc_i <= std_logic_vector(to_unsigned(DEF_SO_CENTER, 6));
    soh_i <= std_logic_vector(to_unsigned(DEF_SO_HYST, 6));
  end generate;
  g_cfg_port : if not CFG_FROM_GENERIC generate
    bm_i  <= bank_mode;
    goc_i <= go_center;
    goh_i <= go_hyst;
    soc_i <= so_center;
    soh_i <= so_hyst;
  end generate;

  miso_v(0) <= spi_miso;
  spi_cs_n  <= cs_v(0);

  -- Driver: HI-8436 protokolü, init / doğrulama, okuma, self-test, hata yönetimi
  u_drv : entity work.hi8436_drv
    generic map (
      CLKS_PER_US   => CLKS_PER_US,
      CLK_DIV       => CLK_DIV,
      CS_T          => CS_T,
      CS_IDX        => 0,
      DATA_WIDTH    => DATA_WIDTH,
      HAS_MR        => HAS_MR,
      MR_CLKS       => MR_CLKS,
      MR_WAIT_CLKS  => MR_WAIT_CLKS,
      SETTLE_CLKS   => SETTLE_CLKS,
      SYNC_TO_CLKS  => SYNC_TO_CLKS,
      CORE_RST_CLKS => CORE_RST_CLKS,
      ERR_LIMIT     => ERR_LIMIT,
      VERIFY_EVERY  => VERIFY_EVERY,
      INIT_EVERY_START => INIT_EVERY_START
    )
    port map (
      clk           => clk,
      rst_n         => rst_n,
      start         => start,
      stop          => stop,
      continuous    => continuous,
      period_us     => period_us,
      bank_mode     => bm_i,
      go_center     => goc_i,
      go_hyst       => goh_i,
      so_center     => soc_i,
      so_hyst       => soh_i,
      self_test_req => self_test_req,
      sense         => sense,
      sense_valid   => sense_valid,
      sense_chg     => sense_chg,
      sense_act     => sense_act,
      cfg_done      => cfg_done,
      busy          => busy,
      err           => err,
      err_code      => err_code,
      st_done       => st_done,
      st_fail       => st_fail,
      mr_n          => spi_mr_n,
      req           => req,
      gnt           => gnt,
      cmd           => cmd,
      cmd_valid     => cmd_valid,
      cmd_ready     => cmd_ready,
      sdo_data      => sdo_data,
      sdo_valid     => sdo_valid,
      sdo_ready     => sdo_ready,
      sdi_data      => sdi_data,
      sdi_valid     => sdi_valid,
      sync          => sync,
      sync_valid    => sync_valid,
      core_rst      => core_rst
    );

  -- SPI master (spi_exec, common/rtl/async): komut stream'ini SPI dalga şekline çevirir.
  u_spi : entity work.spi_exec
    generic map (
      NUM_OF_CS       => 1,
      DEFAULT_SPI_CFG => 0,
      DEFAULT_CLK_DIV => CLK_DIV,
      DATA_WIDTH      => DATA_WIDTH,
      NUM_OF_SDI      => 1,
      SDO_DEFAULT     => "0",
      SDI_DELAY       => std_logic_vector(to_unsigned(SDI_DELAY, 2))
    )
    port map (
      clk            => clk,
      resetn         => core_resetn,
      cmd_ready      => cmd_ready,
      cmd_valid      => cmd_valid,
      cmd            => cmd,
      sdo_data_valid => sdo_valid,
      sdo_data_ready => sdo_ready,
      sdo_data       => sdo_data,
      sdi_data_ready => '1',
      sdi_data_valid => sdi_valid,
      sdi_data       => sdi_data,
      sync_ready     => '1',
      sync_valid     => sync_valid,
      sync           => sync,
      echo_sclk      => '0',
      sclk           => spi_sclk,
      sdo            => spi_mosi,
      sdo_t          => open,
      sdi            => miso_v,
      cs             => cs_v,
      three_wire     => open
    );

end architecture rtl;
