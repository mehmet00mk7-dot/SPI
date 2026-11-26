-- ***************************************************************************
-- ***************************************************************************
-- Copyright (C) 2015-2026 Analog Devices, Inc. All rights reserved.
--
-- In this HDL repository, there are many different and unique modules, consisting
-- of various HDL (Verilog or VHDL) components. The individual modules are
-- developed independently, and may be accompanied by separate and unique license
-- terms.
--
-- The user should read each of these license terms, and understand the
-- freedoms and responsibilities that he or she has by using this source/core.
--
-- This core is distributed in the hope that it will be useful, but WITHOUT ANY
-- WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
-- A PARTICULAR PURPOSE.
--
-- Redistribution and use of source or resulting binaries, with or without modification
-- of this file, are permitted under one of the following two license terms:
--
--   1. The GNU General Public License version 2 as published by the
--      Free Software Foundation, which can be found in the top level directory
--      of this repository (LICENSE_GPL2), and also online at:
--      <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
--
-- OR
--
--   2. An ADI specific BSD license, which can be found in the top level directory
--      of this repository (LICENSE_ADIBSD), and also on-line at:
--      https://github.com/analogdevicesinc/hdl/blob/main/LICENSE_ADIBSD
--      This will allow to generate bit files and not release the source code,
--      as long as it attaches to an ADI device.
--
-- ***************************************************************************
-- ***************************************************************************
-- Derived from ADI HDL spi_engine_execution.v (hdl_2026_r1, b62abef).
-- Translated to VHDL.
--
-- spi_exec : ASYNC reset sürümü (CONTROL PATH).
--
-- RESET STRATEJİSİ
--   * resetn projedeki reset synchronizer'dan gelir: async assert, sync deassert,
--     PLL lock'a bağlı. Async reset olarak YALNIZCA resetn kullanılır.
--   * Bütün register'lar resetn ile async sıfırlanır; initial value kullanılmaz.
--   * Reset değerleri, orijinal core'un "reset + birkaç clock" sonundaki durumudur.
--     Bu yüzden reset kalktıktan sonra davranış orijinalle birebir aynıdır.
--   * Pin çıkışları reset anında, clock beklemeden güvenli değere gider:
--     cs = hepsi '1', sclk = CPOL, sdo = SDO_DEFAULT, sdo_t = '1'.
--   * Orijinalden farklar (yalnız reset ile ilgili):
--     - Orijinalde reset'siz olan register'lar (cmd_d1, sdo_enabled, sdi_enabled,
--       pending_sdi_data_valid, counter'lar, pin çıkış register'ları, SDO/SDI shift
--       register'ları, RX delay line) burada da reset'lenir.
--     - Orijinalde SDI shift register, reset sırasında cs_activate = 1 ve clock kenarı
--       ile temizleniyordu; burada doğrudan resetn ile temizlenir. cs_activate yalnız
--       normal çalışmadaki "yeni CS seçimi" temizliği için kalır.
--   * idle ile yapılan temizlemeler senkron mantıktır (reset değildir), aynen korunur.
--
--   Desteklenen: ECHO_SCLK = 0. VHDL büyük/küçük harf ayırmadığı için ECHO_SCLK
--   generic'i echo_sclk port'u ile çakışır; generic yoktur, davranış ECHO_SCLK = 0'dır.
--   NUM_OF_CS: 1..8. Orijinal hatalar (SLEEP n = 255 hang) bu sürümde de AYNEN durur.
--
-- GENEL BAKIŞ
--   spi_exec, 16 bit komut stream'ini (cmd / cmd_valid / cmd_ready) SPI dalga
--   şekline çevirir. Komutlar sırayla, birer birer yürütülür; cmd_ready = idle.
--     * Komut çözücü        : cmd[14:12] -> exec_*_cmd (kabul clock'unda 1 clk)
--     * Config register'ları : cpha, cpol, three_wire, sdo_idle_state, clk_div,
--                             word_length, left_aligned (WRITE komutu)
--     * Clock divider       : her (clk_div + 1) clk'ta 1 clk'lık trigger
--                             (= SCLK yarı periyodu)
--     * Transfer kontrolü   : bit / kelime counter'ları, transfer_active,
--                             wait_for_io, io_ready (SDO verisi / SDI okuması)
--     * CS generator        : CHIPSELECT öncesi / sonrası bekleme, cs_r
--     * SLEEP / SYNC        : sleep_counter, sync_valid / sync
--     * Idle FSM            : komut bitince idle = '1' (yeni komut kabul edilir)
--     * Data path           : spi_exec_shiftreg (SDO / SDI shift register'ları)
--     * Pin register'ları   : sclk, sdo, sdo_t, cs (hepsi registered çıkış)
--
-- KOMUT FORMATI (cmd[15:0]; cmd[15] kullanılmaz)
--   [14:12] = 000 TRANSFER   : [9] read (SDI), [8] write (SDO), [7:0] kelime sayısı - 1
--   [14:12] = 001 CHIPSELECT : [9:8] bekleme (SCLK periyodu; CS değişiminden önce ve
--                              sonra), [NUM_OF_CS-1:0] yeni CS seviyeleri
--   [14:12] = 010 WRITE      : [9:8] register (00 clk_div, 01 config, 10 word length),
--                              [7:0] değer. Tek clock'ta biter (idle düşmez).
--                              config: [0] CPHA, [1] CPOL, [2] three_wire,
--                              [3] sdo_idle_state
--   [14:12] = 011 MISC       : [8] = 0 SYNC ([7:0] = id), [8] = 1 SLEEP ([7:0] = süre)
--   [14:12] = 100 CS_INV     : [NUM_OF_CS-1:0] CS polarite maskesi (tek clock)
--
-- SPI ZAMANLAMASI
--   Bir SCLK periyodu iki yarı periyottur, her biri (clk_div + 1) clk:
--     ntx_rx = 0 : trigger_tx -> SDO'ya yeni bit (shift register kayar)
--     ntx_rx = 1 : trigger_rx -> SDI örneklemesi (shiftreg'de SDI_DELAY + 1 clk sonra)
--   Transfer sırasında SCLK = CPOL xor CPHA xor ntx_rx, boşta CPOL.
--   f_SCLK = f_clk / (2 * (clk_div + 1)). Bütün pin çıkışları 1 clk registered.
-- ***************************************************************************

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_exec is
  generic (
    NUM_OF_CS       : integer := 1;                   -- CS hattı sayısı (1..8)
    DEFAULT_SPI_CFG : integer := 0;                   -- reset config: [0] CPHA [1] CPOL [2] 3-wire
    DEFAULT_CLK_DIV : integer := 0;                   -- reset clk_div
    DATA_WIDTH      : integer := 8;                   -- kelime genişliği: 8/16/24/32
    NUM_OF_SDI      : integer := 1;                   -- MISO hattı sayısı
    SDO_DEFAULT     : std_logic_vector(0 downto 0) := "0";  -- boşta / reset SDO seviyesi
    SDI_DELAY       : std_logic_vector(1 downto 0) := "00"  -- ek SDI örnekleme gecikmesi (clk)
  );
  port (
    clk            : in  std_logic;                   -- sistem clock'u
    resetn         : in  std_logic;                   -- async aktif-düşük reset
    -- komut stream'i (16 bit komut): valid / ready
    cmd_ready      : out std_logic;
    cmd_valid      : in  std_logic;
    cmd            : in  std_logic_vector(15 downto 0);
    -- SDO kelime stream'i (MOSI): valid / ready
    sdo_data_valid : in  std_logic;
    sdo_data_ready : out std_logic;
    sdo_data       : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
    -- SDI kelime stream'i (MISO): valid / ready
    sdi_data_ready : in  std_logic;
    sdi_data_valid : out std_logic;
    sdi_data       : out std_logic_vector(NUM_OF_SDI * DATA_WIDTH - 1 downto 0);
    -- SYNC geri bildirimi (id): valid / ready
    sync_ready     : in  std_logic;
    sync_valid     : out std_logic;
    sync           : out std_logic_vector(7 downto 0);
    -- SPI pin'leri
    echo_sclk      : in  std_logic;                   -- kullanılmaz (ECHO_SCLK = 0)
    sclk           : out std_logic;                   -- SPI SCLK (registered)
    sdo            : out std_logic;                   -- SPI MOSI (registered)
    sdo_t          : out std_logic;                   -- MOSI tri-state: '1' = high-Z
    sdi            : in  std_logic_vector(NUM_OF_SDI - 1 downto 0);  -- SPI MISO
    cs             : out std_logic_vector(NUM_OF_CS - 1 downto 0);  -- SPI CS (registered)
    three_wire     : out std_logic                    -- 3-wire mod (config [2])
  );
end entity;

architecture rtl of spi_exec is

  -- KOMUT KODLARI (cmd[14:12]). Kaynak: execution.v 77-88
  -- MISC alt kodu cmd[8]; WRITE register seçimi cmd[9:8].
  constant CMD_TRANSFER    : std_logic_vector(2 downto 0) := "000";
  constant CMD_CHIPSELECT  : std_logic_vector(2 downto 0) := "001";
  constant CMD_WRITE       : std_logic_vector(2 downto 0) := "010";
  constant CMD_MISC        : std_logic_vector(2 downto 0) := "011";
  constant CMD_CS_INV      : std_logic_vector(2 downto 0) := "100";
  constant MISC_SYNC       : std_logic := '0';
  constant MISC_SLEEP      : std_logic := '1';
  constant REG_CLK_DIV     : std_logic_vector(1 downto 0) := "00";
  constant REG_CONFIG      : std_logic_vector(1 downto 0) := "01";
  constant REG_WORD_LENGTH : std_logic_vector(1 downto 0) := "10";

  -- bit_counter genişliği: kelimedeki bit numarasını tutacak kadar (DATA_WIDTH'e göre)
  function bcw(dw : integer) return integer is
  begin
    if dw > 16 then return 5; elsif dw > 8 then return 4; else return 3; end if;
  end function;
  constant BIT_COUNTER_WIDTH : integer := bcw(DATA_WIDTH);

  -- Reset değerleri: CFG [0] CPHA, [1] CPOL, [2] three_wire; RST_CLK_DIV = clk_div
  constant CFG          : unsigned(31 downto 0) := to_unsigned(DEFAULT_SPI_CFG, 32);
  constant RST_CLK_DIV  : unsigned(7 downto 0)  := to_unsigned(DEFAULT_CLK_DIV, 8);

  -- clk_div = 0 ise her clock bir yarı periyot sonudur: clk_div_last reset'te '1'
  function rst_clk_div_last return std_logic is
  begin
    if DEFAULT_CLK_DIV = 0 then return '1'; else return '0'; end if;
  end function;

  -- İÇ SİNYALLER. Kaynak: execution.v 96-174 (initial value yok, her şey reset'ten)
  signal sclk_int                 : std_logic;                -- SCLK (pin register'ı öncesi)
  signal sdo_t_int                : std_logic;                -- sdo_t (pin register'ı öncesi)
  signal idle                     : std_logic;                -- '1': komut bekleniyor
  signal clk_div_counter          : unsigned(7 downto 0);     -- yarı periyot geri sayıcı
  signal clk_div_last             : std_logic;                -- yarı periyodun son clock'u
  signal sleep_counter            : unsigned(7 downto 0);     -- SLEEP / CS bekleme (SCLK)
  signal bit_counter              : unsigned(BIT_COUNTER_WIDTH - 1 downto 0);  -- kelimedeki bit
  signal transfer_counter         : unsigned(7 downto 0);     -- TRANSFER'deki kelime
  signal ntx_rx                   : std_logic;                -- 0: tx, 1: rx yarı periyodu
  signal sleep_counter_increment  : std_logic;                -- 2 yarı periyotta 1 artış
  signal trigger                  : std_logic;                -- yarı periyot tetiği (1 clk)
  signal wait_for_io              : std_logic;                -- transfer veri bekliyor
  signal transfer_active          : std_logic;                -- SCLK üretiliyor
  signal transfer_done            : std_logic;                -- TRANSFER bitti (1 clk)
  signal last_transfer            : std_logic;                -- son kelime aktarılıyor
  signal word_length              : unsigned(7 downto 0);     -- kelime uzunluğu (bit)
  signal last_bit_count           : unsigned(7 downto 0);     -- word_length - 1
  signal left_aligned             : unsigned(7 downto 0);     -- DATA_WIDTH - word_length
  signal first_bit                : std_logic;                -- kelimenin ilk biti
  signal cmd_d1                   : std_logic_vector(15 downto 0);  -- yürütülen komut
  signal cpha                     : std_logic;                -- SPI CPHA
  signal cpol                     : std_logic;                -- SPI CPOL
  signal clk_div                  : unsigned(7 downto 0);     -- SCLK bölücü
  signal sdo_idle_state           : std_logic;                -- boşta SDO seviyesi
  signal cs_inv_mask_reg          : std_logic_vector(NUM_OF_CS - 1 downto 0);  -- CS polarite
  signal sdo_enabled              : std_logic;                -- TRANSFER write biti
  signal sdi_enabled              : std_logic;                -- TRANSFER read biti
  signal pending_sdi_data_valid   : std_logic;                -- alınmamış SDI kelimesi var
  signal sdo_enabled_io           : std_logic;                -- kabul clock'unda cmd(8)
  signal sdo_int_s                : std_logic;                -- shift register MSB'si
  signal last_bit                 : std_logic;                -- kelimenin son biti
  signal end_of_word              : std_logic;                -- son bitin rx yarı periyodu biter
  signal inst, inst_d1            : std_logic_vector(2 downto 0);  -- gelen / yürütülen kod
  signal exec_cmd                 : std_logic;                -- komut kabulü (valid and ready)
  -- exec_*: kabul edilen komutun tipi (1 clk)
  signal exec_transfer_cmd        : std_logic;
  signal exec_cs_inv_cmd          : std_logic;
  signal exec_write_cmd           : std_logic;
  signal exec_chipselect_cmd      : std_logic;
  signal exec_misc_cmd            : std_logic;
  signal exec_sync_cmd            : std_logic;
  signal trigger_tx, trigger_rx   : std_logic;                -- tx / rx yarı periyot tetiği
  signal cs_sleep_counter         : std_logic_vector(1 downto 0);  -- sleep_counter[1:0]
  signal sleep_counter_compare    : std_logic;                -- SLEEP süresi doldu
  signal cs_sleep_counter_compare : std_logic;                -- CS bekleme süresi doldu
  signal cs_sleep_early_exit      : std_logic;                -- CS bekleme = 0
  signal cs_sleep_repeat          : std_logic;                -- 0: CS öncesi, 1: sonrası bekleme
  signal cs_activate              : std_logic;                -- yeni CS seçimi: SDI temizliği
  signal io_ready1, io_ready2     : std_logic;                -- kelime başlat / devam et
  signal sdo_io_ready             : std_logic;                -- SDO buffer dolu
  signal cs_gen                   : std_logic;                -- bu clock'ta CS güncellenir
  signal cmd_ready_i              : std_logic;                -- cmd_ready (= idle)
  signal sync_valid_r             : std_logic;                -- sync_valid register'ı
  signal cs_r                     : std_logic_vector(NUM_OF_CS - 1 downto 0);  -- CS pin reg.
  signal three_wire_r             : std_logic;                -- three_wire register'ı
  signal sdi_data_valid_i         : std_logic;                -- sdi_data_valid (iç)

begin

  assert NUM_OF_CS >= 1 and NUM_OF_CS <= 8
    report "spi_exec: NUM_OF_CS 1..8 olmali" severity failure;

  -- DATA PATH. Kaynak: execution.v 176-207
  -- SDO buffer + hizalama + SDO shift register, SDI shift register + örnekleme gecikmesi.
  u_shiftreg : entity work.spi_exec_shiftreg
    generic map (
      DEFAULT_SPI_CFG => DEFAULT_SPI_CFG,
      DATA_WIDTH      => DATA_WIDTH,
      NUM_OF_SDI      => NUM_OF_SDI,
      SDI_DELAY       => SDI_DELAY,
      SDO_DEFAULT     => SDO_DEFAULT,
      CMD_TRANSFER    => CMD_TRANSFER)
    port map (
      clk             => clk,
      resetn          => resetn,
      sdi             => sdi,
      sdo_int         => sdo_int_s,
      echo_sclk       => echo_sclk,
      sdo_data        => sdo_data,
      sdo_data_valid  => sdo_data_valid,
      sdo_data_ready  => sdo_data_ready,
      sdi_data        => sdi_data,
      sdi_data_valid  => sdi_data_valid_i,
      sdi_data_ready  => sdi_data_ready,
      sdo_enabled     => sdo_enabled,
      sdi_enabled     => sdi_enabled,
      current_cmd     => cmd_d1,
      sdo_idle_state  => sdo_idle_state,
      left_aligned    => std_logic_vector(left_aligned),
      word_length     => std_logic_vector(word_length),
      sdo_io_ready    => sdo_io_ready,
      echo_last_bit   => open,
      transfer_active => transfer_active,
      trigger_tx      => trigger_tx,
      trigger_rx      => trigger_rx,
      first_bit       => first_bit,
      cs_activate     => cs_activate);
  sdi_data_valid <= sdi_data_valid_i;

  -- first_bit. Kaynak: execution.v 124 (Verilog width: 8 bit, zero-extend)
  -- Kelimenin ilk biti: SDO shift register bu anda yeni kelimeyle yüklenir.
  first_bit <= '1' when (bit_counter = 0) or
                        (to_integer(bit_counter) = to_integer(word_length)) else '0';

  -- KOMUT ÇÖZÜCÜ. Kaynak: execution.v 148-157
  -- Komut yalnız idle iken kabul edilir (exec_cmd); SYNC = MISC ve cmd[8] = '0'.
  inst                <= cmd(14 downto 12);
  inst_d1             <= cmd_d1(14 downto 12);
  exec_cmd            <= cmd_ready_i and cmd_valid;
  exec_transfer_cmd   <= exec_cmd when inst = CMD_TRANSFER   else '0';
  exec_cs_inv_cmd     <= exec_cmd when inst = CMD_CS_INV     else '0';
  exec_write_cmd      <= exec_cmd when inst = CMD_WRITE      else '0';
  exec_chipselect_cmd <= exec_cmd when inst = CMD_CHIPSELECT else '0';
  exec_misc_cmd       <= exec_cmd when inst = CMD_MISC       else '0';
  exec_sync_cmd       <= exec_misc_cmd when cmd(8) = MISC_SYNC else '0';

  -- CS GENERATOR (1/3). Kaynak: execution.v 209-213
  -- cs_gen: CHIPSELECT yürütülürken CS'nin güncellendiği clock (öncesi bekleme
  -- bittiğinde, bekleme 0 ise hemen). cmd_ready = idle.
  cs_gen <= '1' when inst_d1 = CMD_CHIPSELECT
                 and (cs_sleep_counter_compare = '1' or cs_sleep_early_exit = '1')
                 and cs_sleep_repeat = '0'
                 and idle = '0' else '0';
  cmd_ready_i <= idle;
  cmd_ready   <= cmd_ready_i;

  -- sdo_enabled / sdi_enabled. Kaynak: execution.v 215-222
  -- TRANSFER kabulünde write / read bitleri saklanır; sdo_enabled_io kabul
  -- clock'unda doğrudan cmd(8)'i kullanır.
  p_enables : process(clk, resetn)
  begin
    if resetn = '0' then
      sdo_enabled <= '0';
      sdi_enabled <= '0';
    elsif rising_edge(clk) then
      if exec_transfer_cmd = '1' then
        sdo_enabled <= cmd(8);
        sdi_enabled <= cmd(9);
      end if;
    end if;
  end process;
  sdo_enabled_io <= cmd(8) when exec_transfer_cmd = '1' else sdo_enabled;

  -- cmd_d1: yürütülen komut. Kaynak: execution.v 224-227
  -- Kabul edilen komut, yürütme boyunca burada tutulur.
  p_cmd_d1 : process(clk, resetn)
  begin
    if resetn = '0' then
      cmd_d1 <= (others => '0');
    elsif rising_edge(clk) then
      if cmd_ready_i = '1' and cmd_valid = '1' then
        cmd_d1 <= cmd;
      end if;
    end if;
  end process;

  -- last_bit_count (8 bite kırpılır). Kaynak: execution.v 229-235
  -- word_length - 1 (1 clk gecikmeli); last_bit karşılaştırmasında kullanılır.
  p_last_bit_count : process(clk, resetn)
  begin
    if resetn = '0' then
      last_bit_count <= to_unsigned(DATA_WIDTH - 1, 8);
    elsif rising_edge(clk) then
      last_bit_count <= word_length - 1;
    end if;
  end process;

  -- CONFIG REGISTER'LARI. Kaynak: execution.v 236-254
  -- WRITE komutu, cmd[9:8] ile register seçer:
  --   REG_CONFIG      : cpha, cpol, three_wire, sdo_idle_state
  --   REG_CLK_DIV     : SCLK bölücü
  --   REG_WORD_LENGTH : kelime uzunluğu ve SDO hizalaması (left_aligned)
  p_config : process(clk, resetn)
  begin
    if resetn = '0' then
      cpha           <= CFG(0);
      cpol           <= CFG(1);
      three_wire_r   <= CFG(2);
      sdo_idle_state <= SDO_DEFAULT(0);
      clk_div        <= RST_CLK_DIV;
      word_length    <= to_unsigned(DATA_WIDTH, 8);
      left_aligned   <= (others => '0');
    elsif rising_edge(clk) then
      if exec_write_cmd = '1' then
        if cmd(9 downto 8) = REG_CONFIG then
          cpha           <= cmd(0);
          cpol           <= cmd(1);
          three_wire_r   <= cmd(2);
          sdo_idle_state <= cmd(3);
        elsif cmd(9 downto 8) = REG_CLK_DIV then
          clk_div <= unsigned(cmd(7 downto 0));
        elsif cmd(9 downto 8) = REG_WORD_LENGTH then
          word_length  <= unsigned(cmd(7 downto 0));
          -- Verilog width: DATA_WIDTH - cmd[7:0], 8 bite kırpılır
          left_aligned <= to_unsigned(DATA_WIDTH, 8) - unsigned(cmd(7 downto 0));
        end if;
      end if;
    end if;
  end process;
  three_wire <= three_wire_r;

  -- CLOCK DIVIDER (1/2): clk_div_last. Kaynak: execution.v 262-268
  -- Yarı periyodun son clock'u: counter 1'e indiğinde (clk_div = 0 ise her clock).
  p_clk_div_last : process(clk, resetn)
  begin
    if resetn = '0' then
      clk_div_last <= rst_clk_div_last;
    elsif rising_edge(clk) then
      if (clk_div_last = '0' and idle = '0' and wait_for_io = '0' and clk_div_counter = 1)
         or clk_div = 0 then
        clk_div_last <= '1';
      else
        clk_div_last <= '0';
      end if;
    end if;
  end process;

  -- CLOCK DIVIDER (2/2): counter ve trigger. Kaynak: execution.v 270-278
  -- Yarı periyot sonunda (veya boşta / beklemede) counter yeniden yüklenir ve
  -- trigger 1 clk '1' olur; trigger_tx / trigger_rx yarı periyodun tipine göre.
  p_clk_div : process(clk, resetn)
  begin
    if resetn = '0' then
      clk_div_counter <= RST_CLK_DIV;
      trigger         <= '1';
    elsif rising_edge(clk) then
      if clk_div_last = '1' or idle = '1' or wait_for_io = '1' then
        clk_div_counter <= clk_div;
        trigger         <= '1';
      else
        clk_div_counter <= clk_div_counter - 1;
        trigger         <= '0';
      end if;
    end if;
  end process;

  trigger_tx <= trigger and not ntx_rx;
  trigger_rx <= trigger and ntx_rx;

  -- SLEEP / CS bekleme karşılaştırmaları. Kaynak: execution.v 283-285
  -- Verilog width: cmd_d1[7:0]+1 32 bit -> n = 255 iken hedef 256, 8 bit counter ulaşamaz
  -- (ORİJİNAL HATA, bilerek korunuyor).
  -- cs_sleep_*: CHIPSELECT bekleme süresi cmd[9:8] SCLK periyodu; "00" ise beklemesiz.
  cs_sleep_counter         <= std_logic_vector(sleep_counter(1 downto 0));
  sleep_counter_compare    <= '1' when to_integer(sleep_counter) =
                                       to_integer(unsigned(cmd_d1(7 downto 0))) + 1 else '0';
  cs_sleep_counter_compare <= '1' when cs_sleep_counter = cmd_d1(9 downto 8) else '0';
  cs_sleep_early_exit      <= '1' when cmd_d1(9 downto 8) = "00" else '0';

  -- CS GENERATOR (2/3): cs_sleep_repeat. Kaynak: execution.v 287-297
  -- 0 = CS değişimi öncesi bekleme, 1 = sonrası bekleme; her bekleme bitince döner.
  p_cs_sleep_repeat : process(clk, resetn)
  begin
    if resetn = '0' then
      cs_sleep_repeat <= '0';
    elsif rising_edge(clk) then
      if idle = '1' then
        cs_sleep_repeat <= '0';
      elsif cs_sleep_counter_compare = '1' and inst_d1 = CMD_CHIPSELECT then
        cs_sleep_repeat <= not cs_sleep_repeat;
      end if;
    end if;
  end process;

  -- COUNTER'LAR (idle ile senkron temizlenir). Kaynak: execution.v 299-326
  -- Transfer sırasında: ntx_rx her yarı periyotta döner; rx yarı periyodunda
  -- bit_counter artar; son bitte bit_counter sıfırlanır, transfer_counter artar.
  -- Transfer dışında (CHIPSELECT / SLEEP): sleep_counter her SCLK periyodunda 1 artar,
  -- CS öncesi bekleme bitince sıfırlanır.
  p_counters : process(clk, resetn)
  begin
    if resetn = '0' then
      bit_counter             <= (others => '0');
      transfer_counter        <= (others => '0');
      ntx_rx                  <= '0';
      sleep_counter_increment <= '0';
      sleep_counter           <= (others => '0');
    elsif rising_edge(clk) then
      if idle = '1' then
        bit_counter             <= (others => '0');
        transfer_counter        <= (others => '0');
        ntx_rx                  <= '0';
        sleep_counter_increment <= '0';
        sleep_counter           <= (others => '0');
      else
        if clk_div_last = '1' and wait_for_io = '0' then
          if last_bit = '1' and transfer_active = '1' and ntx_rx = '1' then
            bit_counter      <= (others => '0');
            transfer_counter <= transfer_counter + 1;
            ntx_rx           <= not ntx_rx;
          else
            if transfer_active = '1' then
              if ntx_rx = '1' then
                bit_counter <= bit_counter + 1;
              end if;
              ntx_rx <= not ntx_rx;
            else
              sleep_counter_increment <= not sleep_counter_increment;
              if sleep_counter_increment = '1' then
                sleep_counter <= sleep_counter + 1;
              end if;
            end if;
          end if;
        end if;
        if cs_sleep_counter_compare = '1' and cs_sleep_repeat = '0' and inst_d1 = CMD_CHIPSELECT then
          sleep_counter <= (others => '0');
        end if;
      end if;
    end if;
  end process;

  -- pending_sdi_data_valid. Kaynak: execution.v 328-334
  -- Son bit örneklendi, SDI kelimesi henüz alınmadı: yeni kelime başlatılmaz.
  p_pending : process(clk, resetn)
  begin
    if resetn = '0' then
      pending_sdi_data_valid <= '0';
    elsif rising_edge(clk) then
      if sdi_enabled = '1' and last_bit = '1' and trigger_rx = '1' then
        pending_sdi_data_valid <= '1';
      elsif sdi_data_ready = '1' then
        pending_sdi_data_valid <= '0';
      end if;
    end if;
  end process;

  -- IDLE STATE MACHINE. Kaynak: execution.v 336-367
  -- TRANSFER / CHIPSELECT / MISC kabulünde idle = '0'; komut bitince '1':
  --   TRANSFER   : transfer_done
  --   CHIPSELECT : sonrası bekleme bitti (veya bekleme 0)
  --   SLEEP      : sleep_counter = süre + 1;  SYNC : sync_ready
  -- WRITE ve CS_INV tek clock'ta biter (idle düşmez).
  p_idle : process(clk, resetn)
  begin
    if resetn = '0' then
      idle <= '1';
    elsif rising_edge(clk) then
      if exec_transfer_cmd = '1' or exec_chipselect_cmd = '1' or exec_misc_cmd = '1' then
        idle <= '0';
      else
        case inst_d1 is
          when CMD_TRANSFER =>
            if transfer_done = '1' then
              idle <= '1';
            end if;
          when CMD_CHIPSELECT =>
            if (cs_sleep_counter_compare = '1' and cs_sleep_repeat = '1') or cs_sleep_early_exit = '1' then
              idle <= '1';
            end if;
          when CMD_MISC =>
            if cmd_d1(8) = MISC_SLEEP then
              if sleep_counter_compare = '1' then
                idle <= '1';
              end if;
            elsif cmd_d1(8) = MISC_SYNC then
              if sync_ready = '1' then
                idle <= '1';
              end if;
            end if;
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  -- CS_INV maskesi. Kaynak: execution.v 369-377
  -- CS polarite maskesi: cs = komuttaki CS seviyeleri xor maske.
  p_cs_inv : process(clk, resetn)
  begin
    if resetn = '0' then
      cs_inv_mask_reg <= (others => '0');
    elsif rising_edge(clk) then
      if exec_cs_inv_cmd = '1' then
        cs_inv_mask_reg <= cmd(NUM_OF_CS - 1 downto 0);
      end if;
    end if;
  end process;

  -- CS GENERATOR (3/3): CS çıkış register'ı. Kaynak: execution.v 379-385
  -- Reset'te clock beklemeden bütün CS hatları pasif ('1').
  p_cs : process(clk, resetn)
  begin
    if resetn = '0' then
      cs_r <= (others => '1');
    elsif rising_edge(clk) then
      if cs_gen = '1' then
        cs_r <= cmd_d1(NUM_OF_CS - 1 downto 0) xor cs_inv_mask_reg;
      end if;
    end if;
  end process;
  cs <= cs_r;

  -- SYNC. Kaynak: execution.v 387-399
  -- SYNC komutunda sync_valid '1', sync = komutun id'si; sync_ready ile düşer.
  p_sync : process(clk, resetn)
  begin
    if resetn = '0' then
      sync_valid_r <= '0';
    elsif rising_edge(clk) then
      if exec_sync_cmd = '1' then
        sync_valid_r <= '1';
      elsif sync_ready = '1' then
        sync_valid_r <= '0';
      end if;
    end if;
  end process;
  sync_valid <= sync_valid_r;
  sync       <= cmd_d1(7 downto 0);

  -- TRANSFER AKIŞ KONTROLÜ: io_ready. Kaynak: execution.v 401-408
  -- io_ready1: yeni kelimeye başlanabilir (önceki SDI alındı, SDO verisi hazır).
  -- io_ready2: kelime sonunda durmadan devam edilebilir (son kelimeden sonra SDO
  --            verisi gerekmez).
  io_ready1 <= (not pending_sdi_data_valid or sdi_data_ready) and
               (not sdo_enabled_io or sdo_io_ready);
  io_ready2 <= (not sdi_enabled or sdi_data_ready) and
               (not sdo_enabled_io or last_transfer or sdo_io_ready);

  -- last_transfer. Kaynak: execution.v 410-419
  -- Her tx tetiğinde güncellenir: transfer_counter = n (cmd[7:0]) ise son kelime.
  p_last_transfer : process(clk, resetn)
  begin
    if resetn = '0' then
      last_transfer <= '0';
    elsif rising_edge(clk) then
      if idle = '1' then
        last_transfer <= '0';
      elsif trigger_tx = '1' and transfer_active = '1' then
        if transfer_counter = unsigned(cmd_d1(7 downto 0)) then
          last_transfer <= '1';
        else
          last_transfer <= '0';
        end if;
      end if;
    end if;
  end process;

  -- transfer_active / wait_for_io. Kaynak: execution.v 447-470
  -- TRANSFER kabulü: veri hazırsa transfer başlar, değilse wait_for_io.
  -- Kelime sonu: son kelimeyse veya io_ready2 yoksa transfer durur; io_ready2
  -- yoksa wait_for_io ile veri beklenir.
  p_transfer : process(clk, resetn)
  begin
    if resetn = '0' then
      transfer_active <= '0';
      wait_for_io     <= '0';
    elsif rising_edge(clk) then
      if exec_transfer_cmd = '1' then
        wait_for_io     <= not io_ready1;
        transfer_active <= io_ready1;
      elsif wait_for_io = '1' and io_ready1 = '1' then
        wait_for_io     <= '0';
        transfer_active <= not last_transfer;
      elsif transfer_active = '1' and end_of_word = '1' then
        if last_transfer = '1' or io_ready2 = '0' then
          transfer_active <= '0';
        end if;
        if io_ready2 = '0' then
          wait_for_io <= '1';
        end if;
      elsif idle = '1' then
        wait_for_io     <= '0';
        transfer_active <= '0';
      end if;
    end if;
  end process;

  -- transfer_done (ECHO_SCLK = 0 dalı). Kaynak: execution.v 472-482
  -- Son kelime bitti (normal veya bekleme sonrası): idle FSM'e 1 clk.
  p_transfer_done : process(clk, resetn)
  begin
    if resetn = '0' then
      transfer_done <= '0';
    elsif rising_edge(clk) then
      transfer_done <= (wait_for_io and io_ready1 and last_transfer) or
                       (not wait_for_io and transfer_active and end_of_word and last_transfer);
    end if;
  end process;

  -- sdo_t_int. Kaynak: execution.v 484-491
  -- Transfer sırasında SDO sürülür (sdo_enabled ise '0'), aksi halde high-Z ('1').
  p_sdo_t : process(clk, resetn)
  begin
    if resetn = '0' then
      sdo_t_int <= '1';
    elsif rising_edge(clk) then
      if transfer_active = '1' or wait_for_io = '1' then
        sdo_t_int <= not sdo_enabled;
      else
        sdo_t_int <= '1';
      end if;
    end if;
  end process;

  -- cs_activate: yeni CS seçiminde SDI shift register'ı temizler. Kaynak: execution.v 493-499
  -- (Orijinalde reset'te 1 idi; burada SDI shift register zaten resetn ile temizleniyor.)
  p_cs_activate : process(clk, resetn)
    variable all_ones : std_logic;
  begin
    if resetn = '0' then
      cs_activate <= '0';
    elsif rising_edge(clk) then
      all_ones := '1';
      for k in 0 to NUM_OF_CS - 1 loop
        all_ones := all_ones and cmd_d1(k);
      end loop;
      cs_activate <= (not all_ones) and cs_gen;
    end if;
  end process;

  -- last_bit / end_of_word. Kaynak: execution.v 501-505 (Verilog width: 8 bit)
  -- last_bit: kelimenin son biti; end_of_word: son bitin rx yarı periyodu bitiyor.
  last_bit    <= '1' when to_integer(bit_counter) = to_integer(last_bit_count) else '0';
  end_of_word <= last_bit and ntx_rx and clk_div_last;

  -- SCLK ÜRETİMİ. Kaynak: execution.v 507-513
  -- Transfer sırasında SCLK her yarı periyotta döner, boşta CPOL seviyesinde.
  p_sclk_int : process(clk, resetn)
  begin
    if resetn = '0' then
      sclk_int <= CFG(1);
    elsif rising_edge(clk) then
      if transfer_active = '1' then
        sclk_int <= cpol xor cpha xor ntx_rx;
      else
        sclk_int <= cpol;
      end if;
    end if;
  end process;

  -- Pin çıkış register'ları. Kaynak: execution.v 515-520
  -- Reset'te clock beklemeden güvenli seviye: sclk = CPOL, sdo = SDO_DEFAULT, sdo_t = '1'.
  p_out : process(clk, resetn)
  begin
    if resetn = '0' then
      sclk  <= CFG(1);
      sdo   <= SDO_DEFAULT(0);
      sdo_t <= '1';
    elsif rising_edge(clk) then
      sclk  <= sclk_int;
      sdo   <= sdo_int_s;
      sdo_t <= sdo_t_int;
    end if;
  end process;

end architecture;
