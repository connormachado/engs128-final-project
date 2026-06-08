library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

-- Test | MAC_BITS | ATOM_MEM    | EXPECTED                                | RESULT
-- 1    | 16       | atom0.mem   | 00000010110011010011000110101001101011  | PASS
-- 2    | 8        | atom0.mem   | 00000000000000000000001011001100011011  | PASS
-- 3    | 16       | atom157.mem | 11110101010101101011110100001101110101  |
-- 4    | 8        | atom157.mem | 11111111111111111111010101010110100111  |

entity tb_corr_datapath is
  generic (
    MAC_BITS : natural := 8;
    ATOM_MEM : string  := "atom157.mem";
    EXPECTED : std_logic_vector(37 downto 0) := "11111111111111111111010101010110100111"
  );
end entity;

architecture sim of tb_corr_datapath is
  constant IO_BITS  : natural := 16;
  constant NUM_MACS : natural := 32;
  constant N_CHUNKS : natural := 4;
  constant ACC_BITS : natural := 38;

  component corr_datapath
    generic ( IO_BITS : natural; MAC_BITS : natural; NUM_MACS : natural;
              N_CHUNKS : natural; ACC_BITS : natural );
    port ( clk : in std_logic; rst : in std_logic; ce : in std_logic; first : in std_logic;
           d_vec : in std_logic_vector(NUM_MACS*IO_BITS-1 downto 0);
           r_vec : in std_logic_vector(NUM_MACS*IO_BITS-1 downto 0);
           acc   : out signed(ACC_BITS-1 downto 0);
           done  : out std_logic );
  end component;

  signal clk, rst, ce, first, done : std_logic := '0';
  signal d_vec, r_vec : std_logic_vector(NUM_MACS*IO_BITS-1 downto 0) := (others => '0');
  signal acc : signed(ACC_BITS-1 downto 0);

  type mem128 is array (0 to 127) of std_logic_vector(15 downto 0);

  impure function load_mem(fn : string) return mem128 is
    file     fp : text;
    variable st : file_open_status;
    variable ln : line;
    variable w  : std_logic_vector(15 downto 0);
    variable m  : mem128 := (others => (others => '0'));
  begin
    file_open(st, fp, fn, read_mode);
    assert st = open_ok report "Cannot open " & fn severity failure;
    for i in 0 to 127 loop
      readline(fp, ln);
      hread(ln, w);
      m(i) := w;
    end loop;
    file_close(fp);
    return m;
  end function;

  constant ATOM : mem128 := load_mem(ATOM_MEM);
  constant RVEC : mem128 := load_mem("r.mem");
begin
  dut : corr_datapath
    generic map ( IO_BITS => IO_BITS, MAC_BITS => MAC_BITS, NUM_MACS => NUM_MACS,
                  N_CHUNKS => N_CHUNKS, ACC_BITS => ACC_BITS )
    port map ( clk => clk, rst => rst, ce => ce, first => first,
               d_vec => d_vec, r_vec => r_vec, acc => acc, done => done );

  clk <= not clk after 5 ns;     -- 100 MHz

  stim : process begin
    rst <= '1'; ce <= '0'; first <= '0';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    for c in 0 to N_CHUNKS-1 loop
      for k in 0 to NUM_MACS-1 loop
        d_vec((k+1)*IO_BITS-1 downto k*IO_BITS) <= ATOM(c*NUM_MACS + k);
        r_vec((k+1)*IO_BITS-1 downto k*IO_BITS) <= RVEC(c*NUM_MACS + k);
      end loop;
      ce <= '1';
      if c = 0 then first <= '1'; else first <= '0'; end if;
      wait until rising_edge(clk);
    end loop;
    ce <= '0'; first <= '0';

    wait until done = '1';
    wait until rising_edge(clk);

    if acc = signed(EXPECTED) then
      report "PASS: " & ATOM_MEM & " @ MAC_BITS=" & integer'image(MAC_BITS)
             & " -> acc = 0x" & to_hstring(std_logic_vector(acc)) severity note;
    else
      report "FAIL: " & ATOM_MEM & " @ MAC_BITS=" & integer'image(MAC_BITS)
             & " : acc = 0x" & to_hstring(std_logic_vector(acc))
             & " expected 0x" & to_hstring(EXPECTED) severity failure;
    end if;
    wait;
  end process;
end architecture;