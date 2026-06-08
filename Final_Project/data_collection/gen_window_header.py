#!/usr/bin/env python3
"""
ENGS-128 — gen_window_header.py

Generates ecg_window.h for the bare-metal board program (omp_onboard.c).
Emits four arrays the C side #includes:

    D_q15[N_ATOMS][M_LEN]   int16   wavelet dictionary D = Phi*psi, [atom][row]
    y_q15[M_LEN]            int16   the 128 compressed measurements
    psi[WINDOW_N][WINDOW_N] float   inverse sparsifying transform (s = psi * a)
    s_orig[WINDOW_N]        float   original window, for PRD / overlay

Indexing note: D_q15 is [atom][row] so atom j is one contiguous run — this
matches the engine's atom-major BRAM layout and the C loop's D_col(row, atom).

Input is a single .npz with arrays (names configurable via flags):
    D       float or int16, shape (M_LEN, N_ATOMS)  [row, atom]   -> transposed on emit
    y       float or int16, shape (M_LEN,)
    psi     float,          shape (WINDOW_N, WINDOW_N)
    s       float,          shape (WINDOW_N,)

If D / y arrive already in int16 Q1.15 they're used verbatim; if float, they're
quantised with round-to-nearest and clamped to int16 range (same convention as
the C f_to_q15).

Usage:
    python gen_window_header.py window0.npz
    python gen_window_header.py window0.npz -o ecg_window.h \
        --d-key D --y-key y --psi-key psi --s-key s

This is the SAME Q1.15 wire format omp_onboard.c packs into BRAM, so the host
reference, the board, and the Ethernet packet path all agree byte-for-byte.
"""

import argparse
import sys
import numpy as np


WINDOW_N = 256
M_LEN = 128
N_ATOMS = 256
Q15_ONE = 32768.0


def cfloat(v):
    """Format a float as a valid C float literal, always ending in 'f'.
 
    The bug: f"{v:.8g}f" emits things like "1f" or "-0f" when %g strips the
    decimal point off whole-number values (very common in a basis matrix:
    0.0, 1.0, -1.0). C reads "1f" as an integer with an illegal 'f' suffix
    -> "invalid suffix 'f' on integer constant". A float literal needs a
    decimal point or exponent BEFORE the suffix: "1.0f" is legal.
    """
    s = f"{float(v):.8g}"
    if not any(c in s for c in (".", "e", "E", "n", "i")):  # n/i guard inf,nan
        s += ".0"
    return s + "f"


def to_q15(arr):
    """Round-to-nearest + clamp to int16, matching the C f_to_q15()."""
    if np.issubdtype(arr.dtype, np.integer):
        # already fixed-point; trust it but sanity-check range
        if arr.min() < -32768 or arr.max() > 32767:
            sys.exit("ERROR: integer input exceeds int16 range; "
                     "is it really Q1.15?")
        return arr.astype(np.int16)
    q = np.rint(arr.astype(np.float64) * Q15_ONE)
    q = np.clip(q, -32768, 32767)
    return q.astype(np.int16)


def fmt_int16_2d(name, a):
    """Emit `static const int16_t name[R][C] = {...};` row-major."""
    R, C = a.shape
    lines = [f"static const int16_t {name}[{R}][{C}] = {{"]
    for r in range(R):
        vals = ", ".join(str(int(v)) for v in a[r])
        lines.append(f"  {{ {vals} }},")
    lines.append("};")
    return "\n".join(lines)


def fmt_int16_1d(name, a):
    vals = ", ".join(str(int(v)) for v in a)
    return f"static const int16_t {name}[{a.shape[0]}] = {{ {vals} }};"


def fmt_float_2d(name, a):
    R, C = a.shape
    lines = [f"static const float {name}[{R}][{C}] = {{"]
    for r in range(R):
        vals = ", ".join(cfloat(v) for v in a[r])
        lines.append(f"  {{ {vals} }},")
    lines.append("};")
    return "\n".join(lines)


def fmt_float_1d(name, a):
    vals = ", ".join(cfloat(v) for v in a)
    return f"static const float {name}[{a.shape[0]}] = {{ {vals} }};"


def main():
    ap = argparse.ArgumentParser(
        description="Generate ecg_window.h from a stored ECG window .npz")
    ap.add_argument("npz", help="input .npz with D, y, psi, s")
    ap.add_argument("-o", "--out", default="ecg_window.h")
    ap.add_argument("--d-key", default="D_q15")
    ap.add_argument("--y-key", default="y")
    ap.add_argument("--psi-key", default="psi")
    ap.add_argument("--s-key", default="s")
    args = ap.parse_args()

    npz = np.load(args.npz)
    for k in (args.d_key, args.y_key, args.psi_key, args.s_key):
        if k not in npz:
            sys.exit(f"ERROR: key '{k}' not in {args.npz}. "
                     f"Have: {list(npz.keys())}")

    D = npz[args.d_key]
    y = npz[args.y_key]
    psi = npz[args.psi_key]
    s = npz[args.s_key]

    # ---- shape checks (fail loud; a silent transpose ruins everything) ----
    if D.shape == (N_ATOMS, M_LEN):
        D = D.T          # stored [atom, row] — transpose to [row, atom] for the script
    elif D.shape != (M_LEN, N_ATOMS):
        sys.exit(f"ERROR: D shape {D.shape}, expected ({M_LEN}, {N_ATOMS}) "
                 f"as [row, atom].")
    if y.shape != (M_LEN,):
        sys.exit(f"ERROR: y shape {y.shape}, expected ({M_LEN},).")
    if psi.shape != (WINDOW_N, WINDOW_N):
        sys.exit(f"ERROR: psi shape {psi.shape}, expected "
                 f"({WINDOW_N}, {WINDOW_N}).")
    if s.shape != (WINDOW_N,):
        sys.exit(f"ERROR: s shape {s.shape}, expected ({WINDOW_N},).")

    # ---- quantise D, y to Q1.15; transpose D to [atom][row] for the C side --
    D_q15 = to_q15(D).T            # (M_LEN, N_ATOMS) -> (N_ATOMS, M_LEN)
    D_q15 = np.ascontiguousarray(D_q15)

    # y = Phi*s has LARGER dynamic range than s (Bernoulli matrix sums 256
    # terms), so entries routinely exceed Q1.15's [-1, 1) and would clip at
    # the rail -> wrecked recovery (51% of entries clipped in practice).
    # Scale y into range BEFORE quantising (no clipping) and emit the factor.
    # OMP is scale-linear, so the board undoes it by dividing the recovered
    # coefficients by Y_SCALE_ALPHA. D and s already fit; they are NOT scaled.
    yf = y.astype(np.float64)
    ymax = float(np.max(np.abs(yf)))
    y_alpha = min(0.9 / ymax, 1.0) if ymax > 0 else 1.0   # 0.9 leaves headroom
    if y_alpha < 1.0:
        print(f"y: max|y|={ymax:.4f} exceeds Q1.15 -> scaling by "
              f"alpha={y_alpha:.8f}  (board divides coeffs back by it)")
    y_q15 = to_q15(yf * y_alpha)

    psi_f = psi.astype(np.float64)
    s_f = s.astype(np.float64)

    # ---- self-check: float-reference PRD of a perfect round-trip ----------
    # If you stored a_hat too you could verify recovery here; at minimum we
    # confirm psi @ (pseudo-coeffs) isn't degenerate by reporting norms.
    print(f"D  : {D.shape} {D.dtype} -> D_q15 [{N_ATOMS}][{M_LEN}] int16")
    print(f"y  : {y.shape} {y.dtype} -> y_q15 [{M_LEN}] int16")
    print(f"psi: {psi.shape} {psi.dtype}")
    print(f"s  : {s.shape} {s.dtype}  ||s|| = {np.linalg.norm(s_f):.4f}")

    header = f"""/*
 * ecg_window.h  --  AUTO-GENERATED by gen_window_header.py
 * Source: {args.npz}
 * Do not edit by hand; regenerate to change the window.
 *
 * Q1.15 fixed-point matches omp_onboard.c f_to_q15/q15_to_f exactly.
 * D_q15 is [atom][row] (atom-major), so D_q15[j] is one contiguous atom.
 */
#ifndef ECG_WINDOW_H
#define ECG_WINDOW_H
#include <stdint.h>

#define GEN_WINDOW_N {WINDOW_N}
#define GEN_M_LEN    {M_LEN}
#define GEN_N_ATOMS  {N_ATOMS}

/* y was pre-scaled by this factor so it fits Q1.15 without clipping.
 * omp_onboard.c divides recovered coefficients by it before psi*a_hat. */
#define Y_SCALE_ALPHA {y_alpha:.8f}f

{fmt_int16_2d("D_q15", D_q15)}

{fmt_int16_1d("y_q15", y_q15)}

{fmt_float_2d("psi", psi_f)}

{fmt_float_1d("s_orig", s_f)}

#endif /* ECG_WINDOW_H */
"""

    with open(args.out, "w") as f:
        f.write(header)

    # rough size warning — psi alone is 256*256 floats of source text
    import os
    kb = os.path.getsize(args.out) / 1024.0
    print(f"Wrote {args.out} ({kb:.0f} KB).")
    if kb > 700:
        print("NOTE: psi as a 256x256 float literal is the bulk of this. "
              "If compile/link is slow or .data is tight, consider storing "
              "psi in DDR and loading it another way -- but for one window "
              "this is fine.")


if __name__ == "__main__":
    main()