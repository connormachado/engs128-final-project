#!/usr/bin/env python3
"""
prepare_data.py  —  build the Phase-4 ECG window file (window.npz).

WHAT IT MAKES
-------------
A single window.npz containing the four arrays the on-board recovery needs:
    psi   (256, 256)  float64  -- the wavelet sparsifying basis (orthonormal)
    D_q15 (256, 128)  int16    -- the Q1.15 dictionary D = Phi @ psi, ATOM-MAJOR
    y     (128,)       float64  -- compressed measurements, in the recovery space
    s     (256,)       float64  -- the original ECG window (for PRD)

It also writes phi.npy (the 128x256 Bernoulli +/-1 matrix) so the experiment is
reproducible, and prints the recovered PRD so you KNOW it's under 9% before you
ever touch the board.

THE PIPELINE (the "shred one photo and check it reassembles" step)
------------------------------------------------------------------
  1. Get one 256-sample ECG window s from MIT-BIH cdb (or a realistic synthetic
     fallback if wfdb / network aren't available).
  2. Build psi = orthonormal db4 wavelet basis. ECG is sparse in psi: a few
     wavelet coefficients capture the QRS spike + slow baseline.
  3. Build Phi = Bernoulli +/-1 (128 x 256), the compressive measurement matrix.
  4. D_float = Phi @ psi. Scale into [-1,1) and quantize to Q1.15 -> D_q15.
     (A uniform positive scale does NOT change the argmax, so the engine is
      indifferent to it -- it only has to fit the number into 16 bits.)
  5. y = Phi @ s, expressed in the same scaled "recovery space" as D_q15.
  6. Run the OMP recovery (bit-exact argmax model + float LS) and print PRD.
  7. Save window.npz.

DEPENDENCIES (on YOUR machine)
------------------------------
    pip install numpy scipy wfdb PyWavelets matplotlib
  wfdb  -> streams the real ECG straight from PhysioNet (no manual download)
  PyWavelets -> the db4 basis. If either is missing, the script falls back
  (synthetic ECG / hand-built wavelet) and still produces a valid window.npz,
  but for the real deliverable you want both installed so s is a real heartbeat.

USAGE
-----
    python3 prepare_data.py                  # auto: real if libs present, else synthetic
    python3 prepare_data.py --record sel100  # choose a cdb record
    python3 prepare_data.py --window 3       # take the 3rd 256-sample window
    python3 prepare_data.py --synthetic      # force the synthetic heartbeat
"""
import argparse
import os
import numpy as np

WINDOW_N = 256
M_LEN = 128
N_ATOMS = 256
Q15 = 32768.0


# ===========================================================================
# 1. Get one ECG window s (256 samples), normalized so |s| < 1.
# ===========================================================================
def get_ecg_window_real(record, window_idx, local_dir=None):
    """Load a cdb record (local copy or streamed from PhysioNet) and slice a window."""
    import wfdb
    if local_dir:
        # Read a downloaded copy: local_dir holds e.g. 13649_04.hea + 13649_04.dat
        rec = wfdb.rdrecord(os.path.join(local_dir, record))
    else:
        # Stream straight from physionet.org. Different wfdb versions disagree on
        # whether the database dir is 'cdb' or 'cdb/1.0.0' -- try both.
        rec, last_err = None, None
        for pn in ("cdb", "cdb/1.0.0"):
            try:
                rec = wfdb.rdrecord(record, pn_dir=pn)
                break
            except Exception as e:
                last_err = e
        if rec is None:
            raise last_err
    sig = np.asarray(rec.p_signal)[:, 0].astype(np.float64)  # lead 0
    start = window_idx * WINDOW_N
    if start + WINDOW_N > sig.size:
        raise ValueError(f"window {window_idx} out of range for record {record} "
                         f"({sig.size} samples, so windows 0..{sig.size // WINDOW_N - 1})")
    return sig[start:start + WINDOW_N]


def get_ecg_window_synthetic(seed=0):
    """A realistic-enough single heartbeat: baseline wander + P, QRS, T waves."""
    rng = np.random.default_rng(seed)
    t = np.linspace(0, 1, WINDOW_N)

    def gauss(center, width, amp):
        return amp * np.exp(-0.5 * ((t - center) / width) ** 2)

    s = np.zeros(WINDOW_N)
    s += gauss(0.30, 0.025, 0.10)    # P wave
    s += gauss(0.47, 0.008, -0.15)   # Q
    s += gauss(0.50, 0.010, 1.00)    # R (the big spike)
    s += gauss(0.53, 0.008, -0.25)   # S
    s += gauss(0.70, 0.040, 0.30)    # T wave
    s += 0.05 * np.sin(2 * np.pi * 1.5 * t)          # baseline wander
    s += 0.003 * rng.standard_normal(WINDOW_N)       # realistic measurement noise
    return s


def normalize(s):
    """Center and scale so the window sits safely inside [-1, 1) for Q1.15."""
    s = s - np.mean(s)
    peak = np.max(np.abs(s)) + 1e-12
    return s / (peak * 1.01)


# ===========================================================================
# 2. Wavelet basis psi (256x256), orthonormal. Prefer PyWavelets; else build
#    a db4 orthonormal matrix from the filter taps by hand.
# ===========================================================================
DB4_DEC_LO = np.array([   # PyWavelets 'db4' low-pass decomposition (8 taps)
    -0.010597401784997278, 0.032883011666982945, 0.030841381835986965,
    -0.18703481171888114, -0.027983769416983849, 0.6308807679295904,
    0.7148465705525415, 0.2303778133088552])


def wavelet_matrix_pywt(levels=4):
    import pywt
    # Transform each unit vector to read off the analysis matrix columns.
    W = np.zeros((WINDOW_N, WINDOW_N))
    for i in range(WINDOW_N):
        e = np.zeros(WINDOW_N)
        e[i] = 1.0
        coeffs = pywt.wavedec(e, 'db4', level=levels, mode='periodization')
        W[:, i] = np.concatenate([c.ravel() for c in coeffs])
    # W is the analysis (forward) transform; psi = synthesis = W^T (orthonormal).
    return W.T


def _single_level(N, h):
    """One orthonormal db4 analysis level for length N (periodic boundary)."""
    g = np.array([((-1) ** k) * h[len(h) - 1 - k] for k in range(len(h))])  # QMF
    W1 = np.zeros((N, N))
    half = N // 2
    for k in range(half):
        for n in range(len(h)):
            W1[k, (2 * k + n) % N] += h[n]           # approximation rows
            W1[half + k, (2 * k + n) % N] += g[n]    # detail rows
    return W1


def wavelet_matrix_scratch(levels=4):
    """Compose L orthonormal db4 levels into a 256x256 analysis matrix."""
    W = np.eye(WINDOW_N)
    n = WINDOW_N
    for _ in range(levels):
        W1 = _single_level(n, DB4_DEC_LO)
        full = np.eye(WINDOW_N)
        full[:n, :n] = W1
        W = full @ W
        n //= 2
        if n < len(DB4_DEC_LO):
            break
    return W.T  # synthesis basis


def build_psi(levels=4):
    try:
        psi = wavelet_matrix_pywt(levels)
        src = "PyWavelets db4"
    except Exception:
        psi = wavelet_matrix_scratch(levels)
        src = "hand-built db4"
    # Orthonormality is the whole game -- verify, don't assume.
    err = np.max(np.abs(psi.T @ psi - np.eye(WINDOW_N)))
    if err > 1e-6:
        raise RuntimeError(f"psi not orthonormal ({src}): max|psi^T psi - I| = {err:.2e}")
    return psi, src


# ===========================================================================
# 3. Bit-exact hardware argmax model (matches the RTL and omp_reference.py).
# ===========================================================================
def to_q15(x):
    v = np.where(x >= 0, np.floor(x * Q15 + 0.5), np.ceil(x * Q15 - 0.5))
    return np.clip(v, -32768, 32767).astype(np.int16)


def truncate_q15(a, mac_bits):
    shift = 16 - mac_bits
    return a.astype(np.int64) if shift == 0 else (a.astype(np.int64) >> shift)


def hw_argmax(D_atom_major_q15, r_q15, mac_bits):
    Dt = truncate_q15(D_atom_major_q15, mac_bits)
    rt = truncate_q15(r_q15, mac_bits)
    acc = Dt @ rt            # (N_ATOMS,) integer inner products, atom-major
    return int(np.argmax(np.abs(acc)))


# ===========================================================================
# 4. OMP recovery (the software loop; LS in float, argmax via the HW model).
# ===========================================================================
def omp_recover(D_prime, D_q15_atom_major, y, mac_bits=16, max_iters=32, tol=1e-4):
    """
    D_prime : (M_LEN, N_ATOMS) float dictionary the C/LS uses (= D_q15/32768).
    D_q15_atom_major : (N_ATOMS, M_LEN) int16, what the engine sees.
    y       : (M_LEN,) measurements in the same space as D_prime.
    """
    r = y.astype(np.float64).copy()
    support = []
    x_hat = np.zeros(N_ATOMS)
    y_norm = np.linalg.norm(y) + 1e-30
    n_iter = 0
    for n_iter in range(1, max_iters + 1):
        # ---- the hardware step: quantize residual, ask the engine -----------
        r_scale = np.max(np.abs(r)) + 1e-12     # positive scale: argmax-invariant
        r_q15 = to_q15(r / (r_scale * 1.01))
        idx = hw_argmax(D_q15_atom_major, r_q15, mac_bits)
        if idx in support:
            n_iter -= 1
            break
        support.append(idx)
        # ---- software step: LS over the support, residual update ------------
        A = D_prime[:, support]
        c, *_ = np.linalg.lstsq(A, y, rcond=None)
        r = y - A @ c
        if np.linalg.norm(r) / y_norm < tol:
            break
    if support:
        x_hat[support] = c
    return x_hat, support, n_iter


def prd(s, s_tilde):
    return 100.0 * np.linalg.norm(s - s_tilde) / (np.linalg.norm(s) + 1e-30)


# ===========================================================================
# Main
# ===========================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--record", default="13649_04",
                    help="cdb record name (e.g. 13649_04, 13420_09). Use --list to see all.")
    ap.add_argument("--window", type=int, default=2, help="which 256-sample window (0..19)")
    ap.add_argument("--local", default=None,
                    help="directory holding a downloaded copy (e.g. ./cdb). Reads local files "
                         "instead of streaming.")
    ap.add_argument("--list", action="store_true", help="print all cdb record names and exit")
    ap.add_argument("--synthetic", action="store_true", help="force synthetic ECG")
    ap.add_argument("--levels", type=int, default=4, help="wavelet decomposition levels")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("-o", "--out", default="window.npz")
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)

    if args.list:
        import wfdb
        names = wfdb.get_record_list("cdb")
        print(f"{len(names)} cdb records:")
        for i in range(0, len(names), 8):
            print("  " + "  ".join(names[i:i + 8]))
        return

    # 1. ECG window ----------------------------------------------------------
    if args.synthetic:
        s_raw, src = get_ecg_window_synthetic(args.seed), "synthetic heartbeat"
    else:
        try:
            s_raw = get_ecg_window_real(args.record, args.window, args.local)
            where = args.local if args.local else "streamed"
            src = f"MIT-BIH cdb/{args.record} window {args.window} ({where})"
        except Exception as e:
            print(f"[wfdb unavailable: {e}]  -> falling back to synthetic ECG")
            s_raw, src = get_ecg_window_synthetic(args.seed), "synthetic heartbeat (fallback)"
    s = normalize(s_raw)
    print(f"ECG source       : {src}")

    # 2. Basis ---------------------------------------------------------------
    psi, psi_src = build_psi(args.levels)
    print(f"Wavelet basis    : {psi_src} ({args.levels} levels), orthonormal OK")

    # 3. Measurement matrix --------------------------------------------------
    Phi = rng.choice([-1.0, 1.0], size=(M_LEN, WINDOW_N))

    # 4. Dictionary, scaled into Q1.15 ---------------------------------------
    D_float = Phi @ psi                              # (128, 256)
    D_scale = np.max(np.abs(D_float)) * 1.01
    D_prime = D_float / D_scale                      # what the C/LS uses
    D_q15_meas_major = to_q15(D_prime)               # (128, 256)
    D_q15_atom_major = D_q15_meas_major.T.copy()     # (256, 128) for the engine
    D_prime_q = D_q15_meas_major.astype(np.float64) / Q15  # exact value C sees

    # 5. Measurements in the recovery space ----------------------------------
    y = (Phi @ s) / D_scale                          # = D_prime @ x_true

    # 6. Validate ------------------------------------------------------------
    print("\nRunning OMP recovery to validate PRD...")
    x_hat, support, n_iter = omp_recover(D_prime_q, D_q15_atom_major, y, mac_bits=16)
    s_tilde = psi @ x_hat
    p = prd(s, s_tilde)
    verdict = "EXCELLENT (<5%)" if p < 5 else ("VERY GOOD (<9%)" if p < 9 else "ABOVE TARGET")
    print(f"  iterations used : {n_iter}")
    print(f"  support size    : {len(support)}")
    print(f"  PRD (mac_bits=16): {p:.4f} %   [{verdict}]")

    # 7. Save ----------------------------------------------------------------
    np.savez(args.out, psi=psi, D_q15=D_q15_atom_major, y=y, s=s)
    np.save("phi.npy", Phi)
    print(f"\nWrote {args.out}: psi{psi.shape}, D_q15{D_q15_atom_major.shape} (atom-major), "
          f"y{y.shape}, s{s.shape}")
    print("Wrote phi.npy (the Bernoulli measurement matrix, for reproducibility)")
    if p >= 9:
        print("\nPRD is above 9% -- try a different --window or --record (some windows "
              "are noisier), or more --levels. Don't commit this one to the board yet.")


if __name__ == "__main__":
    main()