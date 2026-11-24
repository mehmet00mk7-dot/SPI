-- ============================================================================
-- ad7923_ch_regs.vhd  -  AD7923 kanal başına sonuç register'ları
--
-- ad7923_drv'nin data_valid / data_ch / data / data_last akışını dinler:
--   * chN_data  : data_valid geldiğinde data_ch = N ise data yazılır; yeni değer
--                 gelene kadar sabit kalır. Reset değeri 0.
--   * chN_valid : chN_data register'ı güncellendiği clock'ta 1 clk pulse
--                 (yeni değer bu clock'ta chN_data'da görünür).
--   * scan_done : taramanın son ölçüm verisi (data_last = '1') register'a yazıldığı
--                 clock'ta 1 clk pulse; son kanalın chN_valid'i ile aynı clock.
--                 Bu clock'ta taramanın bütün kanal register'ları günceldir.
--                 Hatayla kesilen taramada driver data_last basmadığı için gelmez.
-- Gecikme: data_valid -> chN_valid / scan_done = 1 clk.
--
-- RESET STRATEJİSİ
--   * rst_n kaynağı: projedeki reset synchronizer (async assert, sync deassert,
--     PLL lock'a bağlı). Bu blok, ad7923_drv ve core (spi_exec) aynı rst_n'den
--     beslenir; core'un resetn'i ad7923_top'ta rst_n ile async assert edilen bir
--     flop'tan (p_core_resetn) gelir.
--   * p_regs async reset: process(clk, rst_n), if rst_n = '0' ... elsif
--     rising_edge(clk). Reset değerleri eski sync sürümle aynı (hepsi 0); reset'siz
--     register yok. rst_n düşer düşmez chN_data = 0, chN_valid = scan_done = '0'.
--   * Async reset olarak yalnız rst_n kullanılır. Driver'ın core_rst'u (senkron
--     soft reset) bu bloğu etkilemez.
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ad7923_ch_regs is
  port (
    clk        : in  std_logic;
    rst_n      : in  std_logic;
    data_valid : in  std_logic;
    data_ch    : in  std_logic_vector(1 downto 0);
    data       : in  std_logic_vector(11 downto 0);
    data_last  : in  std_logic;
    ch0_data   : out std_logic_vector(11 downto 0);
    ch1_data   : out std_logic_vector(11 downto 0);
    ch2_data   : out std_logic_vector(11 downto 0);
    ch3_data   : out std_logic_vector(11 downto 0);
    ch0_valid  : out std_logic;
    ch1_valid  : out std_logic;
    ch2_valid  : out std_logic;
    ch3_valid  : out std_logic;
    scan_done  : out std_logic
  );
end entity ad7923_ch_regs;

architecture rtl of ad7923_ch_regs is

  constant C_NUM_CH : integer := 4;

  type ch_data_t is array (0 to C_NUM_CH - 1) of std_logic_vector(11 downto 0);
  signal ch_data_r   : ch_data_t;
  signal ch_valid_r  : std_logic_vector(C_NUM_CH - 1 downto 0);
  signal scan_done_r : std_logic;

begin

  p_regs : process (clk, rst_n)
  begin
    if rst_n = '0' then
      ch_data_r   <= (others => (others => '0'));
      ch_valid_r  <= (others => '0');
      scan_done_r <= '0';
    elsif rising_edge(clk) then
      ch_valid_r  <= (others => '0');
      scan_done_r <= '0';
      if data_valid = '1' then
        ch_data_r(to_integer(unsigned(data_ch)))  <= data;
        ch_valid_r(to_integer(unsigned(data_ch))) <= '1';
        scan_done_r                               <= data_last;
      end if;
    end if;
  end process p_regs;

  ch0_data  <= ch_data_r(0);
  ch1_data  <= ch_data_r(1);
  ch2_data  <= ch_data_r(2);
  ch3_data  <= ch_data_r(3);
  ch0_valid <= ch_valid_r(0);
  ch1_valid <= ch_valid_r(1);
  ch2_valid <= ch_valid_r(2);
  ch3_valid <= ch_valid_r(3);
  scan_done <= scan_done_r;

end architecture rtl;
