library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity corr_datapath is
  generic (
    IO_BITS  : natural := 16;
    MAC_BITS : natural := 16;
    NUM_MACS : natural := 32;
    N_CHUNKS : natural := 4;
    ACC_BITS : natural := 38
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    ce    : in  std_logic;
    first : in  std_logic;
    d_vec : in  std_logic_vector(NUM_MACS*IO_BITS-1 downto 0);
    r_vec : in  std_logic_vector(NUM_MACS*IO_BITS-1 downto 0);
    acc   : out signed(ACC_BITS-1 downto 0);
    done  : out std_logic
  );
end entity;
------------------------------------------------------------------------------

architecture rtl of corr_datapath is
------------------------------------------------------------------------------

  constant PW : natural := 2*MAC_BITS;     -- product width
  constant SW : natural := PW + 5;         -- tree sum width


  component mac_lane is
    generic ( IO_BITS : natural := IO_BITS; MAC_BITS : natural := MAC_BITS );
    port ( clk : in std_logic; ce : in std_logic;
           d_in : in signed(IO_BITS-1 downto 0);
           r_in : in signed(IO_BITS-1 downto 0);
           p    : out signed(2*MAC_BITS-1 downto 0) );
  end component;


  component adder_tree32 is
    generic ( PW : natural := PW );
    port ( clk : in std_logic; ce : in std_logic;
           prods : in std_logic_vector(32*PW-1 downto 0);
           sum   : out signed(PW+4 downto 0);
           valid : out std_logic );
  end component;


  component chunk_acc is
    generic ( ACC_BITS : natural := ACC_BITS; 
              N_CHUNKS : natural := N_CHUNKS; 
              CH_BITS : natural  := 37);
    port ( clk : in std_logic; rst : in std_logic; ce : in std_logic;
           first : in std_logic;
           chunk : in signed(CH_BITS-1 downto 0);
           acc   : out signed(ACC_BITS-1 downto 0);
           done  : out std_logic );
  end component;


  signal prods : std_logic_vector(NUM_MACS*PW-1 downto 0);
  signal tsum  : signed(SW-1 downto 0);
  signal tvld  : std_logic;
  signal mac_v : std_logic := '0';
  signal dl    : std_logic_vector(5 downto 0) := (others => '0');
------------------------------------------------------------------------------

begin

------------------------------------------------------------------------------
  gen_mac : for k in 0 to NUM_MACS-1 generate
    signal pk : signed(PW-1 downto 0);
  begin
    u_mac : mac_lane
      generic map ( IO_BITS => IO_BITS, MAC_BITS => MAC_BITS )
      port map ( clk => clk, ce => ce,
                 d_in => signed(d_vec((k+1)*IO_BITS-1 downto k*IO_BITS)),
                 r_in => signed(r_vec((k+1)*IO_BITS-1 downto k*IO_BITS)),
                 p    => pk );
    prods((k+1)*PW-1 downto k*PW) <= std_logic_vector(pk);
  end generate;


  process(clk) begin
    if rising_edge(clk) then
      mac_v <= ce;                       -- products valid 1 cycle after ce
      dl    <= dl(4 downto 0) & first;   -- dl(5) = first delayed by 6
    end if;
  end process;


  u_tree : adder_tree32
    generic map ( PW => PW )
    port map ( clk => clk, ce => mac_v, prods => prods, sum => tsum, valid => tvld );


  u_acc : chunk_acc
    generic map ( ACC_BITS => ACC_BITS, N_CHUNKS => N_CHUNKS, CH_BITS => SW )
    port map ( clk => clk, rst => rst, ce => tvld, first => dl(5),
               chunk => tsum, acc => acc, done => done );

end architecture;