-- banked_mem.vhd  (VHDL-2008)
-- N banks of WORD_BITS each. Narrow write: one AXI word/cycle, addressed by word
-- index (write decode is pure bit-slice). Wide read: all banks share one address,
-- concatenated to NUM_BANKS*WORD_BITS, registered -> 1-cycle latency.
--
-- D : NUM_BANKS=16, WORD_BITS=32, DEPTH=1024, ADDR_BITS=10, W_BITS=14, RAM_STYLE="block"
--      -> 16 RAMB36, read = 512b/cycle (32 Q1.15 lanes), constant across the MAC_BITS sweep.
-- r : NUM_BANKS=16, WORD_BITS=32, DEPTH=4,    ADDR_BITS=2,  W_BITS=6,  RAM_STYLE="distributed"
--      -> LUTRAM (4 deep is far too shallow to spend BRAM width on).
--
-- Read lane k (bits[16k+15:16k]) = entry(32*c + k) of the addressed atom, matching
-- the engine's d_data/r_data convention and contract section 5. Verified in sim model.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity banked_mem is
  generic (
    NUM_BANKS : natural := 16;
    WORD_BITS : natural := 32;
    DEPTH     : natural := 1024;
    ADDR_BITS : natural := 10;
    W_BITS    : natural := 14;
    BANK_SEL  : natural := 4;          -- log2(NUM_BANKS)
    MEM_STYLE : string  := "block"
  );
  port (
    clk    : in  std_logic;
    -- narrow write port (TB preload now; AXI4-Lite slave in P6)
    we     : in  std_logic;
    w_word : in  std_logic_vector(W_BITS-1 downto 0);   -- AXI word index
    wdata  : in  std_logic_vector(WORD_BITS-1 downto 0);
    -- wide read port (engine side): 1-cycle latency
    raddr  : in  std_logic_vector(ADDR_BITS-1 downto 0);
    rdata  : out std_logic_vector(NUM_BANKS*WORD_BITS-1 downto 0)
  );
end entity;

architecture rtl of banked_mem is
  -- write decode is just a slice of the word index:
  --   bank = w_word[BANK_SEL-1 : 0]
  --   addr = w_word[BANK_SEL+ADDR_BITS-1 : BANK_SEL]
  signal wbank : unsigned(BANK_SEL-1 downto 0);
  signal waddr : unsigned(ADDR_BITS-1 downto 0);
begin
  wbank <= unsigned(w_word(BANK_SEL-1 downto 0));
  waddr <= unsigned(w_word(BANK_SEL+ADDR_BITS-1 downto BANK_SEL));

  gen_banks : for b in 0 to NUM_BANKS-1 generate
    type bank_t is array (0 to DEPTH-1) of std_logic_vector(WORD_BITS-1 downto 0);
    signal mem     : bank_t;
    signal bank_we : std_logic;
    attribute ram_style : string;
    attribute ram_style of mem : signal is MEM_STYLE;
  begin
    bank_we <= we when (to_integer(wbank) = b) else '0';
    process (clk)
    begin
      if rising_edge(clk) then
        if bank_we = '1' then
          mem(to_integer(waddr)) <= wdata;
        end if;
        -- registered read; no reset so the output FF stays in the BRAM tile
        rdata(WORD_BITS*(b+1)-1 downto WORD_BITS*b) <= mem(to_integer(unsigned(raddr)));
      end if;
    end process;
  end generate;
end architecture;