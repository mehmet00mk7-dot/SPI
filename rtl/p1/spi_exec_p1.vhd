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
-- spi_exec_p1 : BİREBİR (cycle-exact) çeviri, SYNC reset.
--   Amaç: orijinal Verilog ile her clock'ta aynı davranış. Hatalar dahil kopyalanır
--   (ör. SLEEP n = 255 hang).
--   Desteklenen: ECHO_SCLK = 0. VHDL büyük/küçük harf ayırmadığı için ECHO_SCLK
--   generic'i echo_sclk port'u ile çakışır; generic yoktur, davranış ECHO_SCLK = 0'dır.
--   echo_* register'ları (ECHO_SCLK = 1 içindi) çıkışları etkilemediği için çevrilmedi.
--   NUM_OF_CS: 1..8.
-- ***************************************************************************

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_exec_p1 is
  generic (
    NUM_OF_CS       : integer := 1;
    DEFAULT_SPI_CFG : integer := 0;
    DEFAULT_CLK_DIV : integer := 0;
    DATA_WIDTH      : integer := 8;          -- 8/16/24/32
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
end entity;

architecture rtl of spi_exec_p1 is

  -- KOMUT KODLARI (cmd[14:12]). Kaynak: execution.v 77-88
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

  function bcw(dw : integer) return integer is
  begin
    if dw > 16 then return 5; elsif dw > 8 then return 4; else return 3; end if;
  end function;
  constant BIT_COUNTER_WIDTH : integer := bcw(DATA_WIDTH);

  constant CFG : unsigned(31 downto 0) := to_unsigned(DEFAULT_SPI_CFG, 32);

  -- İÇ SİNYALLER (initial value'lar Verilog'daki gibi). Kaynak: execution.v 96-174
  signal sclk_int                : std_logic := '0';
  signal sdo_t_int               : std_logic := '0';
  signal idle                    : std_logic;
  signal clk_div_counter         : unsigned(7 downto 0) := (others => '0');
  signal clk_div_last            : std_logic;
  signal sleep_counter           : unsigned(7 downto 0);
  signal bit_counter             : unsigned(BIT_COUNTER_WIDTH - 1 downto 0);
  signal transfer_counter        : unsigned(7 downto 0);
  signal ntx_rx                  : std_logic;
  signal sleep_counter_increment : std_logic;
  signal trigger                 : std_logic := '0';
  signal wait_for_io             : std_logic := '0';
  signal transfer_active         : std_logic := '0';
  signal transfer_done           : std_logic := '0';
  signal last_transfer           : std_logic;
  signal word_length             : unsigned(7 downto 0) := to_unsigned(DATA_WIDTH, 8);
  signal last_bit_count          : unsigned(7 downto 0) := to_unsigned(DATA_WIDTH - 1, 8);
  signal left_aligned            : unsigned(7 downto 0) := (others => '0');
  signal first_bit               : std_logic;
  signal cmd_d1                  : std_logic_vector(15 downto 0);
  signal cpha                    : std_logic := CFG(0);
  signal cpol                    : std_logic := CFG(1);
  signal clk_div                 : unsigned(7 downto 0) := to_unsigned(DEFAULT_CLK_DIV, 8);
  signal sdo_idle_state          : std_logic := SDO_DEFAULT(0);
  signal cs_inv_mask_reg         : std_logic_vector(NUM_OF_CS - 1 downto 0) := (others => '0');
  signal sdo_enabled             : std_logic := '0';
  signal sdi_enabled             : std_logic := '0';
  signal pending_sdi_data_valid  : std_logic := '0';
  signal sdo_enabled_io          : std_logic;
  signal sdo_int_s               : std_logic;
  signal last_bit                : std_logic;
  signal end_of_word             : std_logic;
  signal inst, inst_d1           : std_logic_vector(2 downto 0);
  signal exec_cmd                : std_logic;
  signal exec_transfer_cmd       : std_logic;
  signal exec_cs_inv_cmd         : std_logic;
  signal exec_write_cmd          : std_logic;
  signal exec_chipselect_cmd     : std_logic;
  signal exec_misc_cmd           : std_logic;
  signal exec_sync_cmd           : std_logic;
  signal trigger_tx, trigger_rx  : std_logic;
  signal cs_sleep_counter        : std_logic_vector(1 downto 0);
  signal sleep_counter_compare   : std_logic;
  signal cs_sleep_counter_compare : std_logic;
  signal cs_sleep_early_exit     : std_logic;
  signal cs_sleep_repeat         : std_logic;
  signal cs_activate             : std_logic;
  signal io_ready1, io_ready2    : std_logic;
  signal sdo_io_ready            : std_logic;
  signal cs_gen                  : std_logic;
  signal cmd_ready_i             : std_logic;
  signal sync_valid_r            : std_logic;
  signal cs_r                    : std_logic_vector(NUM_OF_CS - 1 downto 0);
  signal three_wire_r            : std_logic;
  signal sdi_data_valid_i        : std_logic;

begin

  assert NUM_OF_CS >= 1 and NUM_OF_CS <= 8
    report "spi_exec_p1: NUM_OF_CS 1..8 olmali" severity failure;

  -- DATA PATH. Kaynak: execution.v 176-207
  u_shiftreg : entity work.spi_exec_p1_shiftreg
    generic map (
      DEFAULT_SPI_CFG => DEFAULT_SPI_CFG,
      DATA_WIDTH      => DATA_WIDTH,
      NUM_OF_SDI      => NUM_OF_SDI,
      SDI_DELAY       => SDI_DELAY,
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
  first_bit <= '1' when (bit_counter = 0) or
                        (to_integer(bit_counter) = to_integer(word_length)) else '0';

  -- KOMUT ÇÖZÜCÜ. Kaynak: execution.v 148-157
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
  cs_gen <= '1' when inst_d1 = CMD_CHIPSELECT
                 and (cs_sleep_counter_compare = '1' or cs_sleep_early_exit = '1')
                 and cs_sleep_repeat = '0'
                 and idle = '0' else '0';
  cmd_ready_i <= idle;
  cmd_ready   <= cmd_ready_i;

  -- sdo_enabled / sdi_enabled. Kaynak: execution.v 215-222
  p_enables : process(clk)
  begin
    if rising_edge(clk) then
      if exec_transfer_cmd = '1' then
        sdo_enabled <= cmd(8);
        sdi_enabled <= cmd(9);
      end if;
    end if;
  end process;
  sdo_enabled_io <= cmd(8) when exec_transfer_cmd = '1' else sdo_enabled;

  -- cmd_d1: yürütülen komut. Kaynak: execution.v 224-227
  p_cmd_d1 : process(clk)
  begin
    if rising_edge(clk) then
      if cmd_ready_i = '1' and cmd_valid = '1' then
        cmd_d1 <= cmd;
      end if;
    end if;
  end process;

  -- last_bit_count (8 bite kırpılır). Kaynak: execution.v 229-235
  p_last_bit_count : process(clk)
  begin
    if rising_edge(clk) then
      last_bit_count <= word_length - 1;
    end if;
  end process;

  -- CONFIG REGISTER'LARI. Kaynak: execution.v 236-254
  p_config : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        cpha           <= CFG(0);
        cpol           <= CFG(1);
        three_wire_r   <= CFG(2);
        sdo_idle_state <= SDO_DEFAULT(0);
        clk_div        <= to_unsigned(DEFAULT_CLK_DIV, 8);
        word_length    <= to_unsigned(DATA_WIDTH, 8);
        left_aligned   <= (others => '0');
      elsif exec_write_cmd = '1' then
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
  p_clk_div_last : process(clk)
  begin
    if rising_edge(clk) then
      if (clk_div_last = '0' and idle = '0' and wait_for_io = '0' and clk_div_counter = 1)
         or clk_div = 0 then
        clk_div_last <= '1';
      else
        clk_div_last <= '0';
      end if;
    end if;
  end process;

  -- CLOCK DIVIDER (2/2): counter ve trigger. Kaynak: execution.v 270-278
  p_clk_div : process(clk)
  begin
    if rising_edge(clk) then
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
  -- (ORİJİNAL HATA, bilerek kopyalandı).
  cs_sleep_counter         <= std_logic_vector(sleep_counter(1 downto 0));
  sleep_counter_compare    <= '1' when to_integer(sleep_counter) =
                                       to_integer(unsigned(cmd_d1(7 downto 0))) + 1 else '0';
  cs_sleep_counter_compare <= '1' when cs_sleep_counter = cmd_d1(9 downto 8) else '0';
  cs_sleep_early_exit      <= '1' when cmd_d1(9 downto 8) = "00" else '0';

  -- CS GENERATOR (2/3): cs_sleep_repeat. Kaynak: execution.v 287-297
  p_cs_sleep_repeat : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        cs_sleep_repeat <= '0';
      elsif idle = '1' then
        cs_sleep_repeat <= '0';
      elsif cs_sleep_counter_compare = '1' and inst_d1 = CMD_CHIPSELECT then
        cs_sleep_repeat <= not cs_sleep_repeat;
      end if;
    end if;
  end process;

  -- COUNTER'LAR (reset yok, idle ile temizlenir). Kaynak: execution.v 299-326
  p_counters : process(clk)
  begin
    if rising_edge(clk) then
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
  p_pending : process(clk)
  begin
    if rising_edge(clk) then
      if sdi_enabled = '1' and last_bit = '1' and trigger_rx = '1' then
        pending_sdi_data_valid <= '1';
      elsif sdi_data_ready = '1' then
        pending_sdi_data_valid <= '0';
      end if;
    end if;
  end process;

  -- IDLE STATE MACHINE. Kaynak: execution.v 336-367
  p_idle : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        idle <= '1';
      else
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
    end if;
  end process;

  -- CS_INV maskesi. Kaynak: execution.v 369-377
  p_cs_inv : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        cs_inv_mask_reg <= (others => '0');
      elsif exec_cs_inv_cmd = '1' then
        cs_inv_mask_reg <= cmd(NUM_OF_CS - 1 downto 0);
      end if;
    end if;
  end process;

  -- CS GENERATOR (3/3): CS çıkış register'ı. Kaynak: execution.v 379-385
  p_cs : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        cs_r <= (others => '1');
      elsif cs_gen = '1' then
        cs_r <= cmd_d1(NUM_OF_CS - 1 downto 0) xor cs_inv_mask_reg;
      end if;
    end if;
  end process;
  cs <= cs_r;

  -- SYNC. Kaynak: execution.v 387-399
  p_sync : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        sync_valid_r <= '0';
      elsif exec_sync_cmd = '1' then
        sync_valid_r <= '1';
      elsif sync_ready = '1' then
        sync_valid_r <= '0';
      end if;
    end if;
  end process;
  sync_valid <= sync_valid_r;
  sync       <= cmd_d1(7 downto 0);

  -- TRANSFER AKIŞ KONTROLÜ: io_ready. Kaynak: execution.v 401-408
  io_ready1 <= (not pending_sdi_data_valid or sdi_data_ready) and
               (not sdo_enabled_io or sdo_io_ready);
  io_ready2 <= (not sdi_enabled or sdi_data_ready) and
               (not sdo_enabled_io or last_transfer or sdo_io_ready);

  -- last_transfer. Kaynak: execution.v 410-419
  p_last_transfer : process(clk)
  begin
    if rising_edge(clk) then
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
  p_transfer : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        transfer_active <= '0';
        wait_for_io     <= '0';
      else
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
    end if;
  end process;

  -- transfer_done (ECHO_SCLK = 0 dalı). Kaynak: execution.v 472-482
  p_transfer_done : process(clk)
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        transfer_done <= '0';
      else
        transfer_done <= (wait_for_io and io_ready1 and last_transfer) or
                         (not wait_for_io and transfer_active and end_of_word and last_transfer);
      end if;
    end if;
  end process;

  -- sdo_t_int. Kaynak: execution.v 484-491
  p_sdo_t : process(clk)
  begin
    if rising_edge(clk) then
      if transfer_active = '1' or wait_for_io = '1' then
        sdo_t_int <= not sdo_enabled;
      else
        sdo_t_int <= '1';
      end if;
    end if;
  end process;

  -- cs_activate (reset'te 1: SDI shift register'ı temizler). Kaynak: execution.v 493-499
  p_cs_activate : process(clk)
    variable all_ones : std_logic;
  begin
    if rising_edge(clk) then
      if resetn = '0' then
        cs_activate <= '1';
      else
        all_ones := '1';
        for k in 0 to NUM_OF_CS - 1 loop
          all_ones := all_ones and cmd_d1(k);
        end loop;
        cs_activate <= (not all_ones) and cs_gen;
      end if;
    end if;
  end process;

  -- last_bit / end_of_word. Kaynak: execution.v 501-505 (Verilog width: 8 bit)
  last_bit    <= '1' when to_integer(bit_counter) = to_integer(last_bit_count) else '0';
  end_of_word <= last_bit and ntx_rx and clk_div_last;

  -- SCLK ÜRETİMİ. Kaynak: execution.v 507-513
  p_sclk_int : process(clk)
  begin
    if rising_edge(clk) then
      if transfer_active = '1' then
        sclk_int <= cpol xor cpha xor ntx_rx;
      else
        sclk_int <= cpol;
      end if;
    end if;
  end process;

  -- Pin çıkış register'ları (reset yok). Kaynak: execution.v 515-520
  p_out : process(clk)
  begin
    if rising_edge(clk) then
      sclk  <= sclk_int;
      sdo   <= sdo_int_s;
      sdo_t <= sdo_t_int;
    end if;
  end process;

end architecture;
