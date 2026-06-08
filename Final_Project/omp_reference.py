#!/usr/bin/env python3
"""
ENGS-128 -- Phase 1, deliverable (1)
=====================================
Python GOLDEN END-TO-END REFERENCE for the OMP compressed-sensing ECG recovery.

This is the oracle the rest of the project is graded against. Two jobs:

  1. Model the hardware argmax *bit-exactly* (`argmax_corr`), so that when the
     real engine comes up on the board (Phase 3) we already know the index it
     must return for any (D, residual, mac_bits).
  2. Wrap that argmax in the full OMP outer loop (support set -> least squares
     -> residual update) -- exactly the loop that will later run in C on the
     Cortex-A9 -- reconstruct s_tilde = psi @ a_hat, and report PRD.

Mental model
------------
The argmax engine is a fast "search station": you hand it the current leftover
signal (the residual) and it tells you which dictionary atom looks most like it.
That is ALL it does. The rest of the assembly line -- deciding how much of each
chosen atom to use (least squares) and computing what's left over (residual
update) -- happens in software here. This file is that whole assembly line in
float, with the one search station replaced by a faithful integer model of the
silicon.

Faithfulness rules (must match the RTL / the board):
  * Both the dictionary atom and the residual are Q1.15 int16 when the engine
    sees them. AXI always carries Q1.15.
  * TRUNCATE-BEFORE-MULTIPLY: before multiplying, drop the (16 - mac_bits) least
    significant bits of each input via an ARITHMETIC right shift. That is a
    bit-slice of the top mac_bits bits; it floors toward -inf (NOT toward zero).
    Python's `>>` on a signed int already floors toward -inf, so it matches.
  * Accumulate the integer products in a wide (>=38-bit) accumulator. We use
    Python ints (unbounded) / int64, a superset of the hardware Q8.30 38-bit acc.
  * abs(), then argmax with LOWEST-INDEX-WINS tie-break (strict '>' in HW;
    np.argmax returns the first maximum, which is the same thing).
"""

import sys
import numpy as np

# ----------------------------------------------------------------------------
# Frozen system parameters (do not change -- these are the engine's contract)
# ----------------------------------------------------------------------------
WINDOW_N  = 256     # signal / window length        (N)
M_LEN     = 128     # measurements == atom length   (M, rows of D)
N_ATOMS   = 256     # number of dictionary atoms    (cols of D)
MAX_ITERS = 32      # OMP sparsity cap (software-enforced; HW is stateless)
Q15_SCALE = 32768   # 2**15, the Q1.15 scale factor

# ----------------------------------------------------------------------------
# Q1.15 host-side quantization (this is what the PS does before a START pulse)
# ----------------------------------------------------------------------------
def to_q15(x):
    """Float -> Q1.15 int16, round-half-AWAY-from-zero, then saturate.

    The rounding rule is fixed here so the C port can match it exactly
    (C: v>=0 ? floorf(v*32768+0.5) : ceilf(v*32768-0.5)).
    """
    x = np.asarray(x, dtype=np.float64) * Q15_SCALE
    q = np.where(x >= 0.0, np.floor(x + 0.5), np.ceil(x - 0.5))
    q = np.clip(q, -32768, 32767)
    return q.astype(np.int16)


def from_q15(q):
    """Q1.15 int16 -> float."""
    return np.asarray(q, dtype=np.float64) / Q15_SCALE


# ----------------------------------------------------------------------------
# THE HARDWARE MODEL: one OMP search step, bit-exact.
# In Phase 4 this single call is replaced by: write residual to BRAM_R,
# pulse CTRL.START, poll STATUS.DONE, read RESULT_IDX.
# ----------------------------------------------------------------------------
def argmax_corr(D_q15, r_q15, mac_bits):
    """Return the index of the atom most correlated with the residual.

    Parameters
    ----------
    D_q15 : int16 array, shape (M_LEN, N_ATOMS)
        Dictionary in Q1.15. Column j is atom j (matches the math D[i, j]).
        (On the board this lives in BRAM_D, atom-major; same numbers.)
    r_q15 : int16 array, shape (M_LEN,)
        Current residual in Q1.15 (what gets written to BRAM_R each iteration).
    mac_bits : int in {8,10,12,14,16}
        Internal truncation width. 16 == no truncation.

    Returns
    -------
    (best_idx, best_val) : (int, int)
        best_idx is the argmax (RESULT_IDX); best_val is the signed inner
        product at the argmax (RESULT_VAL, debug only).
    """
    assert D_q15.shape == (M_LEN, N_ATOMS)
    assert r_q15.shape == (M_LEN,)
    shift = 16 - mac_bits

    # Truncate-before-multiply: arithmetic right shift = bit-slice of top
    # mac_bits, floors toward -inf. int64 '>>' on signed values does exactly
    # this. Promote to int64 first so the shift is well-defined and the
    # subsequent products/sums can't overflow.
    Dt = D_q15.astype(np.int64) >> shift          # (M_LEN, N_ATOMS)
    rt = r_q15.astype(np.int64) >> shift          # (M_LEN,)

    acc = Dt.T @ rt                               # (N_ATOMS,), exact integers
    scores = np.abs(acc)                          # abs() is internal to the HW

    best_idx = int(np.argmax(scores))             # first max == lowest index
    best_val = int(acc[best_idx])                 # signed value (RESULT_VAL)
    return best_idx, best_val


# ----------------------------------------------------------------------------
# Least-squares solve via normal equations (float, runs on the A9 in C later).
# For <=32 atoms a small dense solve is plenty; no Cholesky / no HW needed.
# ----------------------------------------------------------------------------
def solve_normal_equations(A, y):
    """Least-squares min ||A c - y|| via (A^T A) c = A^T y, Gaussian elim.

    A : (M_LEN, k) float, the chosen atom columns.
    y : (M_LEN,)  float, the measurements.
    Returns c : (k,) float.

    Plain Gaussian elimination with partial pivoting is used (rather than
    np.linalg.lstsq) so the algorithm maps 1:1 onto the C port.
    """
    G = A.T @ A                       # (k, k) Gram matrix
    b = A.T @ y                       # (k,)
    k = G.shape[0]
    # Augmented [G | b], eliminate.
    M = np.hstack([G, b.reshape(-1, 1)]).astype(np.float64)
    for col in range(k):
        piv = col + int(np.argmax(np.abs(M[col:, col])))   # partial pivot
        if piv != col:
            M[[col, piv]] = M[[piv, col]]
        pivot = M[col, col]
        if abs(pivot) < 1e-12:        # degenerate; leave as-is (rare)
            continue
        M[col] = M[col] / pivot
        for row in range(k):
            if row != col:
                M[row] -= M[row, col] * M[col]
    return M[:, -1].copy()


# ----------------------------------------------------------------------------
# The full OMP recovery loop (this is what becomes the C outer loop).
# ----------------------------------------------------------------------------
def omp_recover(D_q15, y, mac_bits, max_iters=MAX_ITERS, tol=1e-6, verbose=False):
    """Recover the sparse coefficient vector a_hat (length N_ATOMS).

    D_q15 : (M_LEN, N_ATOMS) int16  -- the Q1.15 dictionary (what HW uses).
    y     : (M_LEN,) float          -- the compressed measurements.
    Returns (a_hat, support, n_iter).
    """
    # The dictionary the system actually embodies is the *dequantized* D_q15;
    # there is no separate full-precision D on the board, so float work uses it.
    D_f = from_q15(D_q15)                       # (M_LEN, N_ATOMS) float

    r = y.astype(np.float64).copy()             # residual in measurement space
    support = []                                # chosen atom indices, in order
    a_hat = np.zeros(N_ATOMS, dtype=np.float64)
    y0_norm = np.linalg.norm(y) + 1e-30

    n_iter = 0
    for n_iter in range(1, max_iters + 1):
        # ---- HARDWARE STEP: quantize residual to Q1.15, run the engine ----
        r_q15 = to_q15(r)
        idx, _ = argmax_corr(D_q15, r_q15, mac_bits)

        if idx in support:
            # The engine re-picked an atom already in the support set. With an
            # orthogonal residual this shouldn't happen; if it does, quantization
            # has stalled progress -- stop. (Software guards this, not HW.)
            if verbose:
                print(f"  iter {n_iter:2d}: re-picked atom {idx}; stopping.")
            n_iter -= 1
            break
        support.append(idx)

        # ---- SOFTWARE STEP: LS solve over the support, then residual update --
        A = D_f[:, support]                     # (M_LEN, k)
        c = solve_normal_equations(A, y)        # (k,)
        r = y - A @ c                           # new residual
        r_norm = np.linalg.norm(r)

        if verbose:
            print(f"  iter {n_iter:2d}: picked atom {idx:3d}, "
                  f"||r||/||y|| = {r_norm / y0_norm:.6e}")

        if r_norm / y0_norm < tol:
            break

    # Scatter the support-set coefficients back into the full-length vector.
    if support:
        a_hat[support] = c
    return a_hat, support, n_iter


def prd(s, s_tilde):
    """Percentage Root-mean-square Difference: 100 * ||s - s_tilde|| / ||s||."""
    s = np.asarray(s, dtype=np.float64)
    s_tilde = np.asarray(s_tilde, dtype=np.float64)
    return 100.0 * np.linalg.norm(s - s_tilde) / (np.linalg.norm(s) + 1e-30)


# ----------------------------------------------------------------------------
# Synthetic test window  (REPLACE THIS with your real stored window).
# Produces psi (256x256), D_q15 (128x256 int16), y (128,), s (256,) such that
# s is exactly k-sparse in psi -- so a correct OMP must drive PRD near zero at
# mac_bits=16. This is the self-test that proves the loop + the HW model.
#
#   To use your real data instead, save an .npz with arrays
#     psi (256,256), D_q15 (128,256 int16), y (128,), s (256,)
#   and run:  python3 omp_reference.py path/to/window.npz
# ----------------------------------------------------------------------------
def make_synthetic_window(seed=0, k=12):
    rng = np.random.default_rng(seed)

    # psi: a random orthonormal basis standing in for the wavelet basis.
    psi, _ = np.linalg.qr(rng.standard_normal((WINDOW_N, WINDOW_N)))

    # Phi: Bernoulli +/-1 measurement matrix, M x N.
    Phi = rng.choice([-1.0, 1.0], size=(M_LEN, WINDOW_N))

    # A genuinely k-sparse coefficient vector and its signal s = psi @ x.
    x_true = np.zeros(WINDOW_N)
    pos = rng.choice(WINDOW_N, size=k, replace=False)
    x_true[pos] = rng.normal(0.0, 0.12, size=k)
    s = psi @ x_true

    # Effective dictionary D = Phi @ psi, then scale so |D| < 1 to fit Q1.15.
    D = Phi @ psi                                   # (M_LEN, N_ATOMS)
    c_scale = 1.1 * np.max(np.abs(D))
    D_scaled = D / c_scale
    y = (Phi @ s) / c_scale                         # consistent scaling: y=D_scaled@x_true

    D_q15 = to_q15(D_scaled)
    return psi, D_q15, y, s


def load_window(path):
    z = np.load(path)
    psi   = z["psi"].astype(np.float64)
    D_q15 = z["D_q15"].astype(np.int16)
    y     = z["y"].astype(np.float64)
    s     = z["s"].astype(np.float64)
    assert psi.shape == (WINDOW_N, WINDOW_N)
    assert D_q15.shape == (M_LEN, N_ATOMS)
    assert y.shape == (M_LEN,)
    assert s.shape == (WINDOW_N,)
    return psi, D_q15, y, s


# ----------------------------------------------------------------------------
# Optional: dump the current test case as a C header so the C port (deliverable
# 2) can be cross-checked against this exact reference.
# ----------------------------------------------------------------------------
def dump_c_header(path, psi, D_q15, y, s, support, prd16):
    # C stores the dictionary atom-major: Dc[atom][i] == D_q15[i, atom].
    Dc = D_q15.T  # (N_ATOMS, M_LEN)

    def c_array_2d(name, arr, ctype, fmt=lambda v: str(int(v))):
        rows = ", ".join(
            "{" + ",".join(fmt(v) for v in row) + "}" for row in arr
        )
        return f"static const {ctype} {name}[{arr.shape[0]}][{arr.shape[1]}] = {{{rows}}};\n"

    def c_array_1d(name, arr, ctype, fmt=str):
        vals = ",".join(fmt(v) for v in arr)
        return f"static const {ctype} {name}[{len(arr)}] = {{{vals}}};\n"

    with open(path, "w") as f:
        f.write("/* AUTO-GENERATED by omp_reference.py -- test fixture for the C port. */\n")
        f.write("#ifndef TEST_VECTOR_H\n#define TEST_VECTOR_H\n#include <stdint.h>\n\n")
        f.write(f"#define TV_M_LEN {M_LEN}\n#define TV_N_ATOMS {N_ATOMS}\n#define TV_WINDOW_N {WINDOW_N}\n\n")
        f.write(c_array_2d("TV_D_q15", Dc, "int16_t"))
        f.write(c_array_2d("TV_psi", psi, "float", lambda v: f"{v:.10e}f"))
        f.write(c_array_1d("TV_y", y, "float", lambda v: f"{v:.10e}f"))
        f.write(c_array_1d("TV_s", s, "float", lambda v: f"{v:.10e}f"))
        f.write(f"\n#define TV_PRD16 {prd16:.10f}f\n")
        f.write(f"#define TV_NSUPPORT {len(support)}\n")
        f.write(c_array_1d("TV_support", np.array(support), "int"))
        f.write("\n#endif /* TEST_VECTOR_H */\n")


# ----------------------------------------------------------------------------
def main():
    if len(sys.argv) > 1 and not sys.argv[1].startswith("--"):
        path = sys.argv[1]
        print(f"Loading stored ECG window from: {path}")
        psi, D_q15, y, s = load_window(path)
        synthetic = False
    else:
        print("=" * 70)
        print("NO DATA FILE GIVEN -> running on a SYNTHETIC k-sparse self-test.")
        print("Replace with your real window:  python3 omp_reference.py window.npz")
        print("=" * 70)
        psi, D_q15, y, s = make_synthetic_window()
        synthetic = True

    # ---- The required run: PRD at mac_bits = 16 -----------------------------
    print("\nRunning OMP recovery at mac_bits = 16 ...")
    a_hat, support, n_iter = omp_recover(D_q15, y, mac_bits=16, verbose=True)
    s_tilde = psi @ a_hat
    prd16 = prd(s, s_tilde)
    print(f"\n  iterations used : {n_iter}")
    print(f"  support set     : {support}")
    print(f"  PRD (mac_bits=16): {prd16:.4f} %")
    verdict = "EXCELLENT (<5%)" if prd16 < 5 else ("VERY GOOD (<9%)" if prd16 < 9 else "above target")
    print(f"  verdict         : {verdict}")

    # ---- Bonus: the MAC_BITS sweep (the Phase-5 accuracy study) --------------
    print("\nMAC_BITS sweep (PRD vs internal truncation width):")
    print("  mac_bits |   PRD %   | iters | support size")
    print("  ---------+-----------+-------+-------------")
    for mb in (8, 10, 12, 14, 16):
        a_mb, supp_mb, it_mb = omp_recover(D_q15, y, mac_bits=mb)
        prd_mb = prd(s, psi @ a_mb)
        print(f"      {mb:2d}   |  {prd_mb:7.4f}  |   {it_mb:2d}  |   {len(supp_mb)}")

    # ---- Dump the C cross-check fixture --------------------------------------
    if synthetic:
        out = "/home/claude/test_vector.h"
        dump_c_header(out, psi, D_q15, y, s, support, prd16)
        print(f"\nWrote C cross-check fixture: {out}")


if __name__ == "__main__":
    main()