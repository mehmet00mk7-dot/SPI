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
-- spi_exec_p1_shiftreg : BİREBİR (cycle-exact) çeviri, SYNC reset.
--   Amaç: orijinal Verilog ile her clock'ta aynı davranış. Hatalar dahil kopyalanır.
--   Desteklenen: ECHO_SCLK = 0 (ECHO_SCLK yolu çevrilmedi; echo_last_bit = '0').
-- ***************************************************************************

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_exec_p1_shiftreg is
  generic (
    DEFAULT_SPI_CFG : integer := 0;
    DATA_WIDTH      : integer := 8;
    NUM_OF_SDI      : integer := 1;
    SDI_DELAY       : std_logic_vector(1 downto 0) := "00";
    CMD_TRANSFER    : std_logic_vector(2 downto 0) := "000"
  );
  port (
    clk             : in  std_logic;
    resetn          : in  std_logic;
    -- spi io
    sdi             : in  std_logic_vector(NUM_OF_SDI - 1 downto 0);
    sdo_int         : out std_logic;
    echo_sclk       : in  std_logic;
    -- spi data
    sdo_data        : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
    sdo_data_valid  : in  std_logic;
    sdo_data_ready  : out std_logic;
    sdi_data        : out std_logic_vector(NUM_OF_SDI * DATA_WIDTH - 1 downto 0);
    sdi_data_valid  : out std_logic;
    sdi_data_ready  : in  std_logic;
    -- cfg and status
    sdo_enabled     : in  std_logic;
    sdi_enabled     : in  std_logic;
    current_cmd     : in  std_logic_vector(15 downto 0);
    sdo_idle_state  : in  std_logic;
    left_aligned    : in  std_logic_vector(7 downto 0);
    word_length     : in  std_logic_vector(7 downto 0);
    -- timing from main fsm
    sdo_io_ready    : out std_logic;
    echo_last_bit   : out std_logic;
    transfer_active : in  std_logic;
    trigger_tx      : in  std_logic;
    trigger_rx      : in  std_logic;
    first_bit       : in  std_logic;
    cs_activate     : in  std_logic
  );
end entity;

architecture rtl of spi_exec_p1_shiftreg is

  constant SDI_D : integer := to_integer(unsigned(SDI_DELAY));

  signal sdi_counter      : unsigned(7 downto 0) := (others => '0');
  signal data_sdo_shift   : std_logic_vector(DATA_WIDTH - 1 downto 0) := (others => '0');
  signal trigger_rx_d     : std_logic_vector(SDI_D + 1 downto 0) := (others => '0');
  signal aligned_sdo_data : std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal sdo_data_reg     : std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal data_sdo_v       : std_logic;
  signal sdo_toshiftreg   : std_logic;
  signal last_sdi_bit     : std_logic;
  signal trigger_rx_s     : std_logic;
  signal current_instr    : std_logic_vector(2 downto 0);
  signal sdo_data_ready_i : std_logic;
  signal sdi_data_valid_r : std_logic;

begin

  current_instr <= current_cmd(14 downto 12);
  echo_last_bit <= '0';   -- ECHO_SCLK = 0: kullanılmıyor

  -- SDO BUFFER: 1 kelimelik bekleme alanı. Kaynak: shiftreg.v 92-106
  sdo_data_ready_i <= (not data_sdo_v) or sdo_toshiftreg;
  sdo_data_ready   <= sdo_data_ready_i;
  sdo_io_ready     <= data_sdo_v;

  p_sdo_buffer : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        data_sdo_v <= '0';
      else
        if sdo_data_ready_i = '1' and sdo_data_valid = '1' then
          data_sdo_v   <= '1';
          sdo_data_reg <= sdo_data;
        elsif sdo_toshiftreg = '1' then
          data_sdo_v <= '0';
        end if;
      end if;
    end if;
  end process;

  -- ALIGNER: kısa kelimeyi MSB'ye yaslar. Kaynak: shiftreg.v 108-115
  -- Verilog: genişlikten büyük shift -> 0 (numeric_std shift_left da 0 verir)
  p_aligner : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        aligned_sdo_data <= (others => '0');
      else
        aligned_sdo_data <= std_logic_vector(shift_left(unsigned(sdo_data_reg),
                                                        to_integer(unsigned(left_aligned))));
      end if;
    end if;
  end process;

  -- SDO SHIFT REGISTER: MSB önce. Kaynak: shiftreg.v 117-131 (reset yok)
  p_sdo_shift : process(clk)
  begin
    if rising_edge(clk) then
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
  sdo_int        <= data_sdo_shift(DATA_WIDTH - 1);
  sdo_toshiftreg <= transfer_active and trigger_tx and first_bit and sdo_enabled;

  -- RX DELAY LINE: MISO örnekleme anı. Kaynak: shiftreg.v 133-141 (reset yok)
  -- Verilog {trigger_rx_d, trigger_rx} hedef genişliğe kırpılır -> en üst bit düşer.
  p_rx_delay : process(clk)
  begin
    if rising_edge(clk) then
      trigger_rx_d <= trigger_rx_d(SDI_D downto 0) & trigger_rx;
    end if;
  end process;
  trigger_rx_s <= trigger_rx_d(SDI_D + 1);

  -- SDI SHIFT REGISTER (her MISO hattı için). Kaynak: shiftreg.v 259-275
  -- cs_activate ile temizlenir; sdi_data latch'lenmez.
  g_sdi : for i in 0 to NUM_OF_SDI - 1 generate
    signal data_sdi_shift : std_logic_vector(DATA_WIDTH - 1 downto 0);
  begin
    p_sdi_shift : process(clk)
    begin
      if rising_edge(clk) then
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
  last_sdi_bit <= '1' when to_integer(sdi_counter) = to_integer(unsigned(word_length)) - 1 else '0';

  p_sdi_counter : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        sdi_counter <= (others => '0');
      elsif trigger_rx_s = '1' then
        if last_sdi_bit = '1' then
          sdi_counter <= (others => '0');
        else
          sdi_counter <= sdi_counter + 1;
        end if;
      end if;
    end if;
  end process;

  -- sdi_data_valid. Kaynak: shiftreg.v 288-295
  p_sdi_valid : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        sdi_data_valid_r <= '0';
      elsif sdi_enabled = '1' and last_sdi_bit = '1' and trigger_rx_s = '1' then
        sdi_data_valid_r <= '1';
      elsif sdi_data_ready = '1' then
        sdi_data_valid_r <= '0';
      end if;
    end if;
  end process;
  sdi_data_valid <= sdi_data_valid_r;

end architecture;
