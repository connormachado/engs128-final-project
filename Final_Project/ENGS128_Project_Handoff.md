# ENGS-128 Project Handoff — End-to-End ECG Compressed-Sensing Recovery (Zybo Z7-20)

> **For the assistant picking this up:** This is the seed/context document for a fresh Claude
> Project. You are joining an in-progress, solo, advanced-FPGA project. Everything you need is
> below — do not assume any prior conversation. The owner writes VHDL, prefers the simplest thing
> that works, and finds analogies helpful when learning new concepts. When the owner asks for help
> with a phase, you can generate the RTL / C / Python / Tcl directly.

---

## 1. What this project is

A solo course project ("advanced FPGA, no constraints"), due within the week. The goal is an
**end-to-end ECG compressed-sensing recovery system** on a **Digilent Zybo Z7-20** (Zynq-7020 SoC,
part `xc7z020clg400-1`): a compressed ECG window goes in, a reconstructed ECG window comes out, run
on the FPGA, with a speedup measured against an ARM-software baseline.

It is a **pivot** from an earlier project. The owner already built and validated (in simulation) an
OMP **correlation engine** — the search step of the Orthogonal Matching Pursuit algorithm. This
project reuses that engine as the hardware accelerator and builds the *rest of the system* around it:
on-board integration over AXI, plus the OMP outer loop in software on the Cortex-A9.

**Mental model:** the correlation engine is a fast, specialized "search station." A complete OMP
recovery still needs the rest of the line — the least-squares solve and residual update — which run
in software on the ARM core. This is a heterogeneous PS+PL system, not an all-in-hardware design.

---

## 2. Background: compressed sensing + OMP (just enough)

- Compressed sensing acquires `M < N` linear measurements `y = Φs` of a signal `s` that is sparse in
  some basis `ψ`. Here `N = 256`, `M = 128` (M/N = 0.5), `Φ` is a Bernoulli ±1 matrix.
- ECG is approximately sparse in transform domains. The effective dictionary is `D = Φψ` (128×256).
- **OMP** recovers the sparse coefficient vector `â` iteratively:
  1. **argmax** — find the atom (column of `D`) most correlated with the current residual `r`.  ← *this is the hardware*
  2. add that atom's index to the support set,
  3. **least-squares solve** for the coefficients over the chosen atoms,
  4. **update the residual** `r`,
  5. repeat up to the sparsity limit (≤ 32 iterations here).
- The recovered signal is `s̃ = ψ·â`. Quality metric: **PRD = 100·||s − s̃|| / ||s||**;
  below 9% is "very good", below 5% "excellent".
- Validation data: MIT-BIH ECG Compression Test Database, segmented into 256-sample windows.

**Note on the sparsifying basis:** the project is switching `ψ` from a DCT basis to a **wavelet
basis** (DCT recovery was giving ~58% PRD, which is bad; wavelets suit ECG's sharp QRS transients
far better). **This change does not touch the hardware at all** — the engine just computes inner
products of whatever numbers are in memory; a new basis only changes the contents of `D`. The only
place the basis appears in the owner's own work is the inverse transform in software, handled simply
by storing `ψ` as a dense 256×256 matrix and computing `s̃ = ψ·â` as a matrix-vector product
(basis-agnostic).

---

## 3. The correlation engine — what the hardware does

For each of `N_ATOMS = 256` atoms, the engine computes the **integer inner product** of that atom
against the current residual `r` in a 38-bit (Q8.30) accumulator, takes the **absolute value**, and
returns the **argmax index** across all atoms in `RESULT_IDX`. That is its entire job — one OMP
search step.

Key behaviors (all validated bit-exact in simulation):

- **Stateless across OMP iterations.** It does not loop internally. The processor writes a residual,
  pulses START, gets back one index, then does the LS solve + residual update itself and calls again.
  Software enforces the ≤ 32-iteration cap.
- **Datapath:** 32 parallel MACs × 4 chunks (`ceil(128/32)`) per atom, feeding a pipelined adder tree.
- **Truncate-before-multiply:** before multiplying, drop the `(16 − MAC_BITS)` least-significant bits
  of each Q1.15 input via arithmetic right shift. This is a **bit-slice** of the top `MAC_BITS` bits
  (not a shifter), and it floors toward −∞ (differs from truncate-toward-zero on odd negatives). The
  bit-slice is correct by construction — do **not** reimplement as take-magnitude / shift / re-sign.
- **Argmax / tie-break:** lowest index wins, implemented with a **strict `>`** compare so equal values
  never overwrite the running max (matches `np.argmax`). Guard the `abs()` of the most-negative 38-bit
  accumulator value (two's-complement overflow).
- **Abs is internal:** the argmax tracker takes the raw signed `(37:0)` accumulator value, computes the
  magnitude once, uses it for both the strict-`>` compare and the stored running max, and outputs the
  magnitude as `best_score`. (The raw signed value is available internally if `RESULT_VAL` ever needs it.)
- **FSM:** `IDLE → COMPUTE → FINISH`. IDLE waits for START (ignores START while BUSY). COMPUTE iterates
  the 256 atoms through the MAC tree and updates the running argmax. FINISH latches DONE with
  RESULT_IDX/RESULT_VAL stable until the next START or SOFT_RESET.
- **Analytical latency:** ≈ `N_ATOMS × ceil(M_LEN/NUM_MACS) + pipeline + drain` ≈ 256×4 ≈ ~1024+
  cycles ≈ ~10.3 µs at 100 MHz, roughly constant across MAC_BITS.

---

## 4. Frozen system parameters

| Parameter | Value | Generic name | Notes |
|---|---|---|---|
| Window size N | 256 | `WINDOW_N` | signal/window length |
| Measurements / atom length M | 128 | `M_LEN` | rows of D |
| Number of atoms | 256 | `N_ATOMS` | columns of D |
| Max OMP iterations | 32 | (software only) | hardware is stateless; SW enforces |
| I/O fixed-point | Q1.15 | `IO_INT_BITS=1, IO_FRAC_BITS=15` | AXI always carries Q1.15 |
| Clock | 100 MHz | `CLK_HZ` | |
| Part | `xc7z020clg400-1` | — | Zybo Z7-20 |

## 5. Tunable / swept parameters (owner's call; interface unaffected)

| Parameter | Default | Notes |
|---|---|---|
| Internal accumulator | Q8.30 (38-bit signed) | **Do not narrow** — Q2.30 overflows at M=128 |
| MAC pipeline depth | ~4 stages | latency only, not interface |
| Parallel MACs `NUM_MACS` | 32 | |
| `MAC_BITS` (the sweep knob) | 16 baseline; sweep {8,10,12,14,16} | controls internal truncation only; AXI stays Q1.15 |
| BRAM read latency | 1 cycle | primitive default |

`MAC_BITS` is the independent variable for the resource/accuracy study: synthesize at each value to get
resource cost, and (separately, in software simulation) measure PRD at each value.

---

## 6. AXI4-Lite register map (the engine's software interface)

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | `CTRL` | R/W | bit0 = START (write 1, self-clears in 1 cycle); bit1 = SOFT_RESET; other bits reserved/0 |
| 0x04 | `STATUS` | R | bit0 = DONE; bit1 = BUSY; bits[7:4] = VERSION (= 0x1) |
| 0x10 | `RESULT_IDX` | R | argmax index 0..255, zero-extended to 32 bits; valid only when DONE=1 |
| 0x14 | `RESULT_VAL` | R | signed inner-product at argmax (debug only; SW does not use it) |
| 0x1000+ | `BRAM_D` | W | dictionary D, 32K AXI words (128 KB), atom-major (see §7) |
| 0x11000+ | `BRAM_R` | W | residual r, 64 AXI words (256 B), rewritten each iteration |

Sequencing rules: never write START while BUSY=1 (hardware ignores it, but it signals a logic bug);
never read RESULT_IDX before DONE=1; treat a DONE timeout (~100 µs) as fatal.

**OPEN ITEM:** `RESULT_VAL` is debug-only; whether it carries the top-32 or low-32 bits of the 38-bit
accumulator was never finalized. Assume **top-32** unless decided otherwise. It does not affect
recovery correctness.

---

## 7. BRAM data layout + packing

- **Dictionary D** at `0x1000+`: shape 128×256 Q1.15, **atom-major** — atom 0's 128 entries occupy the
  first 64 AXI words, then atom 1, etc. Within a 32-bit word, the even-indexed value (entry 0,2,…) is in
  bits [15:0]; the odd-indexed value is in bits [31:16].
- **Residual r** at `0x11000+`: 128 Q1.15 entries in 64 AXI words, same packing, rewritten every iteration.
- **Packing rule (exact):**
  `word = (int16(D[2i+1, j]) << 16) | (int16(D[2i, j]) & 0xFFFF)`
  where `j` = atom index, `i` = half-row index 0..63. On a little-endian host,
  `D_q15.astype(np.int16).tobytes()` gives the right byte order.
- Atom-major is deliberate: the engine reads one full atom contiguously per inner product, so addressing
  is base + offset with no stride logic.

---

## 8. What runs in hardware vs. software

| Stage | Where | Status |
|---|---|---|
| Argmax / correlation search | **PL (the engine)** | done, sim-validated |
| Support-set tracking | PS (Cortex-A9, C) | to write |
| Least-squares solve | PS (C) | to write — normal equations on the support set is fine for ≤32 atoms; **do NOT build a Cholesky inversion unit in hardware** |
| Residual update | PS (C) | to write |
| Inverse transform `s̃ = ψ·â` | PS (C) | to write — dense 256×256 matvec |
| R-peak / heart-rate (stretch) | PS or host | optional |

---

## 9. Current state (where we are)

- **Done:** correlation-engine RTL (VHDL), validated **bit-exact in simulation** against 5 golden
  vectors (easy-margin, tight ~0.002% margin, winner near index 0, winner near index N−1, engineered
  tie). The reported **~18× speedup is simulation/analytical only** — the engine has **never run on the
  board**.
- **Not done:** AXI4-Lite wrapper, Vivado block design, bitstream, any on-board execution, the OMP outer
  loop in C, the inverse transform, end-to-end recovery, speedup measurement, figures.

**The critical path is on-board AXI integration**, not the algorithm. The single biggest milestone is
the first time `RESULT_IDX` comes back over UART matching a golden vector — after that, the remaining
work is mostly C.

**Provenance / academic-integrity note:** the engine RTL is the owner's own work. The golden vectors and
the original Python fixed-point simulator came from a teammate on the prior team project; for this solo
submission the owner should re-derive the software (the OMP loop, driver, and reference) fresh rather
than submit teammates' code, and should confirm the course's policy on building on prior-course work.

---

## 10. Roadmap (condensed — detailed per-phase prompts exist in a companion plan file)

1. **Phase 1 — Software end-to-end OMP reference.** Python (golden oracle) + a C skeleton with the
   argmax factored into one swappable function. Validates the wavelet recovery + PRD. *Fast win, no
   hardware needed.*
2. **Phase 2 — AXI4-Lite wrapper + Vivado block design + bitstream.** *The long pole.*
3. **Phase 3 — Bare-metal "hardware is alive": one argmax on the board matching a golden vector.**
   *Make-or-break integration milestone.*
4. **Phase 4 — Full on-board recovery:** swap the software argmax for the hardware call; reconstruct a
   stored window end-to-end; overlay plot + PRD. *The headline.*
5. **Phase 5 — Speedup + figures.** Measure HW vs A9-software OMP. Expect end-to-end speedup *well below*
   18× because the un-accelerated LS+residual now dominates — frame this with **Amdahl's law**
   (`speedup = 1 / ((1−f) + f/18)` for correlation fraction `f`) as a finding that motivates future LS
   acceleration.
6. **Phase 6 — "Realtime" (stretch).** Preferred: stream stored windows with a live host plot + per-window
   heart rate (R-peak detection), showing HR-from-reconstruction matches HR-from-original. High-risk
   alternative: live AD8232 sensor via the Zynq XADC (sample full-rate, *simulate* compression, recover).

**Fallback if AXI bring-up stalls:** hardware-in-the-loop (drive the AXI engine from a host script over
JTAG) or a simulation+synthesis Pareto story — so the project is always complete.

---

## 11. Gates / blockers to clear

1. Wavelet `ψ` (256×256) + updated `D_q15` (128×256 int16) available.
2. One stored ECG window: `y` (128 measurements) + original 256-sample `s`, for PRD.
3. Vivado + Digilent Zybo Z7-20 board files installed.
4. The engine source available / packageable as IP.
5. The 5 golden vectors converted to C arrays or `.mem`/`.coe`.
6. Board + USB-JTAG + a working UART terminal.
7. Tool versions noted (Vivado ___ , Vitis/SDK ___).

---

## 12. Hard rules / do-nots

- **Do not** put the least-squares solve / matrix inversion in hardware. It stays in C on the A9.
- **Do not** narrow the Q8.30 accumulator (overflows at M=128).
- **Do not** reimplement truncate-before-multiply as magnitude/shift/re-sign — keep the bit-slice.
- The engine is **stateless** per call; the OMP loop lives in software.
- The basis switch (DCT→wavelet) does **not** change any RTL — only the contents of `D` and the
  software inverse transform.
- AXI always carries Q1.15; `MAC_BITS` affects internal truncation only.
