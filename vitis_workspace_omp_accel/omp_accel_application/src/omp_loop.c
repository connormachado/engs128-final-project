/*
 * ENGS-128 Phase 4 — Full on-board ECG compressed-sensing recovery.
 *
 * Combines the Phase-1 C OMP loop with the Phase-3 AXI driver: each OMP
 * iteration packs the current residual into BRAM_R, pulses START, polls DONE,
 * reads RESULT_IDX. The least-squares solve and residual update stay in C on
 * the Cortex-A9. After recovery, reconstructs s_tilde = psi * a_hat, computes
 * PRD, and dumps the 256-sample reconstruction over UART for the host plotter.
 *
 * Build: bare-metal Vitis/SDK app, standalone BSP, UART (PS-side) as stdout.
 *
 * Mental model: the FPGA is a fast "search clerk". You slide a residual across
 * the counter (BRAM_R), ring the bell (START), wait for "found it" (DONE), and
 * it hands you back ONE index — the atom most correlated with that residual.
 * Everything else about running the OMP errand (which atoms you've collected,
 * solving for their weights, subtracting them off) you do yourself in C.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"   /* usleep for the timeout loop */
#include "lwip/init.h"
#include "lwip/udp.h"
#include "lwip/pbuf.h"


#include "netif/xadapter.h"
#include "platform.h"
#include "platform_config.h"
#include "lwip/tcp.h"
#include "xil_cache.h"

/* ------------------------------------------------------------------ *
 *  Problem dimensions (frozen params)
 * ------------------------------------------------------------------ */
#define WINDOW_N    256          /* signal / window length            */
#define M_LEN       128          /* measurements = atom length        */
#define N_ATOMS     256          /* columns of D                      */
#define MAX_ITERS   32           /* OMP sparsity cap (SW-enforced)     */

/* ------------------------------------------------------------------ *
 *  AXI base + register map.  Set ENGINE_BASE to your peripheral's
 *  base address from xparameters.h (e.g. XPAR_OMP_CORR_0_S_AXI_BASEADDR).
 * ------------------------------------------------------------------ */
#ifndef ENGINE_BASE
#define ENGINE_BASE   XPAR_AXI_OMP_CORR_0_BASEADDR
#endif

#define REG_CTRL        0x00     /* bit0 START (self-clear), bit1 SOFT_RESET */
#define REG_STATUS      0x04     /* bit0 DONE, bit1 BUSY, [7:4] VERSION       */
#define REG_RESULT_IDX  0x10     /* argmax 0..255, valid when DONE=1          */
#define REG_RESULT_VAL  0x14     /* debug only                                */
#define BRAM_D_OFFSET   0x1000   /* dictionary D, atom-major                  */
#define BRAM_R_OFFSET   0x11000  /* residual r, rewritten each iteration      */

#define CTRL_START      0x1
#define CTRL_SOFT_RST   0x2
#define STATUS_DONE     0x1
#define STATUS_BUSY     0x2
#define STATUS_VER_MASK 0xF0
#define STATUS_VER_SHFT 4
#define EXPECTED_VER    0x1

#define DONE_TIMEOUT_US 100      /* ~100 us; treat as fatal                   */

#define REG_RD(off)        Xil_In32 (ENGINE_BASE + (off))
#define REG_WR(off, val)   Xil_Out32(ENGINE_BASE + (off), (u32)(val))


/* ------------------------------------------------------------------ *
 *  Defines for the UDP ethernet functions
 * ------------------------------------------------------------------ */
#define DEST_IP_0  192
#define DEST_IP_1  168
#define DEST_IP_2  17
#define DEST_IP_3  50
#define DEST_PORT  5005

static struct udp_pcb *stream_pcb;

struct netif server_netif;
struct netif *echo_netif;


/* ------------------------------------------------------------------ *
 *  Struct we send over ethernet to plot real time windows
 * ------------------------------------------------------------------ */
#pragma pack(push, 1)
typedef struct {
    uint8_t  window_id;
    uint8_t  iter_idx;
    uint8_t  total_iters;
    uint8_t  flags;
    int16_t  samples[256];
    int16_t  original[256];
    float    prd;
} ecg_frame_t;
#pragma pack(pop)

/* ------------------------------------------------------------------ *
 *  Q1.15 fixed-point I/O helpers (AXI always carries Q1.15)
 * ------------------------------------------------------------------ */
#define Q15_ONE   32768.0f
#define CLAMP16(x) ((x) >  32767 ?  32767 : ((x) < -32768 ? -32768 : (x)))

static inline int16_t f_to_q15(float x) {
    int v = (int)lrintf(x * Q15_ONE);
    return (int16_t)CLAMP16(v);
}
static inline float q15_to_f(int16_t q) {
    return (float)q / Q15_ONE;
}


/* ------------------------------------------------------------------ *
 *  UDP streaming code
 * ------------------------------------------------------------------ */
void udp_stream_init(void) {
    stream_pcb = udp_new();
}

void udp_stream_send(const void *data, u16_t len) {
    struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, len, PBUF_RAM);
    if (p == NULL) { xil_printf("pbuf_alloc failed\r\n"); return; }
    memcpy(p->payload, data, len);
    ip_addr_t dest;
    IP4_ADDR(&dest, DEST_IP_0, DEST_IP_1, DEST_IP_2, DEST_IP_3);
    err_t e = udp_sendto(stream_pcb, p, &dest, DEST_PORT);
    if (e != ERR_OK) xil_printf("udp_sendto error: %d\r\n", e);
    else             xil_printf("sent %d bytes\r\n", len);
    pbuf_free(p);
}


void send_ecg_frame(const float *recon, const float *orig, float prd_val,
                    uint8_t win_id, uint8_t iter_idx, uint8_t total_iters,
                    uint8_t flags) {
    ecg_frame_t frame;
    frame.window_id   = win_id;
    frame.iter_idx    = iter_idx;
    frame.total_iters = total_iters;
    frame.flags       = flags;
    for (int i = 0; i < 256; i++) {
        float v = recon[i] * 32768.0f;
        if (v >  32767.0f) v =  32767.0f;
        if (v < -32768.0f) v = -32768.0f;
        frame.samples[i] = (int16_t)v;
        float o = orig[i] * 32768.0f;
        if (o >  32767.0f) o =  32767.0f;
        if (o < -32768.0f) o = -32768.0f;
        frame.original[i] = (int16_t)o;
    }
    frame.prd = prd_val;
    udp_stream_send(&frame, sizeof(frame));
}


static void drain_udp(int budget)
{
    for (volatile int i = 0; i < budget; i++)
        xemacif_input(echo_netif);
}




/* ------------------------------------------------------------------ *
 *  Problem data.  These arrays are generated by the host-side helper
 *  (gen_window_header.py) into ecg_window.h:
 *
 *      D_q15[N_ATOMS][M_LEN]   int16   the wavelet dictionary D = Phi*psi
 *      y_q15[M_LEN]            int16   the 128 compressed measurements
 *      psi[WINDOW_N][WINDOW_N] float   inverse sparsifying transform
 *      s_orig[WINDOW_N]        float   original window (for PRD, debug)
 *
 *  Layout note: D_q15 is [atom][row] so atom j is D_q15[j][*] — contiguous,
 *  which matches the engine's atom-major BRAM read.
 * ------------------------------------------------------------------ */
#include "ecg_window.h"

/* ================================================================== *
 *  HARDWARE ARGMAX  (replaces the Phase-1 software argmax_corr)
 * ================================================================== *
 *
 *  Pack a residual into BRAM_R using the exact §7 packing, pulse START,
 *  poll DONE with a timeout, return RESULT_IDX. The residual is supplied
 *  in float; it gets quantised to Q1.15 on the way in, exactly as the
 *  AXI interface expects.
 *
 *  Packing: word = (int16(r[2i+1]) << 16) | (int16(r[2i]) & 0xFFFF)
 *  -> 64 words for the 128-entry residual, even index in low half-word.
 */
static int hw_argmax(const float r[M_LEN], int *err)
{
    *err = 0;

    /* 1. Pack + write residual to BRAM_R (128 entries -> 64 words). */
    for (int i = 0; i < M_LEN / 2; i++) {
        int16_t lo = f_to_q15(r[2 * i]);      /* even index -> bits[15:0]  */
        int16_t hi = f_to_q15(r[2 * i + 1]);  /* odd  index -> bits[31:16] */
        u32 word = ((u32)(uint16_t)hi << 16) | ((u32)(uint16_t)lo & 0xFFFF);
        REG_WR(BRAM_R_OFFSET + i * 4, word);
    }

    /* 2. Make sure the engine isn't mid-flight, then pulse START.
     *    (Never write START while BUSY — that signals a logic bug.)   */
    if (REG_RD(REG_STATUS) & STATUS_BUSY) {
        *err = 1;
        return -1;
    }
    REG_WR(REG_CTRL, CTRL_START);   /* START self-clears in 1 cycle    */

    /* 3. Poll DONE with a ~100 us timeout. Fatal if it never asserts. */
    for (int t = 0; t <= DONE_TIMEOUT_US; t++) {
        if (REG_RD(REG_STATUS) & STATUS_DONE) {
            return (int)(REG_RD(REG_RESULT_IDX) & 0xFF);  /* 0..255    */
        }
        usleep(1);  /* 1 us granularity; loop bound = timeout in us    */
    }

    *err = 2;   /* DONE timeout */
    return -1;
}

/* Load the full dictionary D into BRAM_D once, before the loop.
 * D_q15 is [atom][row]; atom-major means atom j's 128 rows occupy 64
 * consecutive words starting at BRAM_D_OFFSET + j*64*4.               */
static void load_dictionary(void)
{
    for (int j = 0; j < N_ATOMS; j++) {
        u32 base = BRAM_D_OFFSET + (u32)j * (M_LEN / 2) * 4;
        for (int i = 0; i < M_LEN / 2; i++) {
            int16_t lo = D_q15[j][2 * i];      /* even row -> low half  */
            int16_t hi = D_q15[j][2 * i + 1];  /* odd  row -> high half */
            u32 word = ((u32)(uint16_t)hi << 16) | ((u32)(uint16_t)lo & 0xFFFF);
            REG_WR(base + i * 4, word);
        }
    }
}

/* ================================================================== *
 *  OMP outer loop in C  (support set, LS solve, residual update)
 * ================================================================== *
 *
 *  LS solve = normal equations on the support set. With k <= 32 atoms,
 *  this is a small symmetric solve; plain Gaussian elimination with
 *  partial pivoting is plenty (no Cholesky needed). The atoms here are
 *  the columns of D (the engine's dictionary), as floats.
 *
 *  Analogy: each iteration we ask the clerk for the single best-matching
 *  atom, add it to a growing "team", re-fit ALL the team's weights at once
 *  to best explain y (the least-squares re-fit), then look at what's left
 *  over (the residual) and ask the clerk again.
 */

/* Column j of D as float (the j-th atom, length M_LEN). */
static inline float D_col(int row, int atom) {
    return q15_to_f(D_q15[atom][row]);
}

/* Solve A x = b for n<=MAX_ITERS via Gaussian elimination w/ partial
 * pivoting. A is n x n row-major in a fixed buffer. Returns 0 on success. */
static int solve_dense(float *A, float *b, float *x, int n)
{
    for (int col = 0; col < n; col++) {
        /* pivot */
        int piv = col;
        float best = fabsf(A[col * n + col]);
        for (int r = col + 1; r < n; r++) {
            float v = fabsf(A[r * n + col]);
            if (v > best) { best = v; piv = r; }
        }
        if (best < 1e-12f) return 1;   /* singular */
        if (piv != col) {
            for (int c = 0; c < n; c++) {
                float t = A[col * n + c]; A[col * n + c] = A[piv * n + c]; A[piv * n + c] = t;
            }
            float t = b[col]; b[col] = b[piv]; b[piv] = t;
        }
        /* eliminate */
        for (int r = col + 1; r < n; r++) {
            float f = A[r * n + col] / A[col * n + col];
            for (int c = col; c < n; c++) A[r * n + c] -= f * A[col * n + c];
            b[r] -= f * b[col];
        }
    }
    /* back-substitute */
    for (int r = n - 1; r >= 0; r--) {
        float s = b[r];
        for (int c = r + 1; c < n; c++) s -= A[r * n + c] * x[c];
        x[r] = s / A[r * n + r];
    }
    return 0;
}


static void emit_frame(const int *support, const float *coeff, int k,
                       uint8_t win_id, uint8_t iter_idx, uint8_t total_iters,
                       uint8_t flags)
{
    static float a_hat[N_ATOMS];
    static float s_tilde[WINDOW_N];

    for (int i = 0; i < N_ATOMS; i++) a_hat[i] = 0.0f;
    for (int a = 0; a < k; a++)
        a_hat[support[a]] = coeff[a] / Y_SCALE_ALPHA;

    for (int row = 0; row < WINDOW_N; row++) {
        float acc = 0.0f;
        for (int col = 0; col < WINDOW_N; col++)
            acc += psi[row][col] * a_hat[col];
        s_tilde[row] = acc;
    }

    float num = 0.0f, den = 0.0f;
    for (int i = 0; i < WINDOW_N; i++) {
        float d = s_orig[i] - s_tilde[i];
        num += d * d;
        den += s_orig[i] * s_orig[i];
    }
    float prd = (den > 0.0f) ? 100.0f * sqrtf(num) / sqrtf(den) : -1.0f;

    send_ecg_frame(s_tilde, s_orig, prd, win_id, iter_idx, total_iters, flags);
    drain_udp(8000);
}


int main(void)
{
    /* ---- network bring-up (static IP, UDP only) ---- */
    ip_addr_t ipaddr, netmask, gw;
    unsigned char mac_ethernet_address[] =
        { 0x00, 0x0a, 0x35, 0x00, 0x01, 0x02 };

    echo_netif = &server_netif;

    init_platform();

    IP4_ADDR(&ipaddr,  192, 168,   17, 10);
    IP4_ADDR(&netmask, 255, 255, 255,  0);
    IP4_ADDR(&gw,      192, 168,   1,  1);

    lwip_init();

    if (!xemac_add(echo_netif, &ipaddr, &netmask, &gw,
                   mac_ethernet_address, PLATFORM_EMAC_BASEADDR)) {
        xil_printf("Error adding N/W interface\r\n");
        return -1;
    }
    netif_set_default(echo_netif);
    platform_enable_interrupts();
    netif_set_up(echo_netif);
    //print_ip_settings(&ipaddr, &netmask, &gw);

    udp_stream_init();   /* make the UDP mailbox once */
    /* ---- end network bring-up ---- */


    /* ---- sanity: read STATUS, confirm VERSION ---- */
    u32 st = REG_RD(REG_STATUS);
    u32 ver = (st & STATUS_VER_MASK) >> STATUS_VER_SHFT;
    xil_printf("\r\n=== ENGS-128 Phase 4: on-board OMP recovery ===\r\n");
    xil_printf("STATUS=0x%08x  VERSION=0x%x (expect 0x%x)\r\n",
               (unsigned)st, (unsigned)ver, EXPECTED_VER);
    if (ver != EXPECTED_VER) {
        xil_printf("FATAL: version mismatch -- wrong bitstream/base addr?\r\n");
        return 1;
    }

    /* ---- soft reset, then load the dictionary into BRAM_D once ---- */
    REG_WR(REG_CTRL, CTRL_SOFT_RST);
    usleep(1);
    load_dictionary();
    xil_printf("Dictionary loaded (%d atoms x %d rows).\r\n", N_ATOMS, M_LEN);

    /* ---- OMP state ---- */
    static float r[M_LEN];            /* residual, starts as y         */
    static int   support[MAX_ITERS];  /* chosen atom indices           */
    static float coeff[MAX_ITERS];    /* LS coefficients on the support*/
    static float a_hat[N_ATOMS];      /* full sparse coeff vector       */
    static float Gram[MAX_ITERS * MAX_ITERS];
    static float rhs[MAX_ITERS];
    int k = 0;                        /* support size                  */

    for (int i = 0; i < M_LEN; i++)  r[i] = q15_to_f(y_q15[i]);
    for (int i = 0; i < N_ATOMS; i++) a_hat[i] = 0.0f;

    /* ---- OMP iterations ---- */
    for (int it = 0; it < MAX_ITERS; it++) {

        /* (1) ARGMAX in HARDWARE: best atom for current residual */
        int herr = 0;
        int idx = hw_argmax(r, &herr);
        if (herr) {
            xil_printf("FATAL: hw_argmax err=%d on iter %d "
                       "(1=BUSY, 2=DONE timeout)\r\n", herr, it);
            return 1;
        }

        /* skip if already in support (shouldn't happen with a true OMP
         * residual, but guard against pathological repeats) */
        int dup = 0;
        for (int s = 0; s < k; s++) if (support[s] == idx) { dup = 1; break; }
        if (dup) {
            xil_printf("iter %2d: idx %3d already in support -- stopping\r\n",
                       it, idx);
            break;
        }
        support[k++] = idx;

        /* (2) LEAST-SQUARES re-fit over the whole support set.
         *     Normal equations:  (Ds^T Ds) c = Ds^T y
         *     Ds = columns of D for the chosen atoms (M_LEN x k).      */
        for (int a = 0; a < k; a++) {
            int ja = support[a];
            /* rhs[a] = <atom_ja, y> */
            float acc = 0.0f;
            for (int row = 0; row < M_LEN; row++)
                acc += D_col(row, ja) * q15_to_f(y_q15[row]);
            rhs[a] = acc;
            /* Gram[a][b] = <atom_ja, atom_jb> (symmetric) */
            for (int b = a; b < k; b++) {
                int jb = support[b];
                float g = 0.0f;
                for (int row = 0; row < M_LEN; row++)
                    g += D_col(row, ja) * D_col(row, jb);
                Gram[a * k + b] = g;
                Gram[b * k + a] = g;
            }
        }
        if (solve_dense(Gram, rhs, coeff, k)) {
            xil_printf("iter %2d: singular Gram -- stopping\r\n", it);
            k--;            /* drop the offending atom                  */
            break;
        }

        /* (3) RESIDUAL UPDATE:  r = y - Ds * coeff                     */
        for (int row = 0; row < M_LEN; row++) {
            float approx = 0.0f;
            for (int a = 0; a < k; a++)
                approx += D_col(row, support[a]) * coeff[a];
            r[row] = q15_to_f(y_q15[row]) - approx;
        }

        /* residual norm for progress visibility */
        float rn = 0.0f;
        for (int row = 0; row < M_LEN; row++) rn += r[row] * r[row];
        xil_printf("iter %2d: hw idx=%3d  |r|=%d.%04d\r\n",
                   it, idx, (int)sqrtf(rn),
                   (int)((sqrtf(rn) - (int)sqrtf(rn)) * 10000));


        /* Emit a frame every iteration: partial k-sparse reconstruction.
         * flags=0 here; the FINAL frame (flags=1) is the post-loop send. */
        emit_frame(support, coeff, k, /*win_id=*/7,
                   /*iter_idx=*/(uint8_t)k, /*total_iters=*/MAX_ITERS,
                   /*flags=*/0);
    }

    /* ---- scatter LS coeffs into the full a_hat vector ---- *
     * y was pre-scaled by Y_SCALE_ALPHA in the header so it fit Q1.15 without
     * clipping. OMP is scale-linear, so the coeffs we solved are alpha*true.
     * Undo it here, once, before the inverse transform. */
    for (int a = 0; a < k; a++)
        a_hat[support[a]] = coeff[a] / Y_SCALE_ALPHA;

    /* ---- INVERSE TRANSFORM:  s_tilde = psi * a_hat  (256x256 matvec) ---- */
    static float s_tilde[WINDOW_N];
    for (int row = 0; row < WINDOW_N; row++) {
        float acc = 0.0f;
        for (int col = 0; col < WINDOW_N; col++)
            acc += psi[row][col] * a_hat[col];
        s_tilde[row] = acc;
    }

    /* ---- PRD = 100 * ||s - s_tilde|| / ||s|| ---- */
    float num = 0.0f, den = 0.0f;
    for (int i = 0; i < WINDOW_N; i++) {
        float d = s_orig[i] - s_tilde[i];
        num += d * d;
        den += s_orig[i] * s_orig[i];
    }
    float prd = (den > 0.0f) ? 100.0f * sqrtf(num) / sqrtf(den) : -1.0f;

    /* ---- UART dump for the host plotter ---- *
     * Machine-parseable block. Host script keys on the BEGIN/END tags. */
    xil_printf("\r\nSUPPORT_SIZE %d\r\n", k);
    xil_printf("PRD %d.%04d\r\n", (int)prd,
               (int)((prd - (int)prd) * 10000));

    xil_printf("RECON_BEGIN\r\n");
    for (int i = 0; i < WINDOW_N; i++) {
        /* print s_tilde[i] as a signed fixed-decimal with 6 places;
         * xil_printf has no %f, so do it by hand */
        float v = s_tilde[i];
        int neg = (v < 0.0f);
        if (neg) v = -v;
        int ip = (int)v;
        int fp = (int)((v - ip) * 1000000.0f + 0.5f);
        if (fp >= 1000000) { ip++; fp -= 1000000; }
        xil_printf("%s%d.%06d\r\n", neg ? "-" : "", ip, fp);
    }
    xil_printf("RECON_END\r\n");

    /* also dump the original so the host can plot without its own copy */
    xil_printf("ORIG_BEGIN\r\n");
    for (int i = 0; i < WINDOW_N; i++) {
        float v = s_orig[i];
        int neg = (v < 0.0f);
        if (neg) v = -v;
        int ip = (int)v;
        int fp = (int)((v - ip) * 1000000.0f + 0.5f);
        if (fp >= 1000000) { ip++; fp -= 1000000; }
        xil_printf("%s%d.%06d\r\n", neg ? "-" : "", ip, fp);
    }
    xil_printf("ORIG_END\r\n");

    xil_printf("DONE.\r\n");


    /* ---- send the reconstructed window over UDP ---- */
	xil_printf("Sending frame over UDP...\r\n");
	send_ecg_frame(s_tilde, s_orig, prd, /*win_id=*/7,
	               /*iter_idx=*/(uint8_t)k, /*total_iters=*/MAX_ITERS,
	               /*flags=*/1);

	/* keep the heartbeat alive so the queued packet actually flushes,
	 * then idle here. ~200k iterations is plenty for one small packet. */
	for (volatile int flush = 0; flush < 200000; flush++) {
		xemacif_input(echo_netif);
	}

	xil_printf("Frame sent. Idling.\r\n");
	while (1) {
		xemacif_input(echo_netif);   /* stay alive; keeps the link serviced */
	}
	/* never reached */
	return 0;
}


























