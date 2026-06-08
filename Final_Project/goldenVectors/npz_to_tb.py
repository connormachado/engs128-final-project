#!/usr/bin/env python3
"""
npz_to_tb.py  —  convert golden-vector .npz files into the exact format
                 expected by tb_omp_engine.vhd.

Produces (in --outdir, default goldenVectors/):
    <base>_D.mem     1024 lines x 128 hex chars  (512-bit chunks, MSB-first)
    <base>_r.mem        4 lines x 128 hex chars
    <base>_exp.txt   "<IDX 2hex> <VAL 10hex>"

The 512-bit line format (what hread fills MSB-first):
    bits[511:496] = element 31  (MAC 31's input for this chunk)
    bits[495:480] = element 30
    ...
    bits[15:0]    = element  0  (MAC 0's input)
  => hex string = {elem31:04X}{elem30:04X}...{elem1:04X}{elem0:04X}  (128 chars)

This matches the testbench's bank slicing:
    chunk(32*b+31 downto 32*b) for b=0..15
    -> bank b lower 16 = element 2b  (even, bits[16*(2b)+15:16*(2b)])
    -> bank b upper 16 = element 2b+1 (odd)
which is exactly §7 packing (even in bits[15:0], odd in bits[31:16]).

VAL in exp.txt is the 38-bit signed integer accumulator at the winning atom,
sign-extended to 40 bits and written as 10 uppercase hex chars.  This matches
the testbench assertion (EXPECT_SIGNED_VAL=true path):
    resize(signed(dbg_best_score), 40) = signed(val_e)

Usage:
    python3 npz_to_tb.py golden_3.npz              # one vector, auto-named
    python3 npz_to_tb.py golden_3.npz --name test_04_winner_near_index_N
    python3 npz_to_tb.py --all                     # regenerate all 5 + convert
    python3 npz_to_tb.py golden_*.npz -o sim/gv/   # batch, explicit output dir
"""

import argparse
import os
import sys
import numpy as np

M_LEN    = 128
N_ATOMS  = 256
N_MACS   = 32          # elements per 512-bit chunk
N_CHUNKS = M_LEN // N_MACS   # 4

# Mapping from make_golden.py labels to testbench base names
LABEL_TO_TB = {
    "easy_big_margin":          "test_01_easy_margin",
    "tight_margin":             "test_02_tight_margin",
    "winner_index_0":           "test_03_winner_near_index_0",
    "winner_index_255":         "test_04_winner_near_index_N",
    "engineered_tie_low_wins":  "test_05_engineered_tie",
}


# ── key-name aliasing ────────────────────────────────────────────────────────
def pick(npz, names):
    for n in names:
        if n in npz:
            return npz[n]
    raise KeyError(f"none of {names} found; keys present: {list(npz.keys())}")


def as_atom_major(D):
    D = np.asarray(D, dtype=np.int16)
    if D.shape == (M_LEN, N_ATOMS):
        return D.T.copy()
    elif D.shape == (N_ATOMS, M_LEN):
        return D.copy()
    raise ValueError(f"unexpected D shape {D.shape}")


# ── 512-bit chunk → 128-char hex string ─────────────────────────────────────
def chunk_to_hex(elems):
    """
    Pack 32 int16 elements into a 128-char hex string, MSB-first.
    Element 31 occupies the most-significant 16 bits (first 4 hex chars).
    Element  0 occupies the least-significant 16 bits (last  4 hex chars).

    This is what hread fills into chunk(511 downto 0), and what the engine
    reads back as bits[16*i+15:16*i] for MAC i.
    """
    assert len(elems) == N_MACS, f"expected {N_MACS} elements, got {len(elems)}"
    return "".join(f"{int(e) & 0xFFFF:04X}" for e in reversed(elems))


# ── file writers ─────────────────────────────────────────────────────────────
def write_d_mem(path, D):
    """D: (N_ATOMS, M_LEN) int16 atom-major."""
    with open(path, "w") as f:
        for j in range(N_ATOMS):          # atom 0..255
            for c in range(N_CHUNKS):     # chunk 0..3
                elems = D[j][c * N_MACS : (c + 1) * N_MACS]
                f.write(chunk_to_hex(elems) + "\n")
    lines = N_ATOMS * N_CHUNKS
    print(f"  wrote {path}  ({lines} lines x 512 bits)")


def write_r_mem(path, r):
    """r: (M_LEN,) int16."""
    with open(path, "w") as f:
        for c in range(N_CHUNKS):         # chunk 0..3
            elems = r[c * N_MACS : (c + 1) * N_MACS]
            f.write(chunk_to_hex(elems) + "\n")
    print(f"  wrote {path}  ({N_CHUNKS} lines x 512 bits)")


def write_exp_txt(path, idx, D, r):
    """
    Compute the 38-bit signed accumulator at atom idx, sign-extend to 40 bits.
    Format: "<IDX 2hex> <VAL 10hex>"
    """
    # Full-precision integer dot product (mac_bits=16 = no truncation)
    acc = int(np.dot(D[idx].astype(np.int64), r.astype(np.int64)))
    # Sign-extend from 38 bits to 40 bits via two's-complement mask
    acc_40 = acc & 0xFFFFFFFFFF   # take low 40 bits (two's-complement for negatives)
    with open(path, "w") as f:
        f.write(f"{idx:02X} {acc_40:010X}\n")
    sign = "+" if acc >= 0 else "-"
    print(f"  wrote {path}  idx={idx} (0x{idx:02X})  acc={sign}{abs(acc)}  "
          f"VAL=0x{acc_40:010X}")


# ── convert one .npz ─────────────────────────────────────────────────────────
def convert(npz_path, outdir, name_override=None):
    z = np.load(npz_path, allow_pickle=True)
    D   = as_atom_major(pick(z, ["D_q15", "D", "dictionary"]))
    r   = np.asarray(pick(z, ["r_q15", "r", "residual"]), dtype=np.int16).reshape(-1)
    idx = int(np.asarray(pick(z, ["expected_idx", "idx", "argmax"])).flat[0])
    label = str(z["label"]) if "label" in z else ""

    if name_override:
        base = name_override
    elif label in LABEL_TO_TB:
        base = LABEL_TO_TB[label]
    else:
        # Fall back to the .npz stem
        base = os.path.splitext(os.path.basename(npz_path))[0]
        print(f"  [warn] label '{label}' not in LABEL_TO_TB map — using '{base}'")

    print(f"\n[{base}]  source: {npz_path}  expected_idx={idx}")
    os.makedirs(outdir, exist_ok=True)
    write_d_mem(  os.path.join(outdir, f"{base}_D.mem"),   D)
    write_r_mem(  os.path.join(outdir, f"{base}_r.mem"),   r)
    write_exp_txt(os.path.join(outdir, f"{base}_exp.txt"), idx, D, r)


# ── --all: regenerate all 5 vectors via make_golden then convert ─────────────
def make_all_vectors(outdir, seed=0):
    """Call make_golden's scenarios directly so no intermediate files are needed."""
    # inline the scenario logic rather than shelling out
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import goldenVectors.make_golden as mg
    except ImportError:
        print("ERROR: make_golden.py not found in the same directory as this script.")
        print("Run: python3 npz_to_tb.py golden_0.npz golden_1.npz ... -o goldenVectors/")
        sys.exit(1)

    rng = np.random.default_rng(seed)
    scenarios = [
        (mg.scenario_easy,            "golden_0.npz"),
        (mg.scenario_tight,           "golden_1.npz"),
        (mg.scenario_winner_low,      "golden_2.npz"),
        (mg.scenario_winner_high,     "golden_3.npz"),
        (mg.scenario_engineered_tie,  "golden_4.npz"),
    ]
    print(f"Generating {len(scenarios)} golden vectors in-memory ...\n")
    for build, _ in scenarios:
        Dq, rq, label = build(rng)
        idx, _ = mg.hw_argmax(Dq, rq, mac_bits=16)
        base = LABEL_TO_TB.get(label, label)
        print(f"[{base}]  label={label}  expected_idx={idx}")
        os.makedirs(outdir, exist_ok=True)
        write_d_mem(  os.path.join(outdir, f"{base}_D.mem"),   Dq)
        write_r_mem(  os.path.join(outdir, f"{base}_r.mem"),   rq)
        write_exp_txt(os.path.join(outdir, f"{base}_exp.txt"), idx, Dq, rq)


# ── sanity check: round-trip one chunk ───────────────────────────────────────
def _self_test():
    rng = np.random.default_rng(99)
    elems = rng.integers(-32768, 32767, size=N_MACS, dtype=np.int16)
    line = chunk_to_hex(elems)
    assert len(line) == 128, f"chunk hex length {len(line)} != 128"
    # Verify element 0 is in last 4 chars, element 31 is in first 4 chars
    assert int(line[-4:], 16) == (int(elems[0]) & 0xFFFF), "element 0 mismatch"
    assert int(line[:4],  16) == (int(elems[31]) & 0xFFFF), "element 31 mismatch"
    # Verify bank b extraction: chunk[32b+31:32b] = {elem2b+1, elem2b}
    chunk_int = int(line, 16)  # 512-bit integer, MSB = elem31
    for b in range(16):
        bank = (chunk_int >> (32 * b)) & 0xFFFFFFFF
        even_got = bank & 0xFFFF
        odd_got  = (bank >> 16) & 0xFFFF
        assert even_got == (int(elems[2 * b])     & 0xFFFF), f"bank {b} even mismatch"
        assert odd_got  == (int(elems[2 * b + 1]) & 0xFFFF), f"bank {b} odd  mismatch"
    print("  self-test OK (element ordering + bank extraction verified)")


# ── main ─────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("npz", nargs="*", help=".npz file(s) to convert")
    ap.add_argument("--all", action="store_true",
                    help="generate all 5 vectors via make_golden (no .npz needed)")
    ap.add_argument("--name", default=None,
                    help="override output base name for a single .npz")
    ap.add_argument("-o", "--outdir", default="goldenVectors",
                    help="output directory (default: goldenVectors/)")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    print("Running self-test ...")
    _self_test()

    if args.all:
        make_all_vectors(args.outdir, seed=args.seed)
        return

    if not args.npz:
        ap.print_help()
        sys.exit(1)

    for path in args.npz:
        convert(path, args.outdir, args.name if len(args.npz) == 1 else None)

    print(f"\nDone. Files are in {args.outdir}/")
    print("In Vivado/ModelSim: set working directory so 'goldenVectors/' is reachable,")
    print("or edit VEC_DIR in tb_omp_engine.vhd to match your path.")


if __name__ == "__main__":
    main()