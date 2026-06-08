-- omp_mem_top.vhd  (VHDL-2008)
-- Replaces the TB's modeled memory: omp_engine reads from real (inferable) BRAM/LUTRAM.
-- The engine entity is UNCHANGED. The write ports here are driven by the TB preload
-- now, and by the AXI4-Lite slave in P6 (same word-indexed interface, no logic change).

library ieee;
use ieee.std_logic_1164.all;

entity omp_mem_top is
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
    aclk        : in  std_logic;
    rst        : in  std_logic;
    start      : in  std_logic;
    soft_reset : in  std_logic;
    
    -- D dictionary write port: 16384 32b words, word index w (bank=w[3:0], row=w[13:4])
    d_we       : in  std_logic;
    d_w_word   : in  std_logic_vector(13 downto 0);
    d_wdata    : in  std_logic_vector(31 downto 0);
    
    -- r residual write port: 64 32b words, word index w (bank=w[3:0], row=w[5:4])
    r_we       : in  std_logic;
    r_w_word   : in  std_logic_vector(5 downto 0);
    r_wdata    : in  std_logic_vector(31 downto 0);
    
    -- engine outputs
    busy           : out std_logic;
    done           : out std_logic;
    result_idx     : out std_logic_vector(7 downto 0);
    result_val     : out std_logic_vector(31 downto 0);
    cyc_count      : out std_logic_vector(31 downto 0);
    dbg_best_score : out std_logic_vector(ACC_BITS-1 downto 0)
  );
end entity;
--------------------------------------------------------------------------

--------------------------------------------------------------------------
architecture rtl of omp_mem_top is
--------------------------------------------------------------------------
    -- Signals
    signal d_addr : std_logic_vector(9 downto 0);
    signal r_addr : std_logic_vector(1 downto 0);
    signal d_data : std_logic_vector(NUM_MACS*IO_BITS-1 downto 0);
    signal r_data : std_logic_vector(NUM_MACS*IO_BITS-1 downto 0);

--------------------------------------------------------------------------
begin
    -- engine: read interface now points at BRAM/LUTRAM instead of the TB model
    u_engine : entity work.omp_engine
    generic map (
        IO_BITS => IO_BITS, MAC_BITS => MAC_BITS, NUM_MACS => NUM_MACS,
        N_CHUNKS => N_CHUNKS, ACC_BITS => ACC_BITS, N_ATOMS => N_ATOMS,
        RESULT_VAL_TOP32 => RESULT_VAL_TOP32
    )
    port map (
        clk => aclk, rst => rst, start => start, soft_reset => soft_reset,
        busy => busy, done => done,
        result_idx => result_idx, result_val => result_val, cyc_count => cyc_count,
        d_addr => d_addr, r_addr => r_addr, d_data => d_data, r_data => r_data,
        dbg_best_score => dbg_best_score
    );
    
    
    -- D: 16 x (1024 x 32b) block RAM -> 16 RAMB36, 512b/cycle read
    u_dmem : entity work.banked_mem
    generic map (
        NUM_BANKS => 16, WORD_BITS => 32, DEPTH => N_ATOMS*N_CHUNKS,
        ADDR_BITS => 10, W_BITS => 14, BANK_SEL => 4, MEM_STYLE => "block"
    )
    port map (
        clk => aclk, we => d_we, w_word => d_w_word, wdata => d_wdata,
        raddr => d_addr, rdata => d_data
    );
    
    
    -- r: 16 x (4 x 32b) distributed RAM (LUTRAM), 512b/cycle read
    u_rmem : entity work.banked_mem
    generic map (
        NUM_BANKS => 16, WORD_BITS => 32, DEPTH => N_CHUNKS,
        ADDR_BITS => 2, W_BITS => 6, BANK_SEL => 4, MEM_STYLE => "distributed"
    )
    port map (
        clk => aclk, we => r_we, w_word => r_w_word, wdata => r_wdata,
        raddr => r_addr, rdata => r_data
    );
end architecture;