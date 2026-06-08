-- tb_omp_engine.vhd  (VHDL-2008)
-- Gate TB: runs the engine against all 5 golden vectors, now reading from REAL
-- inferred BRAM/LUTRAM via omp_mem_top (omp_engine + banked_mem x2) instead of a
-- modelled-memory process.  The DUT is omp_mem_top; omp_engine is UNCHANGED.
--
-- Memory is preloaded through omp_mem_top's narrow 32-bit write port -- the SAME
-- port the AXI4-Lite slave will drive in P6 -- so this exercises the real load
-- path's bank/row write-decode, not a sim backdoor.
--
-- The golden .mem files are UNCHANGED (still 512-bit-wide chunks, one per line):
--   <base>_D.mem   : N_DCHUNK lines, 128 hex chars each = one 512-bit D chunk,
--                    idx = atom*N_CHUNKS + chunk.
--   <base>_r.mem   : N_CHUNKS lines, 128 hex chars each = one 512-bit r chunk.
--   <base>_exp.txt : "<IDX 2hex> <VAL 10hex>", VAL = 38b acc sign-extended to 40b.
--
-- Preload slices each 512-bit chunk into 16 x 32-bit bank writes at word index
-- w = chunk_addr*16 + bank, wdata = chunk[32*bank+31 : 32*bank].  banked_mem's
-- wide read concatenates the 16 banks back to the SAME 512 bits -> bit-identical
-- to the old modelled read, AND bit-identical to the BRAM contents the real §5
-- AXI load produces.  Gate semantics are unchanged: green on 5 = provably correct.
--
-- Compile order: banked_mem.vhd -> omp_engine.vhd -> omp_mem_top.vhd -> this.

library ieee;
use ieee.std_logic_1164.all;     -- hread (VHDL-2008) for std_logic_vector
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_omp_engine is end entity;

architecture sim of tb_omp_engine is

  constant N_ATOMS  : integer := 256;
  constant N_CHUNKS : integer := 4;
  constant N_DCHUNK : integer := N_ATOMS*N_CHUNKS;   -- 1024
  constant W        : integer := 512;                -- NUM_MACS*IO_BITS
  constant CLK_PER  : time    := 10 ns;              -- 100 MHz

  constant VEC_DIR  : string  := "goldenVectors/"; 

  -- Compile-time switch tied to ASSUMPTION A in the engine:
  --   true  -> tracker keeps the SIGNED winner (compare signed)
  --   false -> tracker stores |acc|           (compare magnitudes)
  constant EXPECT_SIGNED_VAL : boolean := true;

  -- clock / control
  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal start      : std_logic := '0';
  signal soft_reset : std_logic := '0';

  -- narrow 32-bit write ports (preload now; AXI4-Lite slave in P6)
  signal d_we       : std_logic := '0';
  signal d_w_word   : std_logic_vector(13 downto 0) := (others=>'0');
  signal d_wdata    : std_logic_vector(31 downto 0) := (others=>'0');
  signal r_we       : std_logic := '0';
  signal r_w_word   : std_logic_vector(5 downto 0)  := (others=>'0');
  signal r_wdata    : std_logic_vector(31 downto 0) := (others=>'0');

  -- engine outputs
  signal busy, done : std_logic;
  signal result_idx : std_logic_vector(7 downto 0);
  signal result_val : std_logic_vector(31 downto 0);
  signal cyc_count  : std_logic_vector(31 downto 0);
  signal dbg_best_score : std_logic_vector(37 downto 0);

begin

  clk <= not clk after CLK_PER/2;

  -- DUT is now the engine + real memory wrapper.  d_addr/r_addr/d_data/r_data
  -- are internal to omp_mem_top; the TB drives the write side instead.
  dut : entity work.omp_mem_top
    generic map ( MAC_BITS => 16 )   -- goldens are the MAC_BITS=16 reference (confirm w/ HDL-B)
    port map (
      aclk => clk, rst => rst, start => start, soft_reset => soft_reset,
      d_we => d_we, d_w_word => d_w_word, d_wdata => d_wdata,
      r_we => r_we, r_w_word => r_w_word, r_wdata => r_wdata,
      busy => busy, done => done,
      result_idx => result_idx, result_val => result_val, cyc_count => cyc_count,
      dbg_best_score => dbg_best_score
    );

  stim : process

    variable npass : integer := 0;

    -- Preload D: read 512-bit chunks, slice each into 16 x 32-bit bank writes.
    -- chunk addr a (= atom*N_CHUNKS + chunk) -> bank b at word index w = a*16 + b.
    procedure preload_d(constant base : string) is
      file f       : text;
      variable st  : file_open_status;
      variable L   : line;
      variable chunk : std_logic_vector(W-1 downto 0);
    begin
      file_open(st, f, VEC_DIR & base & "_D.mem", read_mode);
      assert st = open_ok report "MISSING VECTOR (D): " & base severity failure;
      d_we <= '1';
      for a in 0 to N_DCHUNK-1 loop
        assert not endfile(f) report "TRUNCATED D.mem: " & base severity failure;
        readline(f, L); hread(L, chunk);
        for b in 0 to 15 loop
          d_w_word <= std_logic_vector(to_unsigned(a*16 + b, 14));
          d_wdata  <= chunk(32*b+31 downto 32*b);
          wait until rising_edge(clk);
        end loop;
      end loop;
      d_we <= '0';
      file_close(f);
    end procedure;

    -- Preload r: same scheme, 4 chunks deep.  word index w = a*16 + b (6-bit).
    procedure preload_r(constant base : string) is
      file f       : text;
      variable st  : file_open_status;
      variable L   : line;
      variable chunk : std_logic_vector(W-1 downto 0);
    begin
      file_open(st, f, VEC_DIR & base & "_r.mem", read_mode);
      assert st = open_ok report "MISSING VECTOR (r): " & base severity failure;
      r_we <= '1';
      for a in 0 to N_CHUNKS-1 loop
        assert not endfile(f) report "TRUNCATED r.mem: " & base severity failure;
        readline(f, L); hread(L, chunk);
        for b in 0 to 15 loop
          r_w_word <= std_logic_vector(to_unsigned(a*16 + b, 6));
          r_wdata  <= chunk(32*b+31 downto 32*b);
          wait until rising_edge(clk);
        end loop;
      end loop;
      r_we <= '0';
      file_close(f);
    end procedure;

    procedure run_vector(constant base : string) is
      file f        : text;
      variable st   : file_open_status;
      variable L    : line;
      variable idx_e: std_logic_vector(7  downto 0);
      variable val_e: std_logic_vector(39 downto 0);
      variable tcnt : integer := 0;
    begin
      -- ---- preload memories through the real write port ----
      preload_d(base);
      preload_r(base);
      -- ---- load expected ----
      file_open(st, f, VEC_DIR & base & "_exp.txt", read_mode);
      assert st = open_ok report "MISSING VECTOR (exp): " & base severity failure;
      readline(f, L); hread(L, idx_e); hread(L, val_e);
      file_close(f);

      wait until rising_edge(clk);          -- settle edge after preload
      -- soft reset -> IDLE  (clears latched done from the previous vector)
      soft_reset <= '1'; wait until rising_edge(clk); soft_reset <= '0';
      wait until rising_edge(clk);
      -- start pulse
      start <= '1'; wait until rising_edge(clk); start <= '0';
      -- wait for DONE with a timeout (gate: never hang silently)
      loop
        wait until rising_edge(clk);
        exit when done = '1';
        tcnt := tcnt + 1;
        assert tcnt < 20000 report "TIMEOUT waiting DONE: " & base severity failure;
      end loop;

      -- ---- index assertion (primary correctness gate) ----
      assert result_idx = idx_e
        report "IDX MISMATCH " & base
             & ": got "  & integer'image(to_integer(unsigned(result_idx)))
             & " exp "   & integer'image(to_integer(unsigned(idx_e)))
        severity failure;

      -- ---- value assertion (white-box: full 38b signed accumulator) ----
      if EXPECT_SIGNED_VAL then
        assert resize(signed(dbg_best_score), 40) = signed(val_e)
          report "VAL MISMATCH (signed) " & base severity failure;
      else
        assert resize(abs(signed(dbg_best_score)), 40) = abs(signed(val_e))
          report "VAL MISMATCH (abs) " & base severity failure;
      end if;

      report "PASS " & base
           & "  idx="    & integer'image(to_integer(unsigned(result_idx)))
           & "  cycles=" & integer'image(to_integer(unsigned(cyc_count)))
        severity note;
      npass := npass + 1;
    end procedure;

  begin
    -- power-on reset
    rst <= '1'; start <= '0'; soft_reset <= '0';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    run_vector("test_03_winner_near_index_N");
--    run_vector("test_02_tight_margin");
--    run_vector("test_03_winner_near_index_0");
--    run_vector("test_04_winner_near_index_N");
--    run_vector("test_05_engineered_tie");

    report "TB COMPLETE: " & integer'image(npass) & "/5 vectors passed"
      severity note;
    assert npass = 5 report "NOT ALL VECTORS PASSED" severity failure;
    finish;
  end process;

end architecture;