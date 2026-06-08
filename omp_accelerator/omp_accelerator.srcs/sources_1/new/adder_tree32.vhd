library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity adder_tree32 is
  generic ( PW : natural := 32 );      -- product width = 2*MAC_BITS
  port (
    clk   : in  std_logic;
    ce    : in  std_logic;             -- '1' when a fresh set of 32 products is valid
    prods : in  std_logic_vector(32*PW-1 downto 0);  -- lane k = bits [(k+1)*PW-1 : k*PW]
    sum   : out signed(PW+4 downto 0); -- 32-input sum grows by ceil(log2 32)=5 bits
    valid : out std_logic              -- ce delayed by the 5 tree stages
  );
end entity;
------------------------------------------------------------------------------

------------------------------------------------------------------------------
architecture rtl of adder_tree32 is
------------------------------------------------------------------------------
    constant W : natural := PW + 5;      -- uniform internal width; can't overflow 32 inputs
    type warr is array (natural range <>) of signed(W-1 downto 0);
    signal x  : warr(0 to 31);
    signal A : warr(0 to 15);
    signal B : warr(0 to 7);
    signal C : warr(0 to 3);
    signal D : warr(0 to 1);
    signal E : signed(W-1 downto 0);
    signal vpipe : std_logic_vector(4 downto 0) := (others => '0');
    
------------------------------------------------------------------------------
begin
------------------------------------------------------------------------------
    gen_unpack: for k in 0 to 31 generate
        x(k) <= resize(signed(prods((k+1)*PW-1 downto k*PW)), W);   -- sign-extend each lane
    end generate;
    
    process(clk) begin
        if rising_edge(clk) then
            for k in 0 to 15 loop A(k) <= x(2*k)  + x(2*k+1);  end loop;  -- stage 1
            for k in 0 to 7  loop B(k) <= A(2*k) + A(2*k+1); end loop;  -- stage 2
            for k in 0 to 3  loop C(k) <= B(2*k) + B(2*k+1); end loop;  -- stage 3
            for k in 0 to 1  loop D(k) <= C(2*k) + C(2*k+1); end loop;  -- stage 4
            E <= D(0) + D(1);                                           -- stage 5
            vpipe <= vpipe(3 downto 0) & ce;
        end if;
    end process;
    
    sum   <= resize(E, PW+5);
    valid <= vpipe(4);                   -- aligned with E: both are ce delayed by 5
end architecture;