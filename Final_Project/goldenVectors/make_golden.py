#!/usr/bin/env python3
"""
make_golden.py  —  generate golden-vector .npz files for the OMP correlation engine.

These are ANSWER KEYS for the argmax step: a dictionary D, a residual r, and the
index the engine MUST return. The "expected" index is computed by a bit-exact
model of the hardware (truncate-before-multiply at mac_bits, abs, argmax with
lowest-index tie-break) so the vector is consistent with both the silicon and
your own re-derived software.

NO external dataset is needed — golden vectors test the argmax, not ECG recovery.
(You only need the real MIT-BIH window later, for the Phase-4 PRD plot.)

Usage:
    python make_golden.py                 # writes golden_0.npz ... golden_4.npz
    python make_golden.py -o vectors/     # into a directory
    python make_golden.py --mac-bits 16   # answer key computed at this width

Then convert one to a C header for Phase 3:
    python npz_to_c.py golden_0.npz       # -> golden_vector.h

Each .npz contains:
    D_q15 : int16, shape (256, 128)  atom-major (one atom per row)
    r     : int16, shape (128,)      the residual, Q1.15
    expected_idx : int               the argmax index the engine must return
    mac_bits     : int               width the answer key was computed at
    label        : str               which scenario this vector exercises
"""
import argparse
import os
import numpy as np

M_LEN = 128       # atom length / # measurements
N_ATOMS = 256     # # dictionary atoms
Q15 = 32768.0     # 2^15


# ---------------------------------------------------------------------------
# Bit-exact hardware argmax model.
# MUST match argmax_corr() in omp_reference.py and the RTL:
#   * truncate-before-multiply: arithmetic right shift drops (16-mac_bits) LSBs
#     of each Q1.15 input -> a bit-slice that floors toward -inf.
#   * accumulate integer products in a wide (64-bit here) accumulator.
#   * abs(), then argmax with STRICT '>' so lowest index wins on ties.
# ---------------------------------------------------------------------------
def truncate_q15(a, mac_bits):
    """Drop the (16 - mac_bits) LSBs via arithmetic right shift (floor toward -inf)."""
    shift = 16 - mac_bits
    if shift == 0:
        return a.astype(np.int64)
    return (a.astype(np.int64) >> shift)  # numpy >> on signed ints is arithmetic


def hw_argmax(D, r, mac_bits):
    """Return the index the engine produces for dictionary D (atom-major) and residual r."""
    Dt = truncate_q15(D, mac_bits)        # (N_ATOMS, M_LEN)
    rt = truncate_q15(r, mac_bits)        # (M_LEN,)
    acc = Dt.astype(np.int64) @ rt.astype(np.int64)   # (N_ATOMS,) integer inner products
    mag = np.abs(acc)
    # strict '>' / lowest-index-wins is exactly what np.argmax does already.
    return int(np.argmax(mag)), acc


def to_q15(x):
    """Float in [-1,1) -> Q1.15 int16, round half away from zero, saturate."""
    v = np.where(x >= 0, np.floor(x * Q15 + 0.5), np.ceil(x * Q15 - 0.5))
    v = np.clip(v, -32768, 32767)
    return v.astype(np.int16)


# ---------------------------------------------------------------------------
# Scenario builders. Each returns (D_q15, r_q15, label).
# We build float D/r in [-1,1), quantize, then let hw_argmax decide the key.
# The scenarios deliberately stress the corners the engine can get wrong.
# ---------------------------------------------------------------------------
def scenario_easy(rng):
    """One atom is an obvious copy of the residual; huge margin."""
    r = rng.uniform(-0.6, 0.6, M_LEN)
    D = rng.uniform(-0.3, 0.3, (N_ATOMS, M_LEN))
    winner = 137
    D[winner] = 0.9 * r / (np.abs(r).max() + 1e-9)   # strongly aligned
    return to_q15(D), to_q15(r), "easy_big_margin"


def scenario_tight(rng):
    """Two atoms nearly tie; ~0.002%-ish margin. Tests the comparator."""
    r = rng.uniform(-0.5, 0.5, M_LEN)
    D = rng.uniform(-0.3, 0.3, (N_ATOMS, M_LEN))
    base = 0.8 * r / (np.abs(r).max() + 1e-9)
    D[100] = base
    D[101] = base * 0.99995            # a hair smaller -> 100 should win
    return to_q15(D), to_q15(r), "tight_margin"


def scenario_winner_low(rng):
    """Winner at index 0 — checks the running-max init."""
    r = rng.uniform(-0.5, 0.5, M_LEN)
    D = rng.uniform(-0.25, 0.25, (N_ATOMS, M_LEN))
    D[0] = 0.95 * r / (np.abs(r).max() + 1e-9)
    return to_q15(D), to_q15(r), "winner_index_0"


def scenario_winner_high(rng):
    """Winner at index N_ATOMS-1 — checks the last-atom path / drain."""
    r = rng.uniform(-0.5, 0.5, M_LEN)
    D = rng.uniform(-0.25, 0.25, (N_ATOMS, M_LEN))
    D[N_ATOMS - 1] = 0.95 * r / (np.abs(r).max() + 1e-9)
    return to_q15(D), to_q15(r), "winner_index_255"


def scenario_engineered_tie(rng):
    """Two atoms with IDENTICAL post-quantization correlation -> lowest index must win."""
    r = rng.uniform(-0.5, 0.5, M_LEN)
    D = rng.uniform(-0.25, 0.25, (N_ATOMS, M_LEN))
    aligned = 0.7 * r / (np.abs(r).max() + 1e-9)
    D[50] = aligned
    D[200] = aligned                   # exact tie after quantization
    Dq, rq = to_q15(D), to_q15(r)
    # Force the tie to be bit-identical post-quantization:
    Dq[200] = Dq[50].copy()
    return Dq, rq, "engineered_tie_low_wins"


SCENARIOS = [
    scenario_easy,
    scenario_tight,
    scenario_winner_low,
    scenario_winner_high,
    scenario_engineered_tie,
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--outdir", default=".")
    ap.add_argument("--mac-bits", type=int, default=16,
                    help="width the answer key is computed at (default 16 = no truncation)")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)
    rng = np.random.default_rng(args.seed)

    print(f"Generating {len(SCENARIOS)} golden vectors at mac_bits={args.mac_bits}\n")
    for i, build in enumerate(SCENARIOS):
        Dq, rq, label = build(rng)
        idx, acc = hw_argmax(Dq, rq, args.mac_bits)

        # Sanity: report the margin between the winner and runner-up.
        mag = np.abs(acc)
        order = np.argsort(mag)[::-1]
        top, second = mag[order[0]], mag[order[1]]
        margin = 100.0 * (top - second) / (top + 1e-9)

        path = os.path.join(args.outdir, f"golden_{i}.npz")
        np.savez(path,
                 D_q15=Dq, r=rq,
                 expected_idx=np.int32(idx),
                 mac_bits=np.int32(args.mac_bits),
                 label=label)
        print(f"  golden_{i}.npz  [{label:24s}]  expected_idx={idx:3d}  "
              f"margin={margin:6.3f}%  runner-up={order[1]}")

    print("\nNext:")
    print("  python npz_to_c.py golden_0.npz     # -> golden_vector.h for Phase 3")
    print("  (swap golden_0 for golden_1..4 to test other scenarios)")


if __name__ == "__main__":
    main()