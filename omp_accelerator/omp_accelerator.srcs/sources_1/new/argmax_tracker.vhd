----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 05/30/2026 02:45:41 PM
-- Design Name: 
-- Module Name: argmax_tracker - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.NUMERIC_STD.ALL;

----------------------------------------------------------------------------------
entity argmax_tracker is
    Port (
        -- Clock
        clk_i : in std_logic;
        
        ---- Data
        -- In
        score_i : in signed(37 downto 0);       
        j_i : in std_logic_vector(7 downto 0);
        
        -- Out
        best_idx : out std_logic_vector(7 downto 0);
        best_score : out signed(37 downto 0);           -- RETURNS THE MAGNITUDE OF THE BEST_SCORE
                                                        -- AS WE INTERNALLY ABS()
        
        -- Control
        valid_i : in std_logic;
        clear_i : in std_logic
        );
end argmax_tracker;
----------------------------------------------------------------------------------

----------------------------------------------------------------------------------
architecture Behavioral of argmax_tracker is
----------------------------------------------------------------------------------
-- Signals
----------------------------------------------------------------------------------
    -- Score Register
    signal max_score : signed(37 downto 0) := (others => '0');
    
    -- j Register
    signal best_j   : std_logic_vector(7 downto 0) := (others => '0');
----------------------------------------------------------------------------------
-- Components
----------------------------------------------------------------------------------


----------------------------------------------------------------------------------
begin
    
    -- Update everything within a single process
    process(clk_i)
        variable score_abs : signed(37 downto 0);
    begin
        if rising_edge(clk_i) then
            if clear_i = '1' then
                max_score <= (others => '0');   -- reset value
                best_j    <= (others => '0');
            elsif valid_i = '1' then
                score_abs := abs(score_i);
                if score_abs > max_score then      -- strict '>' keeps lowest index on ties
                    max_score <= score_abs;
                    best_j    <= j_i;
                end if;
            end if;
        end if;
    end process;

    -- Output Logic
    best_score <= max_score;
    best_idx <= best_j;

end Behavioral;


