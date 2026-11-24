-- ============================================================================
-- ad7923_drv.vhd  -  AD7923 (4 kanal, 12 bit, 200 kSPS) entegre driver'ı
--
-- Hedef: Microchip PolarFire / Libero SoC, 100 MHz tek clock, asenkron aktif-düşük
-- reset (rst_n). SPI tarafı ADI spi_engine_execution (2026.1.0) komut arayüzüdür;
-- çekirdek olarak VHDL çevirisi spi_exec kullanılır (bkz. ad7923_top.vhd).
--
-- RESET STRATEJİSİ
--   * rst_n kaynağı: projedeki reset synchronizer. Async assert, sync deassert
--     (clk'a göre), PLL lock'a bağlı. Deassert clk ile senkron geldiği için
--     reset kalkarken recovery/removal sorunu yoktur.
--   * Bütün clocked process'ler kalıbı:
--       process(clk, rst_n) begin
--         if rst_n = '0' then <reset değerleri>
--         elsif rising_edge(clk) then ...
--     Reset değerleri, eski sync reset sürümündekiyle birebir aynıdır. Process
--     içinde atanan her register reset listesindedir; reset'siz register yoktur.
--   * Async reset olarak YALNIZCA rst_n port'u kullanılır; türetilmiş async reset
--     yoktur. İç "soft reset"ler (fifo_clr, per_rst, frm_launch ile cycle timer
--     clear'ı, ST_PWR_WAIT dışında pwr_cnt clear'ı) senkron mantık olarak kalır.
--   * Driver ve core (spi_exec) aynı rst_n'den beslenir: ad7923_top'ta core'un
--     resetn'i, rst_n ile async assert edilen bir flop'tan (p_core_resetn) gelir.
--   * core_rst (SYNC timeout sonrası core reset pulse'ı) bu driver'da senkron bir
--     register'dır (core_rst_r); core'a ad7923_top'taki p_core_resetn flop'u
--     üzerinden, bir clock gecikmeli ve senkron olarak ulaşır.
--   * rst_n düşer düşmez (clock beklemeden) busy, err, data_valid, data_last ve
--     core_rst '0', data / data_ch 0 olur; reset kalkınca driver ST_IDLE'da
--     start bekler, kendiliğinden başlamaz (pwr_done = '0': power-up yeniden).
--
-- İç bloklar:
--   * Control FSM      : power-up, tarama, select frame, stop, hata yönetimi
--   * Timer'lar        : cycle (CS falling edge'ler arası 5 us), power-up (1 us),
--                        SYNC timeout (10 us), period (us tick + counter)
--   * Channel selector : mask -> first / next / last (combinational)
--   * Command packer   : 7 kelimelik paket (CONFIG x3, CS, TRANSFER, CS, SYNC),
--                        req/gnt kilidi, sdo kelimesi, SYNC id kontrolü
--   * Expectation FIFO : her frame için {discard, beklenen kanal}
--   * RX checker       : [15:14] = "00" ve [13:12] = beklenen kanal kontrolü
--   * Output register  : data_valid (1 clk pulse), data_ch, data, data_last
--                        (data_last: taramanın son ölçüm verisi; hatayla kesilen
--                        taramada son ölçüm frame'i atılmadığı için gelmez)
--
-- Hatalar:
--   * Veri hatası (format / adres): örnek basılmaz, err sticky, chip_sel_vld='0',
--     tarama kesilir -> ST_SCAN_END. Art arda ERR_LIMIT hatalı tarama -> driver
--     durur (pwr_done='0'). Hatasız tarama hata counter'ını sıfırlar.
--   * Yapısal hata (SYNC timeout, SYNC id, FIFO underflow): driver durur,
--     pwr_done='0'; timeout'ta ayrıca core_rst (CORE_RST_CLKS clk pulse).
--
-- Kodlama: VHDL-2008 ile derlenir, muhafazakâr yazım (numeric_std, process(all)
-- yok, port tipleri std_logic / std_logic_vector, iç aritmetik unsigned / integer).
-- ============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ad7923_drv is
  generic (
    CLKS_PER_US   : integer := 100;   -- 100 MHz -> 1 us = 100 clk
    CYCLE_CLKS    : integer := 500;   -- CS falling edge'ler arası min (5 us, 200 kSPS)
    PWRUP_CLKS    : integer := 100;   -- dummy frame sonrası power-up bekleme (1 us)
    SYNC_TO_CLKS  : integer := 1000;  -- paket launch -> SYNC timeout (10 us)
    CORE_RST_CLKS : integer := 4;     -- SYNC timeout sonrası core_rst pulse genişliği
    ERR_LIMIT     : integer := 4;     -- art arda hatalı tarama limiti
    CLK_DIV       : integer := 2;     -- SCLK = 100 MHz / (2*(CLK_DIV+1)) = 16,7 MHz
    SPI_MODE      : integer := 2;     -- Mode 2: CPOL=1, CPHA=0
    WORD_LEN      : integer := 16;    -- SPI kelime uzunluğu (bit)
    CS_T          : integer := 1;     -- CS komutundaki ek bekleme (SCLK periyodu)
    CS_IDX        : integer := 0      -- kullanılan chip select numarası
  );
  port (
    clk         : in  std_logic;
    rst_n       : in  std_logic;
    -- kontrol (sistem tarafı)
    start       : in  std_logic;
    stop        : in  std_logic;
    continuous  : in  std_logic;
    ch_mask     : in  std_logic_vector(3 downto 0);
    period_us   : in  std_logic_vector(15 downto 0);
    range_sel   : in  std_logic;
    coding_sel  : in  std_logic;
    -- sonuç
    data_valid  : out std_logic;
    data_ch     : out std_logic_vector(1 downto 0);
    data        : out std_logic_vector(11 downto 0);
    data_last   : out std_logic;   -- data_valid ile aynı clock: taramanın son ölçüm verisi
    busy        : out std_logic;
    err         : out std_logic;
    -- SPI master tarafı
    req         : out std_logic;
    gnt         : in  std_logic;
    cmd         : out std_logic_vector(15 downto 0);
    cmd_valid   : out std_logic;
    cmd_ready   : in  std_logic;
    sdo_data    : out std_logic_vector(15 downto 0);
    sdo_valid   : out std_logic;
    sdo_ready   : in  std_logic;
    sdi_data    : in  std_logic_vector(15 downto 0);
    sdi_valid   : in  std_logic;
    sync        : in  std_logic_vector(7 downto 0);
    sync_valid  : in  std_logic;
    core_rst    : out std_logic
  );
end entity ad7923_drv;

architecture rtl of ad7923_drv is

  -- --------------------------------------------------------------------------
  -- ADI spi_engine komut kodlaması: cmd = op(15:12) & "00" & arg(9:8) & val(7:0)
  -- --------------------------------------------------------------------------
  constant C_OP_TRANSFER : std_logic_vector(3 downto 0) := "0000";
  constant C_OP_CS       : std_logic_vector(3 downto 0) := "0001";
  constant C_OP_CONFIG   : std_logic_vector(3 downto 0) := "0010";
  constant C_OP_MISC     : std_logic_vector(3 downto 0) := "0011";

  constant C_CFG_CLK_DIV : std_logic_vector(1 downto 0) := "00";  -- CONFIG register: clk_div
  constant C_CFG_MODE    : std_logic_vector(1 downto 0) := "01";  -- CONFIG register: CPOL/CPHA
  constant C_CFG_WORDLEN : std_logic_vector(1 downto 0) := "10";  -- CONFIG register: word length
  constant C_MISC_SYNC   : std_logic_vector(1 downto 0) := "00";  -- MISC: SYNC (SLEEP kullanılmaz)
  constant C_XFER_RW     : std_logic_vector(1 downto 0) := "11";  -- TRANSFER: read=1, write=1
  constant C_XFER_ONE    : std_logic_vector(7 downto 0) := x"00"; -- TRANSFER: n-1 = 0 (1 kelime)
  constant C_CS_ALL_OFF  : std_logic_vector(7 downto 0) := x"FF";
  constant C_ZERO8       : std_logic_vector(7 downto 0) := x"00";

  function mk_cmd(op : std_logic_vector(3 downto 0); arg : std_logic_vector(1 downto 0);
                  val : std_logic_vector(7 downto 0)) return std_logic_vector is
  begin
    return op & "00" & arg & val;
  end function;

  function cs_on_mask(idx : integer) return std_logic_vector is
    variable m : std_logic_vector(7 downto 0) := C_CS_ALL_OFF;
  begin
    m(idx) := '0';
    return m;
  end function;

  constant C_CMD_CLK_DIV : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CONFIG, C_CFG_CLK_DIV, std_logic_vector(to_unsigned(CLK_DIV, 8)));   -- 0x2002
  constant C_CMD_MODE    : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CONFIG, C_CFG_MODE, std_logic_vector(to_unsigned(SPI_MODE, 8)));     -- 0x2102
  constant C_CMD_WORDLEN : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CONFIG, C_CFG_WORDLEN, std_logic_vector(to_unsigned(WORD_LEN, 8)));  -- 0x2210
  constant C_CMD_CS_ON   : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CS, std_logic_vector(to_unsigned(CS_T, 2)), cs_on_mask(CS_IDX));     -- 0x11FE
  constant C_CMD_XFER    : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_TRANSFER, C_XFER_RW, C_XFER_ONE);                                    -- 0x0300
  constant C_CMD_CS_OFF  : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_CS, std_logic_vector(to_unsigned(CS_T, 2)), C_CS_ALL_OFF);           -- 0x11FF
  constant C_CMD_SYNC0   : std_logic_vector(15 downto 0) :=
    mk_cmd(C_OP_MISC, C_MISC_SYNC, C_ZERO8);                                         -- 0x30id

  -- paket indeksleri
  constant C_PK_CLK_DIV : integer := 0;   -- ilk komut: handshake'i = paket launch
  constant C_PK_MODE    : integer := 1;
  constant C_PK_WORDLEN : integer := 2;
  constant C_PK_CS_ON   : integer := 3;
  constant C_PK_XFER    : integer := 4;
  constant C_PK_CS_OFF  : integer := 5;
  constant C_PK_SYNC    : integer := 6;   -- son komut
  constant C_PK_LAST    : integer := C_PK_SYNC;

  -- --------------------------------------------------------------------------
  -- AD7923 control register (DIN ilk 12 bit) ve DOUT alanları (datasheet Rev. D)
  -- --------------------------------------------------------------------------
  constant C_AD_WRITE_BIT  : integer := 15;
  constant C_AD_SEQ_BIT    : integer := 14;
  constant C_AD_ADD_HI     : integer := 11;
  constant C_AD_ADD_LO     : integer := 10;
  constant C_AD_PM_HI      : integer := 9;
  constant C_AD_PM_LO      : integer := 8;
  constant C_AD_SHADOW_BIT : integer := 7;
  constant C_AD_RANGE_BIT  : integer := 5;
  constant C_AD_CODING_BIT : integer := 4;
  constant C_AD_PM_NORMAL  : std_logic_vector(1 downto 0) := "11";
  constant C_AD_DUMMY_WORD : std_logic_vector(15 downto 0) := x"FFFF";  -- power-up: DIN = 1

  constant C_DOUT_LEAD_HI  : integer := 15;
  constant C_DOUT_LEAD_LO  : integer := 14;
  constant C_DOUT_ADDR_HI  : integer := 13;
  constant C_DOUT_ADDR_LO  : integer := 12;
  constant C_DOUT_DATA_HI  : integer := 11;
  constant C_DOUT_LEAD_OK  : std_logic_vector(1 downto 0) := "00";

  constant C_MASK_NONE     : std_logic_vector(3 downto 0) := "0000";
  constant C_NUM_CH        : integer := 4;

  -- WRITE=1, SEQ=0, ADD=ch, PM=11 (normal), SHADOW=0, RANGE, CODING
  function ctrl_word(ch : unsigned(1 downto 0); rng : std_logic; cod : std_logic)
    return std_logic_vector is
    variable w : std_logic_vector(15 downto 0) := (others => '0');
  begin
    w(C_AD_WRITE_BIT)                := '1';
    w(C_AD_SEQ_BIT)                  := '0';
    w(C_AD_ADD_HI downto C_AD_ADD_LO) := std_logic_vector(ch);
    w(C_AD_PM_HI downto C_AD_PM_LO)   := C_AD_PM_NORMAL;
    w(C_AD_SHADOW_BIT)               := '0';
    w(C_AD_RANGE_BIT)                := rng;
    w(C_AD_CODING_BIT)               := cod;
    return w;
  end function;

  -- Channel selector fonksiyonları
  function first_ch(m : std_logic_vector(3 downto 0)) return unsigned is
    variable r : unsigned(1 downto 0) := (others => '0');
  begin
    for i in C_NUM_CH - 1 downto 0 loop
      if m(i) = '1' then
        r := to_unsigned(i, 2);
      end if;
    end loop;
    return r;
  end function;

  -- dönüş: bit 2 = '1' -> maskede c'den sonra kanal var, bit 1:0 = o kanal
  function next_ch(m : std_logic_vector(3 downto 0); c : unsigned(1 downto 0)) return unsigned is
    variable r : unsigned(2 downto 0) := (others => '0');
  begin
    for i in C_NUM_CH - 1 downto 0 loop
      if i > to_integer(c) and m(i) = '1' then
        r := '1' & to_unsigned(i, 2);
      end if;
    end loop;
    return r;
  end function;

  -- Period timer: SCAN_START -> PERIOD_WAIT -> SCAN_START yolundaki 2 clk FSM
  -- gecikmesi, prescaler'ın başlangıç değeriyle telafi edilir (period tam
  -- period_us * CLKS_PER_US clk olur).
  constant C_PER_FSM_LAT : integer := 2;

  -- --------------------------------------------------------------------------
  -- Control FSM
  -- --------------------------------------------------------------------------
  type st_t is (ST_IDLE, ST_PWR_DUMMY, ST_PWR_WAIT, ST_SCAN_START, ST_SELECT,
                ST_MEAS, ST_SCAN_END, ST_PERIOD_WAIT, ST_CORE_RST);
  signal state        : st_t;

  signal mask_cur     : std_logic_vector(3 downto 0);
  signal period_cur   : unsigned(15 downto 0);
  signal cur_ch       : unsigned(1 downto 0);
  signal chip_sel     : unsigned(1 downto 0);
  signal chip_sel_vld : std_logic;
  signal pwr_done     : std_logic;
  signal stop_pend    : std_logic;
  signal err_r        : std_logic;
  signal err_scan     : std_logic;
  signal err_cnt      : integer range 0 to ERR_LIMIT - 1;
  signal rst_cnt      : integer range 0 to CORE_RST_CLKS - 1;
  signal core_rst_r   : std_logic;

  -- FSM -> packer frame isteği
  signal frm_go       : std_logic;
  signal frm_pend     : std_logic;
  signal frm_dummy    : std_logic;
  signal frm_disc     : std_logic;
  signal frm_wch      : unsigned(1 downto 0);   -- bu frame'de yazılan kanal
  signal frm_ech      : unsigned(1 downto 0);   -- bu frame'de çevrilen (beklenen) kanal
  signal frm_last     : std_logic;              -- taramanın son ölçüm frame'i
  signal frm_derr     : std_logic;              -- bu frame'de veri hatası görüldü
  signal frm_cancel   : std_logic;

  -- channel selector
  signal sel_first    : unsigned(1 downto 0);
  signal sel_next_r   : unsigned(2 downto 0);
  signal sel_next     : unsigned(1 downto 0);
  signal sel_last     : std_logic;

  -- timer'lar
  signal cyc_cnt      : integer range 0 to CYCLE_CLKS - 1;
  signal cyc_ok       : std_logic;
  signal pwr_cnt      : integer range 0 to PWRUP_CLKS - 1;
  signal pwr_ok       : std_logic;
  signal per_pre      : integer range 0 to CLKS_PER_US - 1;
  signal per_us       : unsigned(15 downto 0);
  signal per_rst      : std_logic;
  signal per_ok       : std_logic;
  signal to_cnt       : integer range 0 to SYNC_TO_CLKS - 1;
  signal to_hit       : std_logic;

  -- command packer
  type pk_st_t is (PK_IDLE, PK_CMD, PK_WAIT);
  signal pk_st        : pk_st_t;
  signal pk_idx       : integer range 0 to C_PK_LAST;
  signal pk_dummy     : std_logic;
  signal pk_wch       : unsigned(1 downto 0);
  signal pk_launched  : std_logic;
  signal sync_id      : unsigned(7 downto 0);
  signal cmd_i        : std_logic_vector(15 downto 0);
  signal cmd_valid_i  : std_logic;
  signal cmd_hs       : std_logic;
  signal frm_launch   : std_logic;
  signal frm_done     : std_logic;
  signal sync_err     : std_logic;
  signal sdo_r        : std_logic_vector(15 downto 0);
  signal sdo_valid_r  : std_logic;

  -- expectation FIFO
  constant C_FIFO_DEPTH : integer := 2;
  type fifo_t is array (0 to C_FIFO_DEPTH - 1) of std_logic_vector(3 downto 0);  -- {last, disc, ch}
  signal fifo_mem     : fifo_t;
  signal fifo_wr      : integer range 0 to C_FIFO_DEPTH - 1;
  signal fifo_rd      : integer range 0 to C_FIFO_DEPTH - 1;
  signal fifo_cnt     : integer range 0 to C_FIFO_DEPTH;
  signal fifo_clr     : std_logic;
  signal fifo_unf     : std_logic;
  signal exp_disc     : std_logic;
  signal exp_ch       : unsigned(1 downto 0);
  signal exp_last     : std_logic;

  -- RX checker / output register
  signal rx_take      : std_logic;
  signal rx_lead_ok   : std_logic;
  signal rx_addr_ok   : std_logic;
  signal rx_err_p     : std_logic;   -- registered: format veya adres hatası pulse
  signal data_valid_r : std_logic;
  signal data_ch_r    : std_logic_vector(1 downto 0);
  signal data_r       : std_logic_vector(11 downto 0);
  signal data_last_r  : std_logic;

  signal struct_err   : std_logic;
  signal stop_now     : std_logic;

begin

  -- ==========================================================================
  -- Channel selector (combinational)
  -- ==========================================================================
  sel_first  <= first_ch(mask_cur);
  sel_next_r <= next_ch(mask_cur, cur_ch);
  sel_next   <= sel_next_r(1 downto 0);
  sel_last   <= not sel_next_r(2);

  stop_now   <= stop or stop_pend;
  struct_err <= to_hit or sync_err or fifo_unf;

  -- Paket henüz launch olmadıysa stop onu iptal eder
  frm_cancel <= '1' when frm_pend = '1' and stop_pend = '1' and
                         pk_st = PK_CMD and pk_idx = C_PK_CLK_DIV
                else '0';

  -- ==========================================================================
  -- Control FSM
  -- ==========================================================================
  -- Async reset: frm_go eski sürümde reset kontrolünden önce '0' atanıyordu
  -- (reset'te de '0'); burada açıkça reset listesinde.
  p_ctrl : process (clk, rst_n)
  begin
    if rst_n = '0' then
      frm_go       <= '0';
      state        <= ST_IDLE;
      mask_cur     <= (others => '0');
      period_cur   <= (others => '0');
      cur_ch       <= (others => '0');
      chip_sel     <= (others => '0');
      chip_sel_vld <= '0';
      pwr_done     <= '0';
      stop_pend    <= '0';
      err_r        <= '0';
      err_scan     <= '0';
      err_cnt      <= 0;
      rst_cnt      <= 0;
      core_rst_r   <= '0';
      frm_pend     <= '0';
      frm_dummy    <= '0';
      frm_disc     <= '0';
      frm_wch      <= (others => '0');
      frm_ech      <= (others => '0');
      frm_last     <= '0';
      frm_derr     <= '0';
    elsif rising_edge(clk) then
      frm_go <= '0';
      -- veri hatası: frame içinde latch'lenir, err hemen kalkar
      if rx_err_p = '1' then
        frm_derr <= '1';
        err_r    <= '1';
      end if;
      if stop = '1' then
        stop_pend <= '1';
      end if;

      if struct_err = '1' and state /= ST_CORE_RST then
        -- yapısal hata: driver durur, sonraki start power-up'ı baştan yapar
        err_r        <= '1';
        pwr_done     <= '0';
        chip_sel_vld <= '0';
        frm_pend     <= '0';
        if to_hit = '1' then
          core_rst_r <= '1';
          rst_cnt    <= 0;
          state      <= ST_CORE_RST;
        else
          state      <= ST_IDLE;
        end if;
      else
        case state is

          when ST_IDLE =>
            stop_pend <= '0';
            frm_pend  <= '0';
            if start = '1' and stop = '0' and ch_mask /= C_MASK_NONE then
              mask_cur   <= ch_mask;
              period_cur <= unsigned(period_us);
              err_r      <= '0';
              err_cnt    <= 0;
              err_scan   <= '0';
              if pwr_done = '1' then
                state <= ST_SCAN_START;
              else
                state <= ST_PWR_DUMMY;
              end if;
            end if;

          when ST_PWR_DUMMY =>
            if frm_pend = '0' then
              if stop_now = '1' then
                state <= ST_IDLE;
              else
                frm_go    <= '1';
                frm_pend  <= '1';
                frm_dummy <= '1';
                frm_disc  <= '1';
                frm_wch   <= (others => '0');
                frm_ech   <= (others => '0');
                frm_last  <= '0';
                frm_derr  <= '0';
              end if;
            elsif frm_cancel = '1' then
              frm_pend <= '0';
              state    <= ST_IDLE;
            elsif frm_done = '1' then
              frm_pend     <= '0';
              pwr_done     <= '1';
              chip_sel_vld <= '0';
              state        <= ST_PWR_WAIT;
            end if;

          when ST_PWR_WAIT =>
            if stop_now = '1' then
              state <= ST_IDLE;
            elsif pwr_ok = '1' then
              state <= ST_SCAN_START;
            end if;

          when ST_SCAN_START =>
            -- tarama tetiği (period referansı burada başlar, per_rst)
            if stop_now = '1' then
              state <= ST_IDLE;
            else
              cur_ch <= sel_first;
              if chip_sel_vld = '0' or chip_sel /= sel_first then
                state <= ST_SELECT;
              else
                state <= ST_MEAS;
              end if;
            end if;

          when ST_SELECT =>
            -- kanal seçme frame'i: first kanalı yazar, sonucu atılır
            if frm_pend = '0' then
              if stop_now = '1' then
                state <= ST_IDLE;
              else
                frm_go    <= '1';
                frm_pend  <= '1';
                frm_dummy <= '0';
                frm_disc  <= '1';
                frm_wch   <= sel_first;
                frm_ech   <= chip_sel;
                frm_last  <= '0';
                frm_derr  <= '0';
              end if;
            elsif frm_cancel = '1' then
              frm_pend <= '0';
              state    <= ST_IDLE;
            elsif frm_done = '1' then
              frm_pend     <= '0';
              chip_sel     <= frm_wch;
              chip_sel_vld <= '1';
              state        <= ST_MEAS;
            end if;

          when ST_MEAS =>
            -- ölçüm frame'i: cur_ch çevrilir, sıradaki kanal (son kanalda
            -- bir sonraki taramanın ilk kanalı) yazılır
            if frm_pend = '0' then
              if stop_now = '1' then
                state <= ST_IDLE;
              else
                frm_go    <= '1';
                frm_pend  <= '1';
                frm_dummy <= '0';
                frm_disc  <= '0';
                frm_ech   <= cur_ch;
                frm_last  <= sel_last;
                frm_derr  <= '0';
                if sel_last = '1' then
                  frm_wch <= sel_first;
                else
                  frm_wch <= sel_next;
                end if;
              end if;
            elsif frm_cancel = '1' then
              frm_pend <= '0';
              state    <= ST_IDLE;
            elsif frm_done = '1' then
              frm_pend <= '0';
              if frm_derr = '1' or rx_err_p = '1' then
                -- veri hatası: taramayı kes, sonraki tarama select ile hizalanır
                err_r        <= '1';
                err_scan     <= '1';
                chip_sel_vld <= '0';
                state        <= ST_SCAN_END;
              else
                chip_sel     <= frm_wch;
                chip_sel_vld <= '1';
                if frm_last = '1' then
                  state <= ST_SCAN_END;
                else
                  cur_ch <= frm_wch;
                end if;
              end if;
            end if;

          when ST_SCAN_END =>
            -- tarama sınırı: önce örnekle, sonra yeni değerlerle karar ver
            err_scan <= '0';
            if err_scan = '1' and err_cnt = ERR_LIMIT - 1 then
              err_cnt      <= 0;
              pwr_done     <= '0';
              chip_sel_vld <= '0';
              state        <= ST_IDLE;
            else
              if err_scan = '1' then
                err_cnt <= err_cnt + 1;
              else
                err_cnt <= 0;
              end if;
              mask_cur   <= ch_mask;
              period_cur <= unsigned(period_us);
              if continuous = '0' or stop_now = '1' or ch_mask = C_MASK_NONE then
                state <= ST_IDLE;
              else
                state <= ST_PERIOD_WAIT;
              end if;
            end if;

          when ST_PERIOD_WAIT =>
            if stop_now = '1' then
              state <= ST_IDLE;
            elsif per_ok = '1' then
              state <= ST_SCAN_START;
            end if;

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
  core_rst <= core_rst_r;
  fifo_clr <= '1' when state = ST_IDLE or state = ST_CORE_RST else '0';
  per_rst  <= '1' when state = ST_SCAN_START else '0';

  -- ==========================================================================
  -- Timer'lar
  -- ==========================================================================
  -- cycle timer: paket launch'ından (ilk komut handshake'i) itibaren sayar.
  -- Launch -> CS falling edge gecikmesi sabit olduğundan launch'lar arası
  -- >= CYCLE_CLKS clk, CS falling edge'ler arası >= 5 us demektir.
  -- Reset'te 0'dan başlar: reset sonrası ilk frame 5 us bekler.
  -- rst_n async; frm_launch ile sıfırlama senkron (soft clear).
  p_cyc : process (clk, rst_n)
  begin
    if rst_n = '0' then
      cyc_cnt <= 0;
    elsif rising_edge(clk) then
      if frm_launch = '1' then
        cyc_cnt <= 0;
      elsif cyc_cnt < CYCLE_CLKS - 1 then
        cyc_cnt <= cyc_cnt + 1;
      end if;
    end if;
  end process p_cyc;
  cyc_ok <= '1' when cyc_cnt = CYCLE_CLKS - 1 else '0';

  -- power-up timer: dummy frame'in SYNC'inden sonra ST_PWR_WAIT'te sayar
  -- rst_n async; ST_PWR_WAIT dışında sıfırlama senkron.
  p_pwr : process (clk, rst_n)
  begin
    if rst_n = '0' then
      pwr_cnt <= 0;
    elsif rising_edge(clk) then
      if state /= ST_PWR_WAIT then
        pwr_cnt <= 0;
      elsif pwr_cnt < PWRUP_CLKS - 1 then
        pwr_cnt <= pwr_cnt + 1;
      end if;
    end if;
  end process p_pwr;
  pwr_ok <= '1' when pwr_cnt = PWRUP_CLKS - 1 else '0';

  -- period timer: tarama tetiğinde (ST_SCAN_START) sıfırlanır, us sayar
  -- rst_n async; per_rst (ST_SCAN_START) senkron.
  p_per : process (clk, rst_n)
  begin
    if rst_n = '0' then
      per_pre <= 0;
      per_us  <= (others => '0');
    elsif rising_edge(clk) then
      if per_rst = '1' then
        per_pre <= C_PER_FSM_LAT;
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

  -- SYNC timeout: launch'tan itibaren sayar (gnt bekleme dahil değil)
  to_hit <= '1' when pk_launched = '1' and to_cnt = SYNC_TO_CLKS - 1 and sync_valid = '0'
            else '0';

  -- ==========================================================================
  -- Command packer
  -- ==========================================================================
  pk_launched <= '1' when (pk_st = PK_CMD and pk_idx /= C_PK_CLK_DIV) or pk_st = PK_WAIT
                 else '0';

  with pk_idx select cmd_i <=
    C_CMD_CLK_DIV                                         when C_PK_CLK_DIV,
    C_CMD_MODE                                            when C_PK_MODE,
    C_CMD_WORDLEN                                         when C_PK_WORDLEN,
    C_CMD_CS_ON                                           when C_PK_CS_ON,
    C_CMD_XFER                                            when C_PK_XFER,
    C_CMD_CS_OFF                                          when C_PK_CS_OFF,
    C_CMD_SYNC0(15 downto 8) & std_logic_vector(sync_id)  when others;

  -- ilk komut cycle timer dolmadan ve gnt gelmeden verilmez
  cmd_valid_i <= '1' when pk_st = PK_CMD and gnt = '1' and frm_cancel = '0' and
                          (pk_idx /= C_PK_CLK_DIV or cyc_ok = '1')
                 else '0';
  cmd_hs      <= cmd_valid_i and cmd_ready;
  frm_launch  <= '1' when cmd_hs = '1' and pk_idx = C_PK_CLK_DIV else '0';

  frm_done <= '1' when pk_st = PK_WAIT and sync_valid = '1' and sync = std_logic_vector(sync_id)
              else '0';
  sync_err <= '1' when sync_valid = '1' and
                       (pk_st /= PK_WAIT or sync /= std_logic_vector(sync_id))
              else '0';

  p_pack : process (clk, rst_n)
  begin
    if rst_n = '0' then
      pk_st       <= PK_IDLE;
      pk_idx      <= C_PK_CLK_DIV;
      pk_dummy    <= '0';
      pk_wch      <= (others => '0');
      sync_id     <= (others => '0');
      sdo_r       <= (others => '0');
      sdo_valid_r <= '0';
      to_cnt      <= 0;
    elsif rising_edge(clk) then
      if sdo_valid_r = '1' and sdo_ready = '1' then
        sdo_valid_r <= '0';
      end if;

      if pk_launched = '1' and to_cnt < SYNC_TO_CLKS - 1 then
        to_cnt <= to_cnt + 1;
      end if;

      if struct_err = '1' then
        -- yapısal hata: paket bırakılır (timeout'ta çekirdek reset'lenir)
        pk_st       <= PK_IDLE;
        pk_idx      <= C_PK_CLK_DIV;
        sdo_valid_r <= '0';
        if sync_valid = '1' then
          sync_id <= sync_id + 1;
        end if;
      else
        case pk_st is
          when PK_IDLE =>
            pk_idx <= C_PK_CLK_DIV;
            if frm_go = '1' then
              pk_dummy <= frm_dummy;
              pk_wch   <= frm_wch;
              pk_st    <= PK_CMD;
            end if;

          when PK_CMD =>
            if frm_cancel = '1' then
              pk_st <= PK_IDLE;
            elsif cmd_hs = '1' then
              if pk_idx = C_PK_CLK_DIV then
                -- launch: sdo kelimesi burada kurulur (range/coding örneklenir)
                to_cnt      <= 0;
                sdo_valid_r <= '1';
                if pk_dummy = '1' then
                  sdo_r <= C_AD_DUMMY_WORD;
                else
                  sdo_r <= ctrl_word(pk_wch, range_sel, coding_sel);
                end if;
              end if;
              if pk_idx = C_PK_LAST then
                pk_st <= PK_WAIT;
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

  req       <= '1' when (pk_st = PK_CMD and (pk_idx /= C_PK_CLK_DIV or cyc_ok = '1')) or
                        pk_st = PK_WAIT
               else '0';
  cmd       <= cmd_i;
  cmd_valid <= cmd_valid_i;
  sdo_data  <= sdo_r;
  sdo_valid <= sdo_valid_r;

  -- ==========================================================================
  -- Expectation FIFO: launch'ta push, sdi_valid'de pop
  -- ==========================================================================
  -- rst_n async; fifo_clr (ST_IDLE / ST_CORE_RST) senkron.
  p_fifo : process (clk, rst_n)
  begin
    if rst_n = '0' then
      fifo_wr  <= 0;
      fifo_rd  <= 0;
      fifo_cnt <= 0;
      fifo_mem <= (others => (others => '0'));
    elsif rising_edge(clk) then
      if fifo_clr = '1' then
        fifo_wr  <= 0;
        fifo_rd  <= 0;
        fifo_cnt <= 0;
        fifo_mem <= (others => (others => '0'));
      else
        if frm_launch = '1' and fifo_cnt < C_FIFO_DEPTH then
          fifo_mem(fifo_wr) <= frm_last & frm_disc & std_logic_vector(frm_ech);
          if fifo_wr = C_FIFO_DEPTH - 1 then
            fifo_wr <= 0;
          else
            fifo_wr <= fifo_wr + 1;
          end if;
        end if;
        if sdi_valid = '1' and fifo_cnt /= 0 then
          if fifo_rd = C_FIFO_DEPTH - 1 then
            fifo_rd <= 0;
          else
            fifo_rd <= fifo_rd + 1;
          end if;
        end if;
        if (frm_launch = '1' and fifo_cnt < C_FIFO_DEPTH) and not (sdi_valid = '1' and fifo_cnt /= 0) then
          fifo_cnt <= fifo_cnt + 1;
        elsif not (frm_launch = '1' and fifo_cnt < C_FIFO_DEPTH) and (sdi_valid = '1' and fifo_cnt /= 0) then
          fifo_cnt <= fifo_cnt - 1;
        end if;
      end if;
    end if;
  end process p_fifo;

  exp_last <= fifo_mem(fifo_rd)(3);
  exp_disc <= fifo_mem(fifo_rd)(2);
  exp_ch   <= unsigned(fifo_mem(fifo_rd)(1 downto 0));
  fifo_unf <= '1' when sdi_valid = '1' and fifo_cnt = 0 else '0';

  -- ==========================================================================
  -- RX checker (combinational) + output register
  -- ==========================================================================
  rx_take    <= '1' when sdi_valid = '1' and fifo_cnt /= 0 and exp_disc = '0' else '0';
  rx_lead_ok <= '1' when sdi_data(C_DOUT_LEAD_HI downto C_DOUT_LEAD_LO) = C_DOUT_LEAD_OK else '0';
  rx_addr_ok <= '1' when sdi_data(C_DOUT_ADDR_HI downto C_DOUT_ADDR_LO) = std_logic_vector(exp_ch)
                else '0';

  p_out : process (clk, rst_n)
  begin
    if rst_n = '0' then
      data_valid_r <= '0';
      data_ch_r    <= (others => '0');
      data_r       <= (others => '0');
      data_last_r  <= '0';
      rx_err_p     <= '0';
    elsif rising_edge(clk) then
      data_valid_r <= '0';
      data_last_r  <= '0';
      rx_err_p     <= '0';
      if rx_take = '1' then
        if rx_lead_ok = '1' and rx_addr_ok = '1' then
          data_valid_r <= '1';
          data_ch_r    <= std_logic_vector(exp_ch);
          data_r       <= sdi_data(C_DOUT_DATA_HI downto 0);
          data_last_r  <= exp_last;
        else
          rx_err_p <= '1';
        end if;
      end if;
    end if;
  end process p_out;

  data_valid <= data_valid_r;
  data_ch    <= data_ch_r;
  data       <= data_r;
  data_last  <= data_last_r;

end architecture rtl;
