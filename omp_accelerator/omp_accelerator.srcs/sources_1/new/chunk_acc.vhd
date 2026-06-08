library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity chunk_acc is
  generic (
    ACC_BITS : natural := 38;          -- Q8.30 - do NOT narrow (contract §3)
    N_CHUNKS : natural := 4;           -- ceil(M_LEN / NUM_MACS) = ceil(128/32)
    CH_BITS  : natural := 37           -- incoming chunk-sum width = 2*MAC_BITS+5
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    ce    : in  std_logic;             -- chunk sum valid this cycle (= tree.valid)
    first : in  std_logic;             -- '1' with the FIRST chunk of an atom
    chunk : in  signed(CH_BITS-1 downto 0);                -- one chunk sum (width <= ACC_BITS)
    acc   : out signed(ACC_BITS-1 downto 0);
    done  : out std_logic              -- 1-cycle pulse when the atom is complete
  );
end entity;

architecture rtl of chunk_acc is
    signal areg : signed(ACC_BITS-1 downto 0) := (others => '0');
    signal cnt  : integer range 0 to N_CHUNKS := 0;
    signal dn   : std_logic := '0';
begin
    process(clk) begin
        if rising_edge(clk) then
            dn <= '0';
            
            if rst = '1' then
                areg <= (others => '0'); cnt <= 0;
            elsif ce = '1' then
                if first = '1' then
                    areg <= resize(chunk, ACC_BITS); 
                    cnt <= 1;        -- load on chunk 0
                else
                    areg <= areg + resize(chunk, ACC_BITS); 
                    cnt <= cnt + 1;
                end if;
                
                if (first = '1' and N_CHUNKS = 1) or (first = '0' and cnt = N_CHUNKS-1) then
                    dn <= '1';                                        -- last chunk just landed
                end if;
            end if;
        end if;
    end process;
    acc  <= areg;
    done <= dn;
end architecture;