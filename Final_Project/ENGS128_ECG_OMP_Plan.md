# ENGS-128 — End-to-End ECG Compressed-Sensing Recovery on Zybo Z7-20
### Solo project plan, ~5 days. Critical path = on-board AXI integration.

**The honest framing:** Your OMP correlation engine is *done and proven in sim*. This project is
**not** an algorithm project — it's an integration project. The whole game is getting the validated
engine to run on the board over AXI, then wrapping it in the OMP outer loop (least-squares + residual
update in C on the Cortex-A9) so a compressed ECG window goes in and a reconstructed ECG window comes out.

**Headline deliverable:** original-vs-reconstructed ECG overlay (PRD target < 9%), recovered on the FPGA,
with an end-to-end speedup vs A9-only software.

**Fallback if AXI bring-up stalls:** hardware-in-the-loop (drive the AXI engine from a host script over
JTAG) or fall back to the 109-style sim+synthesis Pareto story. You always have a complete project — see Gates.

---

## GATES (things that stop the project if missing — clear these first)

1. **HDL-B's new wavelet `ψ` (256×256) + updated `D_q15` (128×256 int16).** Blocks Phase 1 PRD validation.
2. **One stored ECG window:** `y` (128 compressed measurements) + the original 256-sample signal `s`. Blocks Phases 1 & 4.
3. **Vivado + Digilent Zybo Z7-20 board files installed.** Blocks Phase 2. (Get board files from Digilent's vivado-boards repo.)
4. **Your engine available as source / packageable IP.** Blocks Phase 2.
5. **5 golden vectors converted to C arrays or `.mem`.** Blocks Phase 3.
6. **Board + USB-JTAG + a UART terminal that works.** Blocks Phase 3+.
7. **Solo-submission check:** the engine RTL is yours (you're HDL-A) — fine. Don't submit HDL-B's sim or
   SW's baseline as your own; re-derive the C loop fresh (the prompts below do this). Confirm your course's
   policy on building on prior-course work.
8. **Fill in your tool versions** (Vivado / Vitis or SDK) wherever the prompts say `[FILL IN]`.

---

## CONTEXT BLOCK  *(prepend this to every phase prompt below)*

> I'm building an end-to-end ECG compressed-sensing recovery system on a Digilent Zybo Z7-20
> (Zynq-7020, part `xc7z020clg400-1`) for a solo advanced-FPGA course project. Tools: Vivado `[FILL IN]`,
> Vitis/SDK `[FILL IN]`. I write VHDL.
>
> The accelerator is a **correlation engine**, already written and validated bit-exact in simulation
> against 5 golden vectors, but **not yet AXI-wrapped or run on the board**. It does ONE step of OMP:
> for each of N_ATOMS atoms, compute the integer inner product of the atom against the current residual
> in a 38-bit (Q8.30) accumulator, take the absolute value, return the argmax index. It is **stateless
> across OMP iterations** — the processor feeds it a residual and gets back one index per call.
>
> Frozen params: WINDOW_N=256, M_LEN=128 (measurements / atom length), N_ATOMS=256, I/O fixed-point Q1.15,
> 100 MHz, max 32 OMP iterations. NUM_MACS=32; MAC_BITS sweepable over {8,10,12,14,16} (internal
> truncation only — AXI always carries Q1.15). Datapath: 32 MACs × 4 chunks per atom + pipelined adder
> tree. Truncate-before-multiply: drop the (16−MAC_BITS) LSBs via arithmetic right shift (a bit-slice,
> floors toward −inf). Argmax tie-break: lowest index wins, via strict `>`.
>
> AXI4-Lite register map: `CTRL @0x00` (bit0 = START, self-clearing; bit1 = SOFT_RESET),
> `STATUS @0x04` (bit0 = DONE, bit1 = BUSY, bits[7:4] = VERSION = 0x1), `RESULT_IDX @0x10` (argmax index,
> valid when DONE=1), `RESULT_VAL @0x14` (debug: signed inner product). Dictionary `D` in BRAM `@0x1000+`
> (128×256 Q1.15, **atom-major**, two values per 32-bit word, even index in bits[15:0]). Residual `r` in
> BRAM `@0x11000+` (128 Q1.15, same packing, rewritten each iteration).
> Packing: `word = (int16(D[2i+1, j]) << 16) | (int16(D[2i, j]) & 0xFFFF)`.
>
> The **full OMP loop** (argmax → augment support set → least-squares solve → residual update → repeat
> up to 32×) runs in software on the Cortex-A9; the hardware only does the argmax. Recovered coefficients
> `â` map back to the signal via `s̃ = ψ·â`, where `ψ` is the (wavelet) sparsifying basis stored as a dense
> 256×256 matrix. `D = Φψ`, Φ = Bernoulli ±1 measurement matrix, M/N = 128/256.
> Reconstruction quality: PRD = 100·||s − s̃|| / ||s||; below 9% is "very good", below 5% "excellent".
>
> Prefer the simplest thing that works.

---

## PHASE 1 — Software end-to-end OMP reference  *(do this first; it's a fast win and de-risks the math + the wavelet switch)*

Independent of all hardware. Proves the recovery actually works and gives you a golden end-to-end oracle.

**Fresh-chat prompt:**
> [CONTEXT BLOCK]
>
> Write me two things. **(1) A clean Python implementation** of the full OMP recovery loop to use as my
> golden end-to-end reference. Inputs: `D_q15` (128×256 int16), `y` (128 measurements), `ψ` (256×256),
> `mac_bits`, max 32 iterations. The **argmax step must match my hardware exactly**: integer inner product
> in a 64-bit accumulator, truncate-before-multiply at `mac_bits`, abs, argmax with lowest-index tie-break.
> The least-squares solve and residual update run in float. After recovery, reconstruct `s̃ = ψ·â` and
> compute PRD against the original window. Run it on one stored ECG window and print PRD for mac_bits=16.
> **(2) The same loop in C**, bare-metal-friendly (no malloc, fixed-size arrays), with the argmax factored
> into a single function `int argmax_corr(...)` I can later swap for an AXI hardware call. Keep the LS solve
> simple — normal equations on the support set is fine for ≤32 atoms; no fancy Cholesky needed.

**Produces:** validated SW recovery + a C skeleton whose argmax I'll later replace with hardware.
**Gate:** need `ψ` + `D_q15` (wavelet) and one stored window first.

---

## PHASE 2 — AXI4-Lite wrapper + Vivado block design  *(THE LONG POLE — start it in parallel with Phase 1 if you can)*

**Fresh-chat prompt:**
> [CONTEXT BLOCK]
>
> Help me wrap my existing VHDL correlation engine as an **AXI4-Lite peripheral** matching the register map
> above, and build the **Vivado block design** for the Zybo Z7-20. I need: (1) the AXI4-Lite slave exposing
> CTRL / STATUS / RESULT_IDX / RESULT_VAL; (2) BRAM access so the PS can write `D` (@0x1000+) and `r`
> (@0x11000+) — advise whether to use an **AXI BRAM Controller + Block Memory Generator** vs. mapping
> through the AXI slave, given my engine reads D/r from BRAM internally and the START pulse triggers the
> FSM; (3) the block-design wiring (Zynq PS, my IP, the BRAM(s), AXI interconnect, clocking/reset); (4) how
> to package the IP and generate the bitstream. Give me the wrapper VHDL and, if possible, the Tcl to
> rebuild the block design. Flag any clock-domain or BRAM-port-width issues with my 32-bit-write /
> wide-read scheme.

**Produces:** a bitstream with the engine reachable from the PS.
**Gate:** Vivado + Zybo board files installed; engine packaged as IP.

---

## PHASE 3 — "Hardware is alive": one argmax on the board  *(the make-or-break integration milestone)*

**Fresh-chat prompt:**
> [CONTEXT BLOCK]
>
> Write a **bare-metal C program** for the Cortex-A9 (Vitis/SDK) that proves the on-board engine matches
> simulation on a single golden vector: read STATUS and assert VERSION==0x1; issue SOFT_RESET; load one
> golden vector's `D` into BRAM_D and `r` into BRAM_R using the exact §5 packing
> (`word = (int16(D[2i+1,j])<<16) | (int16(D[2i,j])&0xFFFF)`); pulse CTRL.START; poll STATUS.DONE with a
> 100 µs timeout; read RESULT_IDX; print it over UART and compare to the golden `expected_idx`. Include the
> register `#define`s and a helper to convert my golden-vector `.npz` into C arrays (or a `.mem`/`.coe`).

**Produces:** on-board engine confirmed bit-identical to sim. If this passes, the rest is "just software."
**Gate:** Phase 2 bitstream; golden vectors converted to C/.mem; UART working.

---

## PHASE 4 — Full on-board recovery  *(THE HEADLINE)*

**Fresh-chat prompt:**
> [CONTEXT BLOCK]
>
> Combine my Phase-1 C OMP loop with my Phase-3 AXI driver: **replace the software argmax with a hardware
> call** — each iteration, pack and write the current residual to BRAM_R, pulse START, poll DONE, read
> RESULT_IDX. Keep the least-squares solve and residual update in C on the A9. Run a full end-to-end
> recovery of one stored ECG window on the board, reconstruct `s̃ = ψ·â`, and print the reconstructed
> 256-sample window plus the PRD over UART. Also give me a **host-side Python script** that captures the
> UART dump and plots original vs. reconstructed on the same axes with the PRD in the title.

**Produces:** end-to-end on-board recovery + the overlay plot. This is the project.
**Gate:** Phases 1 + 3.

---

## PHASE 5 — Speedup + figures  *(the framing that makes it a "study", not a demo)*

**Fresh-chat prompt:**
> [CONTEXT BLOCK]
>
> Help me measure and frame the speedup honestly. (1) Time the hardware-accelerated OMP per window on the
> A9 using `XTime_GetTime` / the global timer. (2) Time a pure-software OMP on the A9 (argmax in C, no
> hardware) on the same window. (3) Compute end-to-end speedup and explain it with **Amdahl's law**: my
> correlation step is ~18× faster in isolation, but the un-accelerated LS+residual now dominates, so the
> end-to-end number is lower. Show me the Amdahl breakdown — given a correlation fraction `f` of software
> runtime, end-to-end speedup = `1 / ((1−f) + f/18)` — and a clean way to present "correlation-only vs
> end-to-end speedup" as a finding that *motivates future LS acceleration*. Then help me build poster
> figures: reconstruction overlay, PRD-vs-MAC_BITS (from the sweep), and a speedup bar.

**Produces:** real numbers + figures + an honest, sophisticated narrative.

---

## PHASE 6 — "Realtime" (STRETCH — only if Phases 1–5 land with time to spare)

### 6a — Pseudo-realtime, low risk (recommended stretch)
**Fresh-chat prompt:**
> [CONTEXT BLOCK]
>
> Build a pseudo-realtime demo: stream stored MIT-BIH windows one after another through the board,
> reconstruct each, and **live-plot original vs reconstructed on the host updating in real time**, with
> **heart rate per window** via a simple R-peak detector (bandpass-ish smoothing + adaptive threshold +
> refractory window → RR intervals → BPM). Show that HR computed from the reconstruction matches HR from
> the original — i.e., recovery preserved the clinically relevant feature. No analog hardware needed.

### 6b — Live ECG sensor, high risk (only if you're done and bored)
**Fresh-chat prompt:**
> [CONTEXT BLOCK]
>
> Help me bring a live **AD8232** single-lead ECG front end into the Zynq via the **XADC**: XADC config for
> the Zybo Z7-20 XADC Pmod, analog scaling from the AD8232 output into the XADC's input range, buffering
> 256 samples at ~250–500 Hz, then **simulate compression** (`y = Φs`) and run the recovery + R-peak HR as
> in 6a. Important framing for me: I'm sampling at full rate and *then* simulating CS compression (I'm not
> physically undersampling) — call out the conceptual caveats so I present this correctly on the poster.

**Gate:** everything else done + time; (6b) also needs the sensor, wiring, and patience for analog noise.

---

## Suggested day-by-day (compress if you have fewer days)

- ~~**Day 1:** Clear gates. Phase 1 (software recovery working, PRD validated on wavelet). Kick off Phase 2.~~
- ~~**Day 2:** Phase 2 — AXI wrapper + block design + bitstream.~~
- **Day 3:** Phase 3 — one argmax on the board matching a golden vector. *(If this slips, switch to the hardware-in-the-loop fallback so the poster is still safe.)*
- **Day 4:** Phase 4 — full on-board recovery + overlay plot. Phase 5 — speedup + figures.
- **Day 5:** Buffer / polish / write-up. Phase 6a only if everything's solid.

**The one rule:** protect Phases 1–4. Everything else is gravy. Decide on Day 1 that the on-board
end-to-end recovery is the committed deliverable and the live sensor is a maybe — so you don't burn the
last night chasing electrodes instead of finishing the plot.
