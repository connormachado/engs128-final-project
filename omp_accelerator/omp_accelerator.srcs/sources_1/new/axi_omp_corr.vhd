--------------------------------------------------------------------------------
-- axi_omp_corr.vhd  (rev 2 - matched to omp_mem_top port list)
--
-- AXI4-Lite slave wrapper around omp_mem_top.
-- omp_mem_top owns its own internal BRAMs; the PS writes them through a
-- simple 32-bit word-addressed write interface exposed here as AXI-mapped
-- memory regions.
--
-- Address map (all offsets from this slave's base):
--   0x00000  CTRL        W   bit0=START (self-clears, ignored while BUSY)
--                            bit1=SOFT_RESET
--   0x00004  STATUS      R   bit0=DONE  bit1=BUSY  bits[7:4]=VERSION=0x1
--   0x00010  RESULT_IDX  R   argmax index 0..255, valid when DONE=1
--   0x00014  RESULT_VAL  R   top-32 of 38-bit Q8.30 accumulator (debug)
--   0x00018  CYC_COUNT   R   cycle count of last engine run (debug)
--   0x01000+ BRAM_D      W   dictionary D, 16384 x 32b words (atom-major)
--   0x11000+ BRAM_R      W   residual r,   64   x 32b words
--
-- AXI address bus is 17 bits wide: covers 0x00000..0x1FFFF (128 KB).
--   bit16    : selects D (0) vs R (1) memory region vs control (<0x1000)
--   The control region decode uses bits [4:2] for the word index.
--
-- WHAT IS READY TO USE:
--   Full AXI4-Lite control plane, memory-region write decode, all register
--   reads. No clock-domain crossings (single clock throughout).
--
-- WHAT TO VERIFY AGAINST YOUR ENTITY:
--   Component declaration below matches omp_mem_top exactly.
--   d_w_word address arithmetic (see ADAPT comment).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_omp_corr is
  generic (
    -- omp_mem_top generics - keep in sync with your engine
    G_IO_BITS  : natural := 16;
    G_MAC_BITS : natural := 16;
    G_NUM_MACS : natural := 32;
    G_N_CHUNKS : natural := 4;
    G_ACC_BITS : natural := 38;
    G_N_ATOMS  : natural := 256;

    -- AXI4-Lite geometry
    C_S_AXI_DATA_WIDTH : integer := 32;
    -- 17-bit address: covers control (0x000xx) + D (0x1xxx+) + R (0x11xxx+)
    C_S_AXI_ADDR_WIDTH : integer := 17
  );
  port (
    S_AXI_ACLK    : in  std_logic;
    S_AXI_ARESETN : in  std_logic;   -- active-LOW from PS reset block

    S_AXI_AWADDR  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    S_AXI_AWPROT  : in  std_logic_vector(2 downto 0);
    S_AXI_AWVALID : in  std_logic;
    S_AXI_AWREADY : out std_logic;
    S_AXI_WDATA   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    S_AXI_WSTRB   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
    S_AXI_WVALID  : in  std_logic;
    S_AXI_WREADY  : out std_logic;
    S_AXI_BRESP   : out std_logic_vector(1 downto 0);
    S_AXI_BVALID  : out std_logic;
    S_AXI_BREADY  : in  std_logic;

    S_AXI_ARADDR  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    S_AXI_ARPROT  : in  std_logic_vector(2 downto 0);
    S_AXI_ARVALID : in  std_logic;
    S_AXI_ARREADY : out std_logic;
    S_AXI_RDATA   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    S_AXI_RRESP   : out std_logic_vector(1 downto 0);
    S_AXI_RVALID  : out std_logic;
    S_AXI_RREADY  : in  std_logic
  );
end entity axi_omp_corr;

architecture rtl of axi_omp_corr is

  --------------------------------------------------------------------------
  -- omp_mem_top component - matches your entity declaration exactly.
  -- Do not change anything here unless you change the entity itself.
  --------------------------------------------------------------------------
  component omp_mem_top is
    generic (
      IO_BITS          : natural := 16;
      MAC_BITS         : natural := 16;
      NUM_MACS         : natural := 32;
      N_CHUNKS         : natural := 4;
      ACC_BITS         : natural := 38;
      N_ATOMS          : natural := 256;
      RESULT_VAL_TOP32 : boolean := true
    );
    port (
      aclk       : in  std_logic;
      rst        : in  std_logic;
      start      : in  std_logic;
      soft_reset : in  std_logic;

      d_we       : in  std_logic;
      d_w_word   : in  std_logic_vector(13 downto 0);
      d_wdata    : in  std_logic_vector(31 downto 0);

      r_we       : in  std_logic;
      r_w_word   : in  std_logic_vector(5 downto 0);
      r_wdata    : in  std_logic_vector(31 downto 0);

      busy           : out std_logic;
      done           : out std_logic;
      result_idx     : out std_logic_vector(7 downto 0);
      result_val     : out std_logic_vector(31 downto 0);
      cyc_count      : out std_logic_vector(31 downto 0);
      dbg_best_score : out std_logic_vector(G_ACC_BITS-1 downto 0)
    );
  end component;

  constant VERSION : std_logic_vector(3 downto 0) := x"1";

  -------------------------------------------------------------------------
  -- Engine control signals
  -------------------------------------------------------------------------
  signal eng_busy       : std_logic;
  signal eng_done       : std_logic;
  signal eng_result_idx : std_logic_vector(7 downto 0);
  signal eng_result_val : std_logic_vector(31 downto 0);
  signal eng_cyc_count  : std_logic_vector(31 downto 0);
  signal eng_dbg        : std_logic_vector(G_ACC_BITS-1 downto 0);

  signal start_pulse    : std_logic := '0';
  signal softrst_pulse  : std_logic := '0';
  signal sys_rst        : std_logic;   -- active-HIGH to engine

  -------------------------------------------------------------------------
  -- Engine memory write signals (driven from AXI write decode)
  -------------------------------------------------------------------------
  signal d_we     : std_logic := '0';
  signal d_w_word : std_logic_vector(13 downto 0) := (others => '0');
  signal d_wdata  : std_logic_vector(31 downto 0) := (others => '0');
  signal r_we     : std_logic := '0';
  signal r_w_word : std_logic_vector(5 downto 0)  := (others => '0');
  signal r_wdata  : std_logic_vector(31 downto 0) := (others => '0');

  -------------------------------------------------------------------------
  -- AXI4-Lite slave internals
  -------------------------------------------------------------------------
  signal axi_awready : std_logic := '0';
  signal axi_wready  : std_logic := '0';
  signal axi_bvalid  : std_logic := '0';
  signal axi_arready : std_logic := '0';
  signal axi_rvalid  : std_logic := '0';
  signal axi_rdata   : std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
  signal axi_awaddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal axi_araddr  : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
  signal aw_en       : std_logic := '1';

  -- Address region flags (registered with the address latch)
  signal wr_is_D    : std_logic := '0';   -- write landed in BRAM_D region
  signal wr_is_R    : std_logic := '0';   -- write landed in BRAM_R region
  signal wr_is_ctrl : std_logic := '0';   -- write landed in control region
  signal wr_word    : integer range 0 to 7 := 0;  -- word index for control writes

  -- Combinational decode helpers
  signal awaddr_word  : integer range 0 to 7;
  signal awaddr_is_D  : std_logic;
  signal awaddr_is_R  : std_logic;

  -- Read word index
  signal rd_word : integer range 0 to 7;

begin

  --------------------------------------------------------------------------
  -- Engine instantiation
  --------------------------------------------------------------------------
  u_mem_top : omp_mem_top
    generic map (
      IO_BITS          => G_IO_BITS,
      MAC_BITS         => G_MAC_BITS,
      NUM_MACS         => G_NUM_MACS,
      N_CHUNKS         => G_N_CHUNKS,
      ACC_BITS         => G_ACC_BITS,
      N_ATOMS          => G_N_ATOMS,
      RESULT_VAL_TOP32 => true
    )
    port map (
      aclk       => S_AXI_ACLK,
      rst        => sys_rst,
      start      => start_pulse,
      soft_reset => softrst_pulse,

      d_we       => d_we,
      d_w_word   => d_w_word,
      d_wdata    => d_wdata,

      r_we       => r_we,
      r_w_word   => r_w_word,
      r_wdata    => r_wdata,

      busy           => eng_busy,
      done           => eng_done,
      result_idx     => eng_result_idx,
      result_val     => eng_result_val,
      cyc_count      => eng_cyc_count,
      dbg_best_score => eng_dbg
    );

  -- Active-high reset to the engine: system reset only.
  -- SOFT_RESET goes separately so the engine can distinguish them if needed.
  sys_rst <= not S_AXI_ARESETN;

  --------------------------------------------------------------------------
  -- Output assignments
  --------------------------------------------------------------------------
  S_AXI_AWREADY <= axi_awready;
  S_AXI_WREADY  <= axi_wready;
  S_AXI_BRESP   <= "00";
  S_AXI_BVALID  <= axi_bvalid;
  S_AXI_ARREADY <= axi_arready;
  S_AXI_RVALID  <= axi_rvalid;
  S_AXI_RRESP   <= "00";
  S_AXI_RDATA   <= axi_rdata;

  --------------------------------------------------------------------------
  -- Address region decode (combinational)
  --
  -- Address layout (offsets from slave base):
  --   bits[16:12] = 0b00000..0b00000   -> control   (0x00000..0x00FFF)
  --   bits[16:12] = 0b00001            -> BRAM_D lo  (0x01000..0x01FFF)
  --   ...continuing...                              (0x01000..0x0FFFF)
  --   bits[16]    = 1                  -> BRAM_R     (0x11000..0x117FF)
  --
  -- Simpler decode: BRAM_R if addr >= 0x11000 (bit16=1),
  --                 BRAM_D if addr >= 0x01000 and bit16=0,
  --                 control otherwise.
  --
  -- ADAPT: verify these thresholds match how your Python loader writes.
  -- The d_w_word arithmetic: byte_offset = awaddr - 0x1000
  --   word_offset = byte_offset >> 2  = awaddr[15:2] - 0x400
  -- 14 bits covers 0..16383 which is exactly 128x256/2 = 16384 words. Good.
  --------------------------------------------------------------------------
  awaddr_is_R  <= axi_awaddr(16);
  awaddr_is_D  <= '1' when (axi_awaddr(16) = '0' and
                             unsigned(axi_awaddr(15 downto 12)) >= 1)
                  else '0';
  awaddr_word  <= to_integer(unsigned(axi_awaddr(4 downto 2)));

  --------------------------------------------------------------------------
  -- AXI4-Lite write channel
  -- Both address and data arrive simultaneously for AXI4-Lite; accept both
  -- in the same cycle, issue BREADY on the next.
  --------------------------------------------------------------------------
  --------------------------------------------------------------------------
  -- AXI4-Lite write channel
  -- Both address and data arrive simultaneously for AXI4-Lite; accept both
  -- in the same cycle, issue BREADY on the next.
  --------------------------------------------------------------------------
  process(S_AXI_ACLK)
  begin
    if rising_edge(S_AXI_ACLK) then
      -- default: pulses are one cycle wide
      start_pulse   <= '0';
      softrst_pulse <= '0';
      d_we          <= '0';
      r_we          <= '0';

      if S_AXI_ARESETN = '0' then
        axi_awready <= '0';
        axi_wready  <= '0';
        axi_bvalid  <= '0';
        aw_en       <= '1';
        axi_awaddr  <= (others => '0');
        wr_is_D     <= '0';
        wr_is_R     <= '0';
        wr_is_ctrl  <= '0';
        wr_word     <= 0;
      else

        ---------------------------------------------------------------
        -- Accept address + data
        ---------------------------------------------------------------
        if (axi_awready = '0' and S_AXI_AWVALID = '1' and
            S_AXI_WVALID = '1' and aw_en = '1') then
            axi_awready <= '1';
            axi_wready  <= '1';
            axi_awaddr  <= S_AXI_AWADDR;

            -- Region decode on bits[16:12] (5 bits, values 0-31):
            --   0      -> CTRL    0x00000-0x00FFF
            --   1..16  -> BRAM_D  0x01000-0x10FFF  (spans the bit-16 boundary)
            --   17     -> BRAM_R  0x11000-0x11FFF
            if (unsigned(S_AXI_AWADDR(16 downto 12)) >= 1 and
                unsigned(S_AXI_AWADDR(16 downto 12)) <= 16) then
                wr_is_D    <= '1';
            else
                wr_is_D    <= '0';
            end if;

            if unsigned(S_AXI_AWADDR(16 downto 12)) = 17 then
                wr_is_R    <= '1';
            else
                wr_is_R    <= '0';
            end if;

            if unsigned(S_AXI_AWADDR(16 downto 12)) = 0 then
                wr_is_ctrl <= '1';
            else
                wr_is_ctrl <= '0';
            end if;

            wr_word    <= to_integer(unsigned(S_AXI_AWADDR(4 downto 2)));
            aw_en      <= '0';
        else
          axi_awready <= '0';
          axi_wready  <= '0';
        end if;

        ---------------------------------------------------------------
        -- Write commit: fires the cycle both readies go high
        ---------------------------------------------------------------
        if (axi_awready = '1' and axi_wready = '1') then

          if wr_is_ctrl = '1' then
            -------------------------------------------------------
            -- Control register writes
            -------------------------------------------------------
            if wr_word = 0 then           -- CTRL @ 0x00
              if S_AXI_WSTRB(0) = '1' then
                if S_AXI_WDATA(0) = '1' and eng_busy = '0' then
                  start_pulse <= '1';     -- START: only when idle
                end if;
                if S_AXI_WDATA(1) = '1' then
                  softrst_pulse <= '1';   -- SOFT_RESET
                end if;
              end if;
            end if;
            -- STATUS / RESULT registers are read-only; writes ignored.

          elsif wr_is_D = '1' then
            -------------------------------------------------------
            -- BRAM_D write  @ 0x1000 .. 0x10FFF
            -- d_w_word = (byte_addr - 0x1000) / 4
            -- 14-bit unsigned subtraction wraps correctly for
            -- atoms 240-255 (addr bit 16 set, bits[15:2] small).
            -------------------------------------------------------
            d_we     <= '1';
            d_wdata  <= S_AXI_WDATA;
            d_w_word <= std_logic_vector(
                          unsigned(axi_awaddr(15 downto 2)) -
                          to_unsigned(16#400#, 14));

          elsif wr_is_R = '1' then
            -------------------------------------------------------
            -- BRAM_R write  @ 0x11000 .. 0x110FF
            -- r has 64 words -> 6-bit index from byte_addr[7:2]
            -------------------------------------------------------
            r_we     <= '1';
            r_wdata  <= S_AXI_WDATA;
            r_w_word <= axi_awaddr(7 downto 2);
          end if;

        end if;

        ---------------------------------------------------------------
        -- Write response
        ---------------------------------------------------------------
        if (axi_awready = '1' and axi_wready = '1' and axi_bvalid = '0') then
          axi_bvalid <= '1';
        elsif (S_AXI_BREADY = '1' and axi_bvalid = '1') then
          axi_bvalid <= '0';
          aw_en      <= '1';
        end if;

      end if;
    end if;
  end process;

  --------------------------------------------------------------------------
  -- AXI4-Lite read channel
  -- All readable registers are control-region only (no reading from BRAMs).
  --------------------------------------------------------------------------
  rd_word <= to_integer(unsigned(axi_araddr(4 downto 2)));

  process(S_AXI_ACLK)
  begin
    if rising_edge(S_AXI_ACLK) then
      if S_AXI_ARESETN = '0' then
        axi_arready <= '0';
        axi_rvalid  <= '0';
        axi_araddr  <= (others => '0');
        axi_rdata   <= (others => '0');
      else

        -- Latch read address
        if (axi_arready = '0' and S_AXI_ARVALID = '1') then
          axi_arready <= '1';
          axi_araddr  <= S_AXI_ARADDR;
        else
          axi_arready <= '0';
        end if;

        -- Drive read data
        if (axi_arready = '1' and S_AXI_ARVALID = '1' and axi_rvalid = '0') then
          axi_rvalid <= '1';
          axi_rdata  <= (others => '0');
          case rd_word is
            when 1 =>   -- STATUS @ 0x04
              axi_rdata(0)          <= eng_done;
              axi_rdata(1)          <= eng_busy;
              axi_rdata(7 downto 4) <= VERSION;
            when 4 =>   -- RESULT_IDX @ 0x10
              axi_rdata(7 downto 0) <= eng_result_idx;
            when 5 =>   -- RESULT_VAL @ 0x14  (top-32 of Q8.30)
              axi_rdata <= eng_result_val;
            when 6 =>   -- CYC_COUNT @ 0x18  (bonus debug register)
              axi_rdata <= eng_cyc_count;
            when others =>
              axi_rdata <= (others => '0');
          end case;

        elsif (axi_rvalid = '1' and S_AXI_RREADY = '1') then
          axi_rvalid <= '0';
        end if;

      end if;
    end if;
  end process;

end architecture rtl;