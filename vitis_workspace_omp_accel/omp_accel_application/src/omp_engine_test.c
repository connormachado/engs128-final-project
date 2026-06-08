///*
// * omp_engine_test.c  —  Phase 3 "hardware is alive"
// *
// * Proves the on-board correlation engine matches simulation on ONE golden vector.
// * Bare-metal Cortex-A9 (Vitis/SDK), Zybo Z7-20.
// *
// * Flow:
// *   1. Read STATUS, assert VERSION == 0x1.
// *   2. SOFT_RESET.
// *   3. Load D into BRAM_D, r into BRAM_R using the exact §5/§7 packing.
// *   4. Pulse CTRL.START.
// *   5. Poll STATUS.DONE with a ~100 us timeout (fatal if it trips).
// *   6. Read RESULT_IDX, print over UART, compare to golden expected_idx.
// *
// * Drop golden_vector.h (from npz_to_c.py) next to this file.
// *
// * The engine is the single source of truth for layout; this driver just feeds
// * it bytes in the order it already reads them in sim. Think of BRAM as a parking
// * garage the engine walks in a fixed route — we only have to park each car in
// * the slot the engine will look in.
// */
//
//#include <stdio.h>
//#include "xil_printf.h"
//#include "xil_io.h"
//#include "xparameters.h"
//#include "xtime_l.h"          /* COUNTS_PER_SECOND, XTime_GetTime */
//#include "golden_vector.h"    /* GV_D[N_ATOMS][M_LEN], GV_R[M_LEN], GV_EXPECTED_IDX */
//
///* ------------------------------------------------------------------ */
///* Frozen dimensions (must match the RTL generics).                    */
///* ------------------------------------------------------------------ */
//#define M_LEN     128         /* atom length / # measurements          */
//#define N_ATOMS   256         /* # dictionary columns                  */
//
///* ------------------------------------------------------------------ */
///* Base address. Set this from your Vivado address editor.             */
///* If you wrapped the engine as a single AXI4-Lite IP, use its         */
///* XPAR_*_S00_AXI_BASEADDR. If you used a separate AXI BRAM Controller  */
///* for D/r, set ENGINE_BASE to the register block and override         */
///* BRAM_D_ABS / BRAM_R_ABS below with the BRAM controller base.        */
///* ------------------------------------------------------------------ */
//#ifndef ENGINE_BASE
//#define ENGINE_BASE   XPAR_AXI_OMP_CORR_0_BASEADDR
//#endif
//
///* Register offsets (AXI4-Lite map, §6) */
//#define REG_CTRL        0x0000u    /* bit0=START (self-clearing), bit1=SOFT_RESET */
//#define REG_STATUS      0x0004u    /* bit0=DONE, bit1=BUSY, bits[7:4]=VERSION      */
//#define REG_RESULT_IDX  0x0010u    /* argmax 0..255, valid when DONE=1            */
//#define REG_RESULT_VAL  0x0014u    /* debug only                                  */
//#define BRAM_D_OFFSET   0x1000u    /* dictionary D base                           */
//#define BRAM_R_OFFSET   0x11000u   /* residual r base                             */
//
///* CTRL bits */
//#define CTRL_START      (1u << 0)
//#define CTRL_SOFT_RESET (1u << 1)
//
///* STATUS bits */
//#define STATUS_DONE     (1u << 0)
//#define STATUS_BUSY     (1u << 1)
//#define STATUS_VER_MASK 0x000000F0u
//#define STATUS_VER_SHIFT 4
//#define EXPECTED_VERSION 0x1u
//
///* If D and r live behind a separate AXI BRAM Controller rather than    */
///* inside the engine's AXI-Lite aperture, define these to that          */
///* controller's base + a per-port offset and they'll override.          */
//#ifndef BRAM_D_ABS
//#define BRAM_D_ABS  ((u32)(ENGINE_BASE + BRAM_D_OFFSET))
//#endif
//#ifndef BRAM_R_ABS
//#define BRAM_R_ABS  ((u32)(ENGINE_BASE + BRAM_R_OFFSET))
//#endif
//
///* Timeout. 100 us at the A9 is plenty over the ~10.3 us engine latency. */
//#define DONE_TIMEOUT_US   100u
//
///* ------------------------------------------------------------------ */
///* Register helpers                                                    */
///* ------------------------------------------------------------------ */
//static inline void reg_write(u32 off, u32 val) {
//    Xil_Out32((UINTPTR)ENGINE_BASE + off, val);
//}
//static inline u32 reg_read(u32 off) {
//    return Xil_In32((UINTPTR)ENGINE_BASE + off);
//}
//
///* ------------------------------------------------------------------ */
///* §7 packing: two Q1.15 values per 32-bit word.                       */
///*   word = (int16(col[2i+1]) << 16) | (int16(col[2i]) & 0xFFFF)       */
///* even index -> bits[15:0], odd index -> bits[31:16].                 */
///* col[] is one atom (M_LEN entries) for D, or the residual for r.     */
///* ------------------------------------------------------------------ */
//static inline u32 pack_pair(s16 even, s16 odd) {
//    return (((u32)(u16)odd) << 16) | ((u32)(u16)even & 0x0000FFFFu);
//}
//
///*
// * Load the whole dictionary, atom-major. Atom j occupies M_LEN/2 = 64
// * consecutive words starting at word index j*64. This is exactly the
// * route the engine walks: one full atom contiguously, base + offset,
// * no stride logic.
// */
//static void load_dictionary(void) {
//    const u32 words_per_atom = M_LEN / 2;          /* 64 */
//    for (u32 j = 0; j < N_ATOMS; ++j) {
//        u32 atom_base = BRAM_D_ABS + (j * words_per_atom) * 4u;
//        for (u32 i = 0; i < words_per_atom; ++i) { /* i = half-row 0..63 */
//            s16 even = (s16)GV_D[j][2u * i];
//            s16 odd  = (s16)GV_D[j][2u * i + 1u];
//            Xil_Out32((UINTPTR)(atom_base + i * 4u), pack_pair(even, odd));
//        }
//    }
//}
//
///* Load the residual: M_LEN Q1.15 entries -> M_LEN/2 = 64 words. */
//static void load_residual(const s16 *r) {
//    const u32 words = M_LEN / 2;                   /* 64 */
//    for (u32 i = 0; i < words; ++i) {
//        Xil_Out32((UINTPTR)(BRAM_R_ABS + i * 4u),
//                  pack_pair(r[2u * i], r[2u * i + 1u]));
//    }
//}
//
///* ------------------------------------------------------------------ */
///* Poll DONE with a wall-clock timeout. Returns 0 on success, -1 on    */
///* timeout. Uses the A9 global timer so it's independent of loop count.*/
///* ------------------------------------------------------------------ */
//static int wait_done(u32 timeout_us) {
//    XTime t0, now;
//    XTime_GetTime(&t0);
//    const XTime ticks = (COUNTS_PER_SECOND / 1000000u) * timeout_us;
//    for (;;) {
//        if (reg_read(REG_STATUS) & STATUS_DONE) return 0;
//        XTime_GetTime(&now);
//        if ((now - t0) >= ticks) return -1;
//    }
//}
//
///* ------------------------------------------------------------------ */
//int main(void) {
//    xil_printf("\r\n=== OMP correlation engine — Phase 3 board bring-up ===\r\n");
//
//    /* 1. Version check. */
//    u32 status = reg_read(REG_STATUS);
//    u32 ver = (status & STATUS_VER_MASK) >> STATUS_VER_SHIFT;
//    xil_printf("STATUS = 0x%08x  (VERSION=0x%x, DONE=%d, BUSY=%d)\r\n",
//               status, ver, (int)(status & STATUS_DONE),
//               (int)((status & STATUS_BUSY) >> 1));
//    if (ver != EXPECTED_VERSION) {
//        xil_printf("FAIL: VERSION 0x%x != expected 0x%x. "
//                   "Wrong bitstream or wrong base address.\r\n",
//                   ver, EXPECTED_VERSION);
//        return 1;
//    }
//
//    /* 2. SOFT_RESET, then clear (do not leave reset asserted). */
//    reg_write(REG_CTRL, CTRL_SOFT_RESET);
//    reg_write(REG_CTRL, 0u);
//
//    /* 3. Load D and r with the exact §7 packing. */
//    xil_printf("Loading D (%d atoms x %d) and r (%d) into BRAM...\r\n",
//               N_ATOMS, M_LEN, M_LEN);
//    load_dictionary();
//    load_residual(GV_R);
//
//    /* Never write START while BUSY. */
//    if (reg_read(REG_STATUS) & STATUS_BUSY) {
//        xil_printf("FAIL: engine BUSY before START — logic/sequencing bug.\r\n");
//        return 1;
//    }
//
//    /* 4. Pulse START (self-clearing in HW; we don't need to clear it). */
//    reg_write(REG_CTRL, CTRL_START);
//
//    /* 5. Poll DONE with timeout. */
//    if (wait_done(DONE_TIMEOUT_US) != 0) {
//        xil_printf("FAIL: DONE timeout after %u us. STATUS=0x%08x. "
//                   "Engine never finished — fatal.\r\n",
//                   DONE_TIMEOUT_US, reg_read(REG_STATUS));
//        return 1;
//    }
//
//    /* 6. Read result, compare to golden. */
//    u32 idx = reg_read(REG_RESULT_IDX);
//    s32 val = (s32)reg_read(REG_RESULT_VAL);   /* debug only */
//    xil_printf("RESULT_IDX = %u   (RESULT_VAL = %d, debug)\r\n",
//               idx, val);
//    xil_printf("expected   = %u\r\n", (u32)GV_EXPECTED_IDX);
//
//    if (idx == (u32)GV_EXPECTED_IDX) {
//        xil_printf(">>> PASS: on-board engine matches simulation. "
//                   "Hardware is alive.\r\n");
//        return 0;
//    } else {
//        xil_printf(">>> FAIL: idx %u != expected %u.\r\n",
//                   idx, (u32)GV_EXPECTED_IDX);
//        return 1;
//    }
//}
//
