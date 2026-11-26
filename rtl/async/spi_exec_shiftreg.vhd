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
-- Derived from ADI HDL spi_engine_execution_shiftreg.v (hdl_2026_r1, b62abef).
-- Translated to VHDL.
--
-- spi_exec_shiftreg : ASYNC reset sürümü (DATA PATH).
--   resetn: async assert / sync deassert (projedeki reset synchronizer'dan).
--   Bütün register'lar resetn ile async olarak sıfırlanır; initial value kullanılmaz.
--   Reset kalktıktan sonra davranış birebir çeviri (spi_exec_p1_shiftreg) ile aynıdır.
--   Desteklenen: ECHO_SCLK = 0 (ECHO_SCLK yolu çevrilmedi; echo_last_bit = '0').
--
-- GENEL BAKIŞ (DATA PATH)
--   SDO: sdo_data stream'i -> SDO buffer (1 kelime) -> aligner (MSB'ye yaslama)
--        -> SDO shift register (MSB önce, trigger_tx ile kayar) -> sdo_int
--   SDI: sdi -> RX delay line (trigger_rx, SDI_DELAY + 1 clk gecikme)
--        -> SDI shift register (MISO hattı başına) -> sdi_data;
--        kelime tamamlanınca sdi_data_valid (sdi_data_ready ile düşer)
-- ***************************************************************************

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_exec_shiftreg is
  generic (
    DEFAULT_SPI_CFG : integer := 0;
    DATA_WIDTH      : integer := 8;
    NUM_OF_SDI      : integer := 1;
    SDI_DELAY       : std_logic_vector(1 downto 0) := "00";
    SDO_DEFAULT     : std_logic_vector(0 downto 0) := "0";
    CMD_TRANSFER    : std_logic_vector(2 downto 0) := "000"
  );
  port (
    clk             : in  std_logic;              -- sistem clock'u
    resetn          : in  std_logic;              -- async aktif-düşük reset
    -- spi io
    sdi             : in  std_logic_vector(NUM_OF_SDI - 1 downto 0);  -- MISO hatları
    sdo_int         : out std_logic;              -- SDO biti (pin register'ı öncesi)
    echo_sclk       : in  std_logic;              -- kullanılmaz (ECHO_SCLK = 0)
    -- spi data
    sdo_data        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);  -- SDO kelime stream'i
    sdo_data_valid  : in  std_logic;
    sdo_data_ready  : out std_logic;
    sdi_data        : out std_logic_vector(NUM_OF_SDI * DATA_WIDTH - 1 downto 0);  -- SDI kelimeleri
    sdi_data_valid  : out std_logic;
    sdi_data_ready  : in  std_logic;
    -- cfg and status
    sdo_enabled     : in  std_logic;              -- TRANSFER write biti
    sdi_enabled     : in  std_logic;              -- TRANSFER read biti
    current_cmd     : in  std_logic_vector(15 downto 0);  -- yürütülen komut
    sdo_idle_state  : in  std_logic;              -- boşta SDO seviyesi
    left_aligned    : in  std_logic_vector(7 downto 0);  -- DATA_WIDTH - word_length
    word_length     : in  std_logic_vector(7 downto 0);  -- kelime uzunluğu (bit)
    -- timing from main fsm
    sdo_io_ready    : out std_logic;              -- SDO buffer dolu
    echo_last_bit   : out std_logic;              -- kullanılmaz ('0')
    transfer_active : in  std_logic;              -- SCLK üretiliyor
    trigger_tx      : in  std_logic;              -- tx yarı periyot tetiği
    trigger_rx      : in  std_logic;              -- rx yarı periyot tetiği
    first_bit       : in  std_logic;              -- kelimenin ilk biti
    cs_activate     : in  std_logic               -- yeni CS seçimi: SDI temizliği
  );
end entity;

architecture rtl of spi_exec_shiftreg is

  constant SDI_D : integer := to_integer(unsigned(SDI_DELAY));  -- ek SDI örnekleme gecikmesi (clk)

  signal sdi_counter      : unsigned(7 downto 0);         -- örneklenen bit sayısı
  signal data_sdo_shift   : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- SDO shift reg.
  signal trigger_rx_d     : std_logic_vector(SDI_D + 1 downto 0);  -- RX delay line
  signal aligned_sdo_data : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- MSB'ye yaslı
  signal sdo_data_reg     : std_logic_vector(DATA_WIDTH - 1 downto 0);  -- SDO buffer
  signal data_sdo_v       : std_logic;                    -- SDO buffer dolu
  signal sdo_toshiftreg   : std_logic;                    -- buffer -> shift register
  signal last_sdi_bit     : std_logic;                    -- kelimenin son SDI biti
  signal trigger_rx_s     : std_logic;                    -- gecikmeli örnekleme tetiği
  signal current_instr    : std_logic_vector(2 downto 0);  -- yürütülen komut kodu
  signal sdo_data_ready_i : std_logic;                    -- sdo_data_ready (iç)
  signal sdi_data_valid_r : std_logic;                    -- sdi_data_valid register'ı

begin

  -- yürütülen komutun kodu (SDO yalnız TRANSFER'de sürülür)
  current_instr <= current_cmd(14 downto 12);
  echo_last_bit <= '0';   -- ECHO_SCLK = 0: kullanılmıyor

  -- SDO BUFFER: 1 kelimelik bekleme alanı. Kaynak: shiftreg.v 92-106
  -- sdo_data_ready: buffer boş veya bu clock'ta shift register'a aktarılıyor.
  -- sdo_io_ready  : buffer dolu (control path kelime başlatabilir).
  sdo_data_ready_i <= (not data_sdo_v) or sdo_toshiftreg;
  sdo_data_ready   <= sdo_data_ready_i;
  sdo_io_ready     <= data_sdo_v;

  p_sdo_buffer : process(clk, resetn)
  begin
    if resetn = '0' then
      data_sdo_v   <= '0';
      sdo_data_reg <= (others => '0');
    elsif rising_edge(clk) then
      if sdo_data_ready_i = '1' and sdo_data_valid = '1' then
        data_sdo_v   <= '1';
        sdo_data_reg <= sdo_data;
      elsif sdo_toshiftreg = '1' then
        data_sdo_v <= '0';
      end if;
    end if;
  end process;

  -- ALIGNER: kısa kelimeyi MSB'ye yaslar. Kaynak: shiftreg.v 108-115
  -- word_length < DATA_WIDTH ise kelime left_aligned bit sola kaydırılır.
  -- Verilog: genişlikten büyük shift -> 0 (numeric_std shift_left da 0 verir)
  p_aligner : process(clk, resetn)
  begin
    if resetn = '0' then
      aligned_sdo_data <= (others => '0');
    elsif rising_edge(clk) then
      aligned_sdo_data <= std_logic_vector(shift_left(unsigned(sdo_data_reg),
                                                      to_integer(unsigned(left_aligned))));
    end if;
  end process;

  -- SDO SHIFT REGISTER: MSB önce. Kaynak: shiftreg.v 117-131
  -- (orijinalde reset yok; burada reset değeri = SDO boşta seviyesi)
  -- SDO kapalıyken / TRANSFER dışında boşta seviyesi; kelimenin ilk bitinde
  -- yüklenir, sonra her trigger_tx'te 1 bit sola kayar. sdo_int = MSB.
  p_sdo_shift : process(clk, resetn)
  begin
    if resetn = '0' then
      data_sdo_shift <= (others => SDO_DEFAULT(0));
    elsif rising_edge(clk) then
      if sdo_enabled = '0' or current_instr /= CMD_TRANSFER then
        data_sdo_shift <= (others => sdo_idle_state);
      elsif transfer_active = '1' and trigger_tx = '1' then
        if first_bit = '1' then
          data_sdo_shift <= aligned_sdo_data;
        else
          data_sdo_shift <= data_sdo_shift(DATA_WIDTH - 2 downto 0) & '0';
        end if;
      end if;
    end if;
  end process;
  -- sdo_int = MSB; sdo_toshiftreg: buffer'daki kelime bu clock'ta shift register'a alındı
  sdo_int        <= data_sdo_shift(DATA_WIDTH - 1);
  sdo_toshiftreg <= transfer_active and trigger_tx and first_bit and sdo_enabled;

  -- RX DELAY LINE: MISO örnekleme anı. Kaynak: shiftreg.v 133-141
  -- Verilog {trigger_rx_d, trigger_rx} hedef genişliğe kırpılır -> en üst bit düşer.
  -- trigger_rx, SDI_DELAY + 1 clk geciktirilir: SCLK pin register'ının 1 clk'ı ve
  -- SDI_DELAY ile ek gecikme (pin / board / slave çıkış gecikmesi) telafi edilir.
  p_rx_delay : process(clk, resetn)
  begin
    if resetn = '0' then
      trigger_rx_d <= (others => '0');
    elsif rising_edge(clk) then
      trigger_rx_d <= trigger_rx_d(SDI_D downto 0) & trigger_rx;
    end if;
  end process;
  trigger_rx_s <= trigger_rx_d(SDI_D + 1);

  -- SDI SHIFT REGISTER (her MISO hattı için). Kaynak: shiftreg.v 259-275
  -- resetn ile async, yeni CS seçiminde (cs_activate) senkron temizlenir; sdi_data latch'lenmez.
  -- (Orijinalde reset sırasında cs_activate = 1 ve clock kenarı ile temizleniyordu.)
  g_sdi : for i in 0 to NUM_OF_SDI - 1 generate
    signal data_sdi_shift : std_logic_vector(DATA_WIDTH - 1 downto 0);
  begin
    p_sdi_shift : process(clk, resetn)
    begin
      if resetn = '0' then
        data_sdi_shift <= (others => '0');
      elsif rising_edge(clk) then
        if cs_activate = '1' then
          data_sdi_shift <= (others => '0');
        elsif trigger_rx_s = '1' then
          data_sdi_shift <= data_sdi_shift(DATA_WIDTH - 2 downto 0) & sdi(i);
        end if;
      end if;
    end process;
    sdi_data((i + 1) * DATA_WIDTH - 1 downto i * DATA_WIDTH) <= data_sdi_shift;
  end generate;

  -- sdi_counter. Kaynak: shiftreg.v 277-286
  -- Verilog width: (sdi_counter == word_length-1) 32 bitte -> word_length = 0 iken hiç eşit olmaz.
  -- Örneklenen bit sayısı; word_length bit dolunca kelime tamamdır (last_sdi_bit).
  last_sdi_bit <= '1' when to_integer(sdi_counter) = to_integer(unsigned(word_length)) - 1 else '0';

  p_sdi_counter : process(clk, resetn)
  begin
    if resetn = '0' then
      sdi_counter <= (others => '0');
    elsif rising_edge(clk) then
      if trigger_rx_s = '1' then
        if last_sdi_bit = '1' then
          sdi_counter <= (others => '0');
        else
          sdi_counter <= sdi_counter + 1;
        end if;
      end if;
    end if;
  end process;

  -- sdi_data_valid. Kaynak: shiftreg.v 288-295
  -- Kelime tamamlanınca (sdi_enabled ise) '1', sdi_data_ready ile '0'.
  p_sdi_valid : process(clk, resetn)
  begin
    if resetn = '0' then
      sdi_data_valid_r <= '0';
    elsif rising_edge(clk) then
      if sdi_enabled = '1' and last_sdi_bit = '1' and trigger_rx_s = '1' then
        sdi_data_valid_r <= '1';
      elsif sdi_data_ready = '1' then
        sdi_data_valid_r <= '0';
      end if;
    end if;
  end process;
  sdi_data_valid <= sdi_data_valid_r;

end architecture;
