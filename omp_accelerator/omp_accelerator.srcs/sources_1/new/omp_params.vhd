--------------------------------------------------------------------------------
-- omp_params.vhd
--
-- Canonical constants for the OMP correlation engine (HDL-A).
-- Mirrors the frozen §2 parameters and the §3 negotiable defaults from the
-- OMP Team Interface Contract v1.0. Nothing else in the design should hard-code
-- any of these numbers; reference them from here.
--
-- If this file and the contract table ever disagree, the contract is right and
-- this file is the bug (contract §2). A §2 change requires a §10 team re-sync.
--
-- Naming convention used here:
--   * Frozen §2 values are plain constants (WINDOW_N, M_LEN, ...).
--   * §3 negotiable values are named DEFAULT_* and are intended to be the
--     defaults for entity generics, e.g.
--         generic ( MAC_BITS : positive := omp_params.DEFAULT_MAC_BITS );
--     The package only holds the default; the per-build sweep value is set by
--     the generic so the package never has to be edited to sweep MAC_BITS.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package omp_params is

  ------------------------------------------------------------------------------
  -- ceil(log2(n)) -- pure, synthesizable; used for index/address widths below.
  ------------------------------------------------------------------------------
  function clog2 (n : positive) return natural;

  ------------------------------------------------------------------------------
  -- §2  Frozen system parameters  (do NOT edit without a §10 re-sync)
  ------------------------------------------------------------------------------
  constant WINDOW_N      : positive := 256;          -- samples per window (N)
  constant M_LEN         : positive := 128;          -- atom length / # measurements (M)
  constant N_ATOMS       : positive := 256;          -- number of dictionary atoms
  constant IO_INT_BITS   : positive := 1;            -- Q1.15 integer bits
  constant IO_FRAC_BITS  : positive := 15;           -- Q1.15 fractional bits
  constant CLK_HZ        : positive := 100_000_000;  -- 100 MHz system clock

  -- Reference only: HW is stateless across OMP iterations (SW enforces the cap).
  -- Included for §2 completeness; no logic in HDL-A should use it.
  constant MAX_OMP_ITERS : positive := 32;

  ------------------------------------------------------------------------------
  -- §3  Negotiable defaults  (override per-build via entity generics)
  ------------------------------------------------------------------------------
  constant DEFAULT_ACC_INT_BITS   : positive := 8;   -- internal accumulator Q8.30
  constant DEFAULT_ACC_FRAC_BITS  : positive := 30;  --   -> 38-bit signed
  constant DEFAULT_MAC_PIPE_DEPTH : positive := 4;   -- MAC pipeline stages
  constant DEFAULT_NUM_MACS       : positive := 32;  -- parallel MAC lanes
  constant DEFAULT_MAC_BITS       : positive := 16;  -- SWEEP VARIABLE {8,10,12,14,16}
  constant DEFAULT_BRAM_RD_LAT    : natural  := 1;   -- BRAM read latency (cycles)

  ------------------------------------------------------------------------------
  -- Derived widths / sizes  (computed -- never hand-edit)
  ------------------------------------------------------------------------------
  constant IO_WIDTH         : positive := IO_INT_BITS + IO_FRAC_BITS;                 -- 16
  constant ACC_WIDTH        : positive := DEFAULT_ACC_INT_BITS + DEFAULT_ACC_FRAC_BITS; -- 38
  constant D_ENTRIES        : positive := M_LEN * N_ATOMS;                            -- 32768
  constant R_ENTRIES        : positive := M_LEN;                                      -- 128
  constant ATOM_IDX_WIDTH   : positive := clog2(N_ATOMS);                             -- 8  (0..255)
  constant SAMPLE_IDX_WIDTH : positive := clog2(M_LEN);                               -- 7  (0..127)

  ------------------------------------------------------------------------------
  -- Convenience subtypes -- keep bit widths out of the RTL body.
  -- NOTE: accumulator_t is tied to the DEFAULT accumulator width. The accumulator
  -- is not the sweep knob (MAC_BITS is), so a fixed subtype is fine. If you ever
  -- make accumulator width a generic, build that vector from the generic instead.
  ------------------------------------------------------------------------------
  subtype io_sample_t   is signed(IO_WIDTH  - 1 downto 0);  -- one Q1.15 value
  subtype accumulator_t is signed(ACC_WIDTH - 1 downto 0);  -- Q8.30 inner-product acc

end package omp_params;

package body omp_params is

  function clog2 (n : positive) return natural is
    variable result : natural  := 0;
    variable value  : positive := 1;
  begin
    -- smallest k such that 2**k >= n  (clog2(1) = 0)
    while value < n loop
      value  := value * 2;
      result := result + 1;
    end loop;
    return result;
  end function clog2;

end package body omp_params;