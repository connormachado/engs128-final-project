-- omp_engine.vhd  (VHDL-2008)
-- Phase-2 COMPUTE engine: sequences N_ATOMS atoms through corr_datapath into
-- argmax_tracker.  IDLE -> COMPUTE -> FINISH.  Exposes a 1-cycle-latency
-- memory-read interface (TB-modelled now, real BRAM in Phase 3), a start->done
-- busy-cycle counter (Phase 5 latency axis), RESULT_VAL (§4 0x14), and a
-- full-38b white-box probe for the TB val-assert.
--
-- ASSUMPTION A (verify against your validated argmax_tracker BODY):
--   score_i receives the SIGNED 38-bit accumulator; the tracker abs-es it
--   internally for the strict-'>' compare and latches the SIGNED winner on
--   best_score.  Your session notes say this; the tracker entity header
--   comment says "abs before entering" -- they contradict.  If the tracker
--   truly needs a pre-abs'd input you must insert an abs stage feeding
--   score_i, capture the signed acc at the winner separately, and set
--   EXPECT_SIGNED_VAL=false in the TB.
--
-- ASSUMPTION B: corr_datapath emits 'done' for in-flight atoms during pipeline
--   drain after ce deasserts (standard for the streaming pipe you validated in P1).
-- ASSUMPTION C: d_addr is clog2(N_ATOMS*N_CHUNKS)=10 bits for the frozen sizes.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity omp_engine is
  generic (
    IO_BITS          : natural := 16;
    MAC_BITS         : natural := 16;   -- sweep knob; goldens are the MAC_BITS=16 ref
    NUM_MACS         : natural := 32;
    N_CHUNKS         : natural := 4;    -- ceil(M_LEN/NUM_MACS) = 128/32
    ACC_BITS         : natural := 38;
    N_ATOMS          : natural := 256;
    RESULT_VAL_TOP32 : boolean := true  -- OPEN ITEM: top-32 vs low-32 of the 38b acc
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;                       -- sync, active-high
    start      : in  std_logic;                       -- 1-cycle pulse (CTRL.START in P6)
    soft_reset : in  std_logic;                       -- 1-cycle pulse (CTRL.SOFT_RESET)
    busy       : out std_logic;
    done       : out std_logic;
    result_idx : out std_logic_vector(7 downto 0);    -- AXI zero-extends in P6
    result_val : out std_logic_vector(31 downto 0);   -- §4 0x14 (debug only)
    cyc_count  : out std_logic_vector(31 downto 0);   -- busy-cycle count (Phase 5)
    
    -- memory-read interface: 1-cycle read latency (TB now / real BRAM in P3)
    d_addr     : out std_logic_vector(9 downto 0);    -- 0..N_ATOMS*N_CHUNKS-1 (1023)
    r_addr     : out std_logic_vector(1 downto 0);    -- 0..N_CHUNKS-1 (3)
    d_data     : in  std_logic_vector(NUM_MACS*IO_BITS-1 downto 0);
    r_data     : in  std_logic_vector(NUM_MACS*IO_BITS-1 downto 0);
    -- white-box probe for the TB val-assert: full SIGNED 38b winner
    dbg_best_score : out std_logic_vector(ACC_BITS-1 downto 0)
  );
end entity;

architecture rtl of omp_engine is

  component corr_datapath
    generic ( 
                IO_BITS:natural:=16; 
                MAC_BITS:natural:=16;
                NUM_MACS:natural:=32; 
                N_CHUNKS:natural:=4; 
                ACC_BITS:natural:=38 );
    port ( clk,rst,ce,first : in std_logic;
           d_vec,r_vec : in  std_logic_vector(NUM_MACS*IO_BITS-1 downto 0);
           acc  : out signed(ACC_BITS-1 downto 0);
           done : out std_logic );
  end component;

  component argmax_tracker
    port ( clk_i      : in  std_logic;
           score_i    : in  signed(37 downto 0);
           j_i        : in  std_logic_vector(7 downto 0);
           best_idx   : out std_logic_vector(7 downto 0);
           best_score : out signed(37 downto 0);
           valid_i    : in  std_logic;
           clear_i    : in  std_logic );
  end component;

  constant N_DCHUNKS : integer := N_ATOMS*N_CHUNKS;   -- 1024

  type state_t is (IDLE, COMPUTE, FINISH);
  signal state : state_t := IDLE;

  signal addr_cnt   : integer range 0 to N_DCHUNKS-1 := 0;  -- address issued THIS cycle
  signal feed_en    : std_logic := '0';                     -- issuing addresses
  signal ce_r       : std_logic := '0';   -- HAZARD#2: ce delayed 1 -> lands on DATA cycle
  signal first_r    : std_logic := '0';   -- HAZARD#2: per-atom clear aligned to DATA cycle
  signal result_cnt : integer range 0 to N_ATOMS := 0;      -- HAZARD#1/#3 driver
  signal clr_trk    : std_logic := '0';
  signal cyc        : unsigned(31 downto 0) := (others=>'0');
  signal cyc_lat    : unsigned(31 downto 0) := (others=>'0');

  signal dp_acc     : signed(ACC_BITS-1 downto 0);
  signal dp_done    : std_logic;
  signal best_idx   : std_logic_vector(7 downto 0);
  signal best_score : signed(37 downto 0);

begin

  -- Address stage: combinational from the register -> data returns next cycle.
  d_addr <= std_logic_vector(to_unsigned(addr_cnt, 10));
  r_addr <= std_logic_vector(to_unsigned(addr_cnt mod N_CHUNKS, 2));


  -- Datapath. d_vec/r_vec are the registered memory outputs (already +1 cycle);
  -- ce_r/first_r are the +1 controls -> all three coincide on the valid-data cycle.
  u_dp : corr_datapath
    generic map ( IO_BITS=>IO_BITS, MAC_BITS=>MAC_BITS, NUM_MACS=>NUM_MACS,
                  N_CHUNKS=>N_CHUNKS, ACC_BITS=>ACC_BITS )
    port map ( clk=>clk, rst=>rst, ce=>ce_r, first=>first_r,
               d_vec=>d_data, r_vec=>r_data, acc=>dp_acc, done=>dp_done );


  -- Tracker.  j_i = result-side atom counter: dp_done pulses in order, so
  -- result_cnt names exactly the atom whose acc is on the bus this cycle.
  u_trk : argmax_tracker
    port map ( clk_i=>clk,
               score_i=>dp_acc,                                          -- ASSUMPTION A
               j_i=>std_logic_vector(to_unsigned(result_cnt mod N_ATOMS, 8)),
               best_idx=>best_idx, best_score=>best_score,
               valid_i=>dp_done, clear_i=>clr_trk );


  busy <= '1' when state=COMPUTE else '0';
  done <= '1' when state=FINISH  else '0';
  result_idx <= best_idx;
  result_val <= std_logic_vector(best_score(ACC_BITS-1 downto ACC_BITS-32)) when RESULT_VAL_TOP32
                else std_logic_vector(best_score(31 downto 0));
  dbg_best_score <= std_logic_vector(best_score);
  cyc_count <= std_logic_vector(cyc_lat);

  fsm : process(clk)
  begin
    if rising_edge(clk) then
      if rst='1' then
        state<=IDLE; feed_en<='0'; ce_r<='0'; first_r<='0';
        addr_cnt<=0; result_cnt<=0; clr_trk<='0';
        cyc<=(others=>'0'); cyc_lat<=(others=>'0');
      else
        clr_trk <= '0';                                  -- default; 1-cycle strobe below
        case state is

          when IDLE =>
            feed_en <= '0'; 
            ce_r <= '0'; 
            first_r <= '0';
            
            if start = '1' then
              state<=COMPUTE; feed_en<='1';
              addr_cnt<=0; result_cnt<=0;
              cyc<=(others=>'0'); clr_trk<='1';          -- clear tracker on COMPUTE entry
            end if;

          when COMPUTE =>
            -- address advance (issue chunk addresses 0..1023)
            if feed_en='1' then
              if addr_cnt = N_DCHUNKS-1 then feed_en<='0';  -- last address issued this cycle
              else addr_cnt <= addr_cnt + 1; end if;
            end if;
            -- HAZARD#2: register ce/first by 1 -> align to valid DATA cycle
            ce_r <= feed_en;
            if feed_en='1' and (addr_cnt mod N_CHUNKS = 0) then first_r<='1';
            else first_r<='0'; end if;
            -- results consumed (counts dones during drain too)
            if dp_done='1' then result_cnt <= result_cnt + 1; end if;
            -- busy-cycle counter (start->done latency, Phase 5)
            cyc <= cyc + 1;
            -- HAZARD#1 + #3: exit the cycle AFTER the 256th result; drive off
            -- result_cnt (NOT addr_cnt) so the tracker latch has settled.
            if result_cnt = N_ATOMS then
              state   <= FINISH;
              cyc_lat <= cyc + 1;                         -- inclusive busy-cycle count
            end if;
            if soft_reset='1' then                        -- abort -> IDLE
              state<=IDLE; feed_en<='0'; ce_r<='0'; first_r<='0';
            end if;

          when FINISH =>
            feed_en<='0'; ce_r<='0'; first_r<='0';
            if soft_reset='1' then
              state<=IDLE;
            elsif start='1' then
              state<=COMPUTE; feed_en<='1';
              addr_cnt<=0; result_cnt<=0;
              cyc<=(others=>'0'); clr_trk<='1';
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;