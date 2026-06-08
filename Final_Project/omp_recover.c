/*
 * ENGS-128 -- Phase 1, deliverable (2)
 * ====================================
 * Bare-metal-friendly C port of the OMP recovery loop, mirroring the Python
 * golden reference (omp_reference.py) 1:1. No malloc, fixed-size static arrays.
 *
 * The ONE function that talks to "the search station" is argmax_corr(). Today
 * it does the correlation in software. In Phase 4 you delete its body and
 * replace it with the AXI hardware call:
 *
 *     pack residual -> write BRAM_R  (0x11000+)
 *     write CTRL.START               (0x00, bit0)
 *     poll STATUS.DONE               (0x04, bit0)  with ~100us timeout
 *     read RESULT_IDX                (0x10)
 *
 * Everything else in this file (support set, least squares, residual update,
 * inverse transform) stays exactly as-is on the Cortex-A9. That is the whole
 * point of the project: prove the loop in software first, then swap one
 * function for silicon.
 *
 * Build the host self-test (cross-checks against the Python reference):
 *     gcc -DHOST_TEST -O2 -o omp_test omp_recover.c -lm && ./omp_test
 */

#include <stdint.h>
#include <math.h>

/* ----- Frozen system parameters (the engine's contract) ----------------- */
#define M_LEN      128      /* measurements == atom length (rows of D)       */
#define N_ATOMS    256      /* dictionary atoms (cols of D)                  */
#define WINDOW_N   256      /* signal / window length                        */
#define MAX_ITERS   32      /* OMP sparsity cap                              */
#define Q15_SCALE  32768.0f /* 2^15                                          */
#define OMP_TOL    1e-6f    /* relative-residual stop threshold              */

/* Working buffers are static (file scope), NOT on the stack -- a 128x32
 * float matrix on a bare-metal stack is asking for trouble. */
static float g_A[M_LEN][MAX_ITERS];   /* chosen atom columns (dequantized)   */
static float g_r[M_LEN];              /* residual (measurement space, float) */
static int16_t g_rq[M_LEN];           /* residual quantized to Q1.15         */

/* ------------------------------------------------------------------------ */
/* Q1.15 host quantization -- MUST match to_q15() in the Python reference:  */
/* round half away from zero, then saturate.                                */
/* ------------------------------------------------------------------------ */
static int16_t to_q15(float v)
{
    float x = v * Q15_SCALE;
    float r = (x >= 0.0f) ? floorf(x + 0.5f) : ceilf(x - 0.5f);
    if (r >  32767.0f) r =  32767.0f;
    if (r < -32768.0f) r = -32768.0f;
    return (int16_t)r;
}

/* ======================================================================== */
/* THE SWAPPABLE FUNCTION: one OMP search step.                              */
/*                                                                           */
/* D is stored ATOM-MAJOR: D[atom][i] is entry i of atom 'atom' -- the same  */
/* layout that goes into BRAM_D. r is the Q1.15 residual (-> BRAM_R).        */
/* mac_bits in {8,10,12,14,16}; 16 == no truncation.                         */
/*                                                                           */
/* Bit-exact rules (match the RTL):                                          */
/*   * truncate-before-multiply: arithmetic right shift by (16 - mac_bits)   */
/*     on each input -- a bit-slice that floors toward -inf. (gcc right-      */
/*     shifts signed ints arithmetically, which is exactly this.)            */
/*   * 64-bit accumulator (superset of the HW Q8.30 38-bit acc).             */
/*   * abs(), then argmax with strict '>' so the LOWEST index wins ties.     */
/*                                                                           */
/* Returns the argmax index; writes the signed inner product to *best_val    */
/* (the RESULT_VAL debug register).                                          */
/* ======================================================================== */
int argmax_corr(const int16_t D[N_ATOMS][M_LEN],
                const int16_t r[M_LEN],
                int mac_bits,
                int64_t *best_val)
{
    const int shift = 16 - mac_bits;

    /* Pre-truncate the residual once (the HW truncates both operands). */
    int32_t rt[M_LEN];
    for (int i = 0; i < M_LEN; ++i)
        rt[i] = ((int32_t)r[i]) >> shift;          /* arithmetic, floors -inf */

    int     best_idx   = 0;
    int64_t best_score = -1;                        /* strictly-greater compare */
    int64_t best_raw   = 0;

    for (int j = 0; j < N_ATOMS; ++j) {
        int64_t acc = 0;
        const int16_t *atom = D[j];
        for (int i = 0; i < M_LEN; ++i) {
            int32_t dt = ((int32_t)atom[i]) >> shift;
            acc += (int64_t)dt * (int64_t)rt[i];
        }
        int64_t score = acc < 0 ? -acc : acc;       /* abs(); 38-bit can't overflow llabs */
        if (score > best_score) {                   /* strict '>' => lowest index wins */
            best_score = score;
            best_idx   = j;
            best_raw   = acc;
        }
    }
    if (best_val) *best_val = best_raw;
    return best_idx;
    /* ---- PHASE 4 REPLACEMENT (sketch) -------------------------------------
     *   for (i=0;i<64;i++) BRAM_R[i] = ((uint16_t)r[2*i+1]<<16)|((uint16_t)r[2*i]&0xFFFF);
     *   REG(CTRL) = CTRL_START;
     *   while(!(REG(STATUS) & STATUS_DONE)) { if (timed_out()) fatal(); }
     *   return REG(RESULT_IDX);
     * ---------------------------------------------------------------------- */
}

/* ------------------------------------------------------------------------ */
/* Least squares over the support set via normal equations (A^T A) c = A^T y */
/* solved by Gaussian elimination with partial pivoting. Fixed-size, no      */
/* malloc, no Cholesky -- plenty for k <= 32.                                */
/* A is g_A[i][col], i in [0,M_LEN), col in [0,k).                           */
/* ------------------------------------------------------------------------ */
static void solve_normal_equations(int k, const float y[M_LEN], float c_out[MAX_ITERS])
{
    static float aug[MAX_ITERS][MAX_ITERS + 1];   /* [G | b] augmented system */

    /* Gram matrix G = A^T A  and  b = A^T y. */
    for (int a = 0; a < k; ++a) {
        for (int b = a; b < k; ++b) {
            float acc = 0.0f;
            for (int i = 0; i < M_LEN; ++i)
                acc += g_A[i][a] * g_A[i][b];
            aug[a][b] = acc;
            aug[b][a] = acc;                       /* symmetric */
        }
        float by = 0.0f;
        for (int i = 0; i < M_LEN; ++i)
            by += g_A[i][a] * y[i];
        aug[a][k] = by;
    }

    /* Forward elimination with partial pivoting, then back-substitute via
     * full reduction (Gauss-Jordan) -- simplest thing that works. */
    for (int col = 0; col < k; ++col) {
        int piv = col;
        float pmax = fabsf(aug[col][col]);
        for (int row = col + 1; row < k; ++row) {
            float v = fabsf(aug[row][col]);
            if (v > pmax) { pmax = v; piv = row; }
        }
        if (piv != col)
            for (int cc = 0; cc <= k; ++cc) {
                float t = aug[col][cc]; aug[col][cc] = aug[piv][cc]; aug[piv][cc] = t;
            }
        float pivot = aug[col][col];
        if (fabsf(pivot) < 1e-12f) continue;       /* degenerate; skip */
        float inv = 1.0f / pivot;
        for (int cc = 0; cc <= k; ++cc) aug[col][cc] *= inv;
        for (int row = 0; row < k; ++row) {
            if (row == col) continue;
            float f = aug[row][col];
            if (f != 0.0f)
                for (int cc = 0; cc <= k; ++cc)
                    aug[row][cc] -= f * aug[col][cc];
        }
    }
    for (int i = 0; i < k; ++i) c_out[i] = aug[i][k];
}

/* ------------------------------------------------------------------------ */
/* Full OMP recovery. D atom-major Q1.15; y float measurements.             */
/* Fills a_hat[N_ATOMS] (mostly zeros) and support[]; returns iters used.   */
/* ------------------------------------------------------------------------ */
int omp_recover(const int16_t D[N_ATOMS][M_LEN],
                const float y[M_LEN],
                int mac_bits,
                float a_hat[N_ATOMS],
                int support[MAX_ITERS])
{
    float c[MAX_ITERS];
    int k = 0;

    for (int i = 0; i < N_ATOMS; ++i) a_hat[i] = 0.0f;
    for (int i = 0; i < M_LEN; ++i)   g_r[i]   = y[i];   /* residual <- y */

    float y_norm = 0.0f;
    for (int i = 0; i < M_LEN; ++i) y_norm += y[i] * y[i];
    y_norm = sqrtf(y_norm) + 1e-30f;

    int it = 0;
    for (it = 0; it < MAX_ITERS; ++it) {
        /* ---- HARDWARE STEP: quantize residual, run the engine ---- */
        for (int i = 0; i < M_LEN; ++i) g_rq[i] = to_q15(g_r[i]);
        int64_t val;
        int idx = argmax_corr(D, g_rq, mac_bits, &val);

        /* reject a repeat pick (quantization stalled progress) */
        int repeat = 0;
        for (int q = 0; q < k; ++q) if (support[q] == idx) { repeat = 1; break; }
        if (repeat) break;
        support[k] = idx;

        /* gather chosen atom column (dequantized) into g_A[][k] */
        for (int i = 0; i < M_LEN; ++i)
            g_A[i][k] = (float)D[idx][i] / Q15_SCALE;
        k++;

        /* ---- SOFTWARE STEP: LS solve, then residual update ---- */
        solve_normal_equations(k, y, c);
        for (int i = 0; i < M_LEN; ++i) {
            float fit = 0.0f;
            for (int col = 0; col < k; ++col) fit += g_A[i][col] * c[col];
            g_r[i] = y[i] - fit;
        }

        float r_norm = 0.0f;
        for (int i = 0; i < M_LEN; ++i) r_norm += g_r[i] * g_r[i];
        r_norm = sqrtf(r_norm);
        if (r_norm / y_norm < OMP_TOL) { it++; break; }
    }

    /* scatter support coefficients into the full-length vector */
    for (int col = 0; col < k; ++col) a_hat[support[col]] = c[col];
    return k;
}

/* ------------------------------------------------------------------------ */
/* Inverse transform s_tilde = psi @ a_hat, and PRD.                         */
/* psi stored as psi[n][j] (dense 256x256).                                  */
/* ------------------------------------------------------------------------ */
void reconstruct(const float psi[WINDOW_N][N_ATOMS],
                 const float a_hat[N_ATOMS],
                 float s_tilde[WINDOW_N])
{
    for (int n = 0; n < WINDOW_N; ++n) {
        float acc = 0.0f;
        for (int j = 0; j < N_ATOMS; ++j) acc += psi[n][j] * a_hat[j];
        s_tilde[n] = acc;
    }
}

float prd(const float s[WINDOW_N], const float s_tilde[WINDOW_N])
{
    float num = 0.0f, den = 0.0f;
    for (int n = 0; n < WINDOW_N; ++n) {
        float d = s[n] - s_tilde[n];
        num += d * d;
        den += s[n] * s[n];
    }
    return 100.0f * sqrtf(num) / (sqrtf(den) + 1e-30f);
}

/* ======================================================================== */
/* Host self-test: cross-check against the Python golden reference.          */
/* (On the target, omit -DHOST_TEST; provide a real main + UART output.)     */
/* ======================================================================== */
#ifdef HOST_TEST
#include <stdio.h>
#include "test_vector.h"     /* auto-generated by omp_reference.py */

static float        s_tilde[WINDOW_N];
static float        a_hat[N_ATOMS];
static int          support[MAX_ITERS];

int main(void)
{
    int k = omp_recover(TV_D_q15, TV_y, 16, a_hat, support);
    reconstruct(TV_psi, a_hat, s_tilde);
    float p = prd(TV_s, s_tilde);

    printf("C port self-test (mac_bits = 16)\n");
    printf("  iterations used   : %d\n", k);
    printf("  support set       : ");
    for (int i = 0; i < k; ++i) printf("%d ", support[i]);
    printf("\n  PRD (C)           : %.4f %%\n", p);
    printf("  PRD (Python ref)  : %.4f %%\n", (double)TV_PRD16);

    /* support-set agreement check */
    int match = (k == TV_NSUPPORT);
    for (int i = 0; i < k && i < TV_NSUPPORT; ++i)
        if (support[i] != TV_support[i]) match = 0;
    printf("  support matches   : %s\n", match ? "YES" : "no");
    printf("  PRD agrees (<0.01): %s\n", fabsf(p - (float)TV_PRD16) < 0.01f ? "YES" : "no");
    return 0;
}
#endif