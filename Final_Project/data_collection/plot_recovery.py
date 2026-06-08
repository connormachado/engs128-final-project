#!/usr/bin/env python3
"""
ENGS-128 Phase 4 host-side plotter.

Captures the UART dump from the board's omp_onboard.c, parses the
ORIG / RECON blocks and the PRD line, and overlays original vs.
reconstructed ECG on the same axes with the PRD in the title.

Two modes:
  1. Live capture from a serial port:
       python plot_recovery.py --port /dev/ttyUSB1 --baud 115200
  2. Parse a previously-captured text file:
       python plot_recovery.py --file uart_capture.txt

Wire format the board emits (see omp_onboard.c):
    PRD <int>.<frac>
    RECON_BEGIN
    <256 signed decimal values, one per line>
    RECON_END
    ORIG_BEGIN
    <256 signed decimal values, one per line>
    ORIG_END
    DONE.
"""

import argparse
import sys
import re

import numpy as np
import matplotlib.pyplot as plt


WINDOW_N = 256


def read_until_done(port, baud, timeout=30.0):
    """Stream lines from the serial port until 'DONE.' or timeout."""
    try:
        import serial  # pyserial
    except ImportError:
        sys.exit("pyserial not installed.  pip install pyserial")

    lines = []
    with serial.Serial(port, baud, timeout=1.0) as ser:
        import time
        t0 = time.time()
        print(f"Listening on {port} @ {baud} ... (waiting for board)")
        while time.time() - t0 < timeout:
            raw = ser.readline()
            if not raw:
                continue
            line = raw.decode("ascii", errors="replace").rstrip("\r\n")
            print(line)            # echo so you see progress live
            lines.append(line)
            if line.strip() == "DONE.":
                break
    return lines


def parse_block(lines, begin_tag, end_tag, n_expected):
    """Pull the float values between begin_tag and end_tag."""
    try:
        i0 = next(i for i, l in enumerate(lines) if l.strip() == begin_tag)
        i1 = next(i for i, l in enumerate(lines) if l.strip() == end_tag)
    except StopIteration:
        return None
    vals = []
    for l in lines[i0 + 1:i1]:
        l = l.strip()
        if not l:
            continue
        try:
            vals.append(float(l))
        except ValueError:
            # tolerate stray UART chatter inside the block
            continue
    arr = np.array(vals, dtype=float)
    if arr.size != n_expected:
        print(f"WARN: {begin_tag} had {arr.size} values, expected {n_expected}",
              file=sys.stderr)
    return arr


def parse_prd(lines):
    for l in lines:
        m = re.match(r"\s*PRD\s+(-?\d+\.\d+)", l)
        if m:
            return float(m.group(1))
    return None


def main():
    ap = argparse.ArgumentParser(description="Plot on-board ECG recovery.")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--port", help="serial port, e.g. /dev/ttyUSB1 or COM4")
    g.add_argument("--file", help="previously captured UART text dump")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--timeout", type=float, default=30.0,
                    help="serial capture timeout in seconds")
    ap.add_argument("--save", help="save figure to this path instead of show()")
    ap.add_argument("--fs", type=float, default=None,
                    help="optional sample rate (Hz) to label the x-axis in seconds")
    args = ap.parse_args()

    if args.port:
        lines = read_until_done(args.port, args.baud, args.timeout)
        # stash a copy so you don't lose a slow capture
        with open("uart_capture.txt", "w") as f:
            f.write("\n".join(lines))
        print("Saved raw capture to uart_capture.txt")
    else:
        with open(args.file) as f:
            lines = f.read().splitlines()

    recon = parse_block(lines, "RECON_BEGIN", "RECON_END", WINDOW_N)
    orig = parse_block(lines, "ORIG_BEGIN", "ORIG_END", WINDOW_N)
    prd = parse_prd(lines)

    if recon is None:
        sys.exit("Could not find RECON block in the UART dump.")
    if orig is None:
        sys.exit("Could not find ORIG block in the UART dump.")

    # recompute PRD on the host as a cross-check against the board's value
    prd_host = 100.0 * np.linalg.norm(orig - recon) / np.linalg.norm(orig)
    if prd is None:
        prd = prd_host
    print(f"PRD (board) = {prd:.4f}%   PRD (host recompute) = {prd_host:.4f}%")

    # x-axis: samples, or seconds if a sample rate was given
    if args.fs:
        x = np.arange(WINDOW_N) / args.fs
        xlabel = "Time (s)"
    else:
        x = np.arange(WINDOW_N)
        xlabel = "Sample index"

    quality = ("excellent" if prd < 5 else
               "very good" if prd < 9 else
               "needs work")

    fig, ax = plt.subplots(figsize=(11, 4.5))
    ax.plot(x, orig, label="Original", linewidth=1.6)
    ax.plot(x, recon, label="Reconstructed (on-board OMP)",
            linewidth=1.4, linestyle="--")
    ax.set_xlabel(xlabel)
    ax.set_ylabel("Amplitude")
    ax.set_title(f"ECG compressed-sensing recovery on Zybo Z7-20  "
                 f"— PRD = {prd:.2f}% ({quality})")
    ax.legend(loc="upper right")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()

    if args.save:
        fig.savefig(args.save, dpi=150)
        print(f"Figure saved to {args.save}")
    else:
        plt.show()


if __name__ == "__main__":
    main()