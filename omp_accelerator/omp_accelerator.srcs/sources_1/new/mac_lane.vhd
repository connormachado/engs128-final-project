library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mac_lane is
  generic (
    IO_BITS  : natural := 16;          -- Q1.15 word width (frozen)
    MAC_BITS : natural := 16           -- sweep knob: # of top bits kept
  );
  port (
    clk  : in  std_logic;
    ce   : in  std_logic;
    d_in : in  signed(IO_BITS-1 downto 0);    -- Q1.15 dictionary sample
    r_in : in  signed(IO_BITS-1 downto 0);    -- Q1.15 residual sample
    p    : out signed(2*MAC_BITS-1 downto 0)  -- registered product
  );
end entity;
------------------------------------------------------------------------------

------------------------------------------------------------------------------
architecture rtl of mac_lane is
------------------------------------------------------------------------------
    -- Signals
  signal dt : signed(MAC_BITS-1 downto 0);
  signal rt : signed(MAC_BITS-1 downto 0);
  
------------------------------------------------------------------------------
begin
------------------------------------------------------------------------------
  -- THE line. Keep the top MAC_BITS bits == arithmetic >> (IO_BITS-MAC_BITS).
  dt <= d_in(IO_BITS-1 downto IO_BITS-MAC_BITS);
  rt <= r_in(IO_BITS-1 downto IO_BITS-MAC_BITS);

  process(clk) begin
    if rising_edge(clk) then
      if ce = '1' then
        p <= dt * rt;                  -- signed MAC_BITS × MAC_BITS -> 2*MAC_BITS
      end if;
    end if;
  end process;
  
end architecture;