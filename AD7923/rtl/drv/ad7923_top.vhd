-- ============================================================================
-- ad7923_top.vhd  -  AD7923 okuma bloğu: ad7923_drv + ad7923_ch_regs + spi_exec
--
-- 1 driver -> 1 spi_exec -> 1 AD7923. Arbiter yok, gnt = '1'.
--
--                    +--------------+   cmd/valid/ready   +--------------+
--   start      ----->|              |-------------------->|              |---> spi_sclk
--   stop       ----->|    u_drv     |   sdo_data/valid    |    u_spi     |---> spi_mosi
--   continuous ----->|  ad7923_drv  |-------------------->|   spi_exec   |---> spi_cs_n
--   ch_mask    ----->|              |   sdi_data/valid    |              |<--- spi_miso
--   period_us  ----->|              |<--------------------|              |
--   range_sel  ----->|              |   sync/valid        |              |
--   coding_sel ----->|              |<--------------------|              |
--   busy, err  <-----|              |                     +--------------+
--                    +--------------+                            ^ resetn
--                      |         |  core_rst         +---------------+
--   data_valid,  <-----+         +------------------>| p_core_resetn |<--- rst_n
--   data_ch, data      |  data_valid/ch/data/last    +---------------+
--                      v
--                    +----------------+
--   chN_data   <-----|     u_regs     |
--   chN_valid  <-----| ad7923_ch_regs |
--   scan_done  <-----|                |
--                    +----------------+
--   rst_n ayrıca u_drv ve u_regs'in async reset'idir.
--
-- SPI core: ADI spi_engine_execution'ın VHDL çevirisi spi_exec (async reset).
-- Davranış orijinal Verilog ile lockstep simülasyonda birebir doğrulandı.
-- Orijinal Verilog entegrasyonuna göre değişen iki nokta: component adı
-- (spi_engine_execution -> spi_exec) ve core reset'i (kombinasyonel
-- "rst_n and not core_rst" yerine register'lı p_core_resetn).
--
-- ad7923_ch_regs, driver'ın data_valid / data_ch / data / data_last akışından kanal
-- başına register'lar (chN_data, chN_valid) ve scan_done üretir; data_valid /
-- data_ch / data çıkışları ayrıca doğrudan dışarı verilir.
--
-- Core kullanım kuralları:
--   * sdi_data_ready = sync_ready = '1' (driver her zaman kabul eder)
--   * echo_sclk = '0' (ECHO_SCLK kullanılmaz)
--   * sdo_t / three_wire açık: MOSI her zaman sürülür, 3-wire mod yok
--   * sdo doğrudan MOSI, sdi(0) = MISO, cs(0) = AD7923 CS
--   * Core config'i (Mode 2, 16 bit, CLK_DIV) her frame'de driver tarafından
--     CONFIG komutlarıyla yeniden yazılır; generic'ler yalnız reset değeridir.
--
-- RESET STRATEJİSİ
--   * rst_n kaynağı: projedeki reset synchronizer. Async assert, sync deassert,
--     PLL lock'a bağlı. Bu modülde async reset olarak YALNIZCA rst_n kullanılır.
--   * Driver (ad7923_drv), kanal register'ları (ad7923_ch_regs) ve core (spi_exec)
--     aynı rst_n'den beslenir. Driver ve ch_regs rst_n'yi doğrudan async reset
--     olarak alır. Core'un resetn'i p_core_resetn flop'undan gelir: rst_n ile async
--     assert (rst_n düşünce clock beklemeden core reset'te, spi_cs_n = '1'),
--     deassert senkron.
--   * core_rst (driver'ın SYNC timeout sonrası ürettiği core reset pulse'ı) senkron
--     bir register'dır ve async reset olarak kullanılmaz: p_core_resetn'in D
--     girişine gider, core'u bir clock gecikmeli ve senkron olarak reset'e sokar.
--   * p_core_resetn bu geçişte değiştirilmedi (doğrulanmış core entegrasyonu).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ad7923_top is
  generic (
    CLK_DIV : integer := 2;   -- SCLK = 100 MHz / (2*(CLK_DIV+1)) = 16,7 MHz
    CS_T    : integer := 1    -- CS komutundaki ek bekleme
  );
  port (
    clk        : in  std_logic;                     -- 100 MHz sistem clock'u
    rst_n      : in  std_logic;                     -- async aktif-düşük reset (synchronizer)
    start      : in  std_logic;                     -- tarama başlat
    stop       : in  std_logic;                     -- taramayı durdur
    continuous : in  std_logic;                     -- '1': sürekli tarama
    ch_mask    : in  std_logic_vector(3 downto 0);  -- taranacak kanallar
    period_us  : in  std_logic_vector(15 downto 0);  -- sürekli modda tarama periyodu (us)
    range_sel  : in  std_logic;                     -- AD7923 RANGE biti
    coding_sel : in  std_logic;                     -- AD7923 CODING biti
    data_valid : out std_logic;                     -- 1 clk: data geçerli
    data_ch    : out std_logic_vector(1 downto 0);  -- verinin kanalı
    data       : out std_logic_vector(11 downto 0);  -- 12 bit sonuç
    busy       : out std_logic;                     -- driver meşgul
    err        : out std_logic;                     -- sticky hata
    -- kanal başına sonuçlar (ad7923_ch_regs)
    ch0_data   : out std_logic_vector(11 downto 0);
    ch1_data   : out std_logic_vector(11 downto 0);
    ch2_data   : out std_logic_vector(11 downto 0);
    ch3_data   : out std_logic_vector(11 downto 0);
    ch0_valid  : out std_logic;
    ch1_valid  : out std_logic;
    ch2_valid  : out std_logic;
    ch3_valid  : out std_logic;
    scan_done  : out std_logic;                     -- tarama tamamlandı (1 clk)
    spi_sclk   : out std_logic;                     -- AD7923 SCLK (Mode 2: boşta '1')
    spi_mosi   : out std_logic;                     -- AD7923 DIN
    spi_cs_n   : out std_logic;                     -- AD7923 CS (aktif '0')
    spi_miso   : in  std_logic                      -- AD7923 DOUT
  );
end entity ad7923_top;

architecture rtl of ad7923_top is

  -- ADI çekirdek parametreleri (proje kuralı 5): tek CS, 16 bit, Mode 2, tek MISO
  constant C_NUM_OF_CS       : integer := 1;
  constant C_DATA_WIDTH      : integer := 16;
  constant C_DEFAULT_SPI_CFG : integer := 2;          -- Mode 2: CPOL=1, CPHA=0
  constant C_NUM_OF_SDI      : integer := 1;
  constant C_SDO_DEFAULT     : std_logic_vector(0 downto 0) := "1";
  -- ECHO_SCLK: Verilog default'u 0 (istenen değer). VHDL büyük/küçük harf ayırmadığı
  -- için generic ECHO_SCLK, port echo_sclk ile çakışır; bu yüzden component'te
  -- tanımlanmaz ve map edilmez (çekirdek default 0 ile elaborate edilir).
  constant C_SDI_DELAY       : std_logic_vector(1 downto 0) := "00";

  -- SPI core (rtl/async/spi_exec.vhd); generic / port listesi orijinal component ile aynı
  component spi_exec is
    generic (
      NUM_OF_CS       : integer := 1;
      DEFAULT_SPI_CFG : integer := 0;
      DEFAULT_CLK_DIV : integer := 0;
      DATA_WIDTH      : integer := 8;
      NUM_OF_SDI      : integer := 1;
      SDO_DEFAULT     : std_logic_vector(0 downto 0) := "0";
      SDI_DELAY       : std_logic_vector(1 downto 0) := "00"
    );
    port (
      clk            : in  std_logic;
      resetn         : in  std_logic;
      cmd_ready      : out std_logic;
      cmd_valid      : in  std_logic;
      cmd            : in  std_logic_vector(15 downto 0);
      sdo_data_valid : in  std_logic;
      sdo_data_ready : out std_logic;
      sdo_data       : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
      sdi_data_ready : in  std_logic;
      sdi_data_valid : out std_logic;
      sdi_data       : out std_logic_vector(NUM_OF_SDI * DATA_WIDTH - 1 downto 0);
      sync_ready     : in  std_logic;
      sync_valid     : out std_logic;
      sync           : out std_logic_vector(7 downto 0);
      echo_sclk      : in  std_logic;
      sclk           : out std_logic;
      sdo            : out std_logic;
      sdo_t          : out std_logic;
      sdi            : in  std_logic_vector(NUM_OF_SDI - 1 downto 0);
      cs             : out std_logic_vector(NUM_OF_CS - 1 downto 0);
      three_wire     : out std_logic
    );
  end component;

  signal core_resetn : std_logic;                     -- core async reset'i (p_core_resetn flop'u)
  signal core_rst    : std_logic;                     -- driver: core reset isteği (senkron)
  signal req         : std_logic;                     -- driver isteği (arbiter yok, kullanılmaz)
  signal gnt         : std_logic;                     -- arbiter izni (sabit '1')
  signal cmd         : std_logic_vector(15 downto 0);  -- komut stream'i: driver -> core
  signal cmd_valid   : std_logic;
  signal cmd_ready   : std_logic;
  signal sdo_data    : std_logic_vector(15 downto 0);  -- MOSI kelime stream'i: driver -> core
  signal sdo_valid   : std_logic;
  signal sdo_ready   : std_logic;
  signal sdi_data    : std_logic_vector(15 downto 0);  -- MISO kelime stream'i: core -> driver
  signal sdi_valid   : std_logic;
  signal sync        : std_logic_vector(7 downto 0);  -- SYNC id: core -> driver
  signal sync_valid  : std_logic;
  signal miso_v      : std_logic_vector(C_NUM_OF_SDI - 1 downto 0);  -- core sdi vektörü
  signal cs_v        : std_logic_vector(C_NUM_OF_CS - 1 downto 0);  -- core cs vektörü
  signal data_valid_i : std_logic;                    -- driver sonuç akışı (iç)
  signal data_ch_i    : std_logic_vector(1 downto 0);
  signal data_i       : std_logic_vector(11 downto 0);
  signal data_last_i  : std_logic;

begin

  gnt         <= '1';                       -- tek driver, arbiter yok
  -- Core reset'i: spi_exec async reset kullandığı için reset hattı bir flop'tan gelmeli
  -- (kombinasyonel AND'deki glitch, async reset'te istenmeyen bir reset pulse'ı olabilir).
  -- rst_n düşünce anında (async) reset'e girer; core_rst ise bir clock gecikmeli, senkron.
  --   rst_n = '0'              -> core_resetn = '0' (hemen)
  --   rst_n = '1', core_rst=1  -> sonraki kenarda core_resetn = '0'
  --   rst_n = '1', core_rst=0  -> sonraki kenarda core_resetn = '1'
  p_core_resetn : process(clk, rst_n)
  begin
    if rst_n = '0' then
      core_resetn <= '0';
    elsif rising_edge(clk) then
      core_resetn <= not core_rst;
    end if;
  end process;
  -- pin bağlantıları ve driver sonuç çıkışları
  miso_v(0)   <= spi_miso;
  spi_cs_n    <= cs_v(0);
  data_valid  <= data_valid_i;
  data_ch     <= data_ch_i;
  data        <= data_i;

  -- Driver: AD7923 protokolü, tarama kontrolü, sonuç kontrolü
  u_drv : entity work.ad7923_drv
    generic map (
      CLK_DIV  => CLK_DIV,
      SPI_MODE => C_DEFAULT_SPI_CFG,
      WORD_LEN => C_DATA_WIDTH,
      CS_T     => CS_T
    )
    port map (
      clk        => clk,
      rst_n      => rst_n,
      start      => start,
      stop       => stop,
      continuous => continuous,
      ch_mask    => ch_mask,
      period_us  => period_us,
      range_sel  => range_sel,
      coding_sel => coding_sel,
      data_valid => data_valid_i,
      data_ch    => data_ch_i,
      data       => data_i,
      data_last  => data_last_i,
      busy       => busy,
      err        => err,
      req        => req,
      gnt        => gnt,
      cmd        => cmd,
      cmd_valid  => cmd_valid,
      cmd_ready  => cmd_ready,
      sdo_data   => sdo_data,
      sdo_valid  => sdo_valid,
      sdo_ready  => sdo_ready,
      sdi_data   => sdi_data,
      sdi_valid  => sdi_valid,
      sync       => sync,
      sync_valid => sync_valid,
      core_rst   => core_rst
    );

  -- Kanal başına sonuç register'ları ve scan_done
  u_regs : entity work.ad7923_ch_regs
    port map (
      clk        => clk,
      rst_n      => rst_n,
      data_valid => data_valid_i,
      data_ch    => data_ch_i,
      data       => data_i,
      data_last  => data_last_i,
      ch0_data   => ch0_data,
      ch1_data   => ch1_data,
      ch2_data   => ch2_data,
      ch3_data   => ch3_data,
      ch0_valid  => ch0_valid,
      ch1_valid  => ch1_valid,
      ch2_valid  => ch2_valid,
      ch3_valid  => ch3_valid,
      scan_done  => scan_done
    );

  -- SPI master (spi_exec): komut stream'ini SPI dalga şekline çevirir.
  -- Kullanılmayan çıkışlar: sdo_t (MOSI hep sürülür), three_wire.
  u_spi : spi_exec
    generic map (
      NUM_OF_CS       => C_NUM_OF_CS,
      DEFAULT_SPI_CFG => C_DEFAULT_SPI_CFG,
      DEFAULT_CLK_DIV => CLK_DIV,
      DATA_WIDTH      => C_DATA_WIDTH,
      NUM_OF_SDI      => C_NUM_OF_SDI,
      SDO_DEFAULT     => C_SDO_DEFAULT,
      SDI_DELAY       => C_SDI_DELAY
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
