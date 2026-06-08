import socket
import struct
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

PORT = 5005
FMT = "<BBBB256h256hf"
EXPECTED = struct.calcsize(FMT)   # 1032

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", PORT))

# --- collect all frames for one window ---
# Frames arrive in iter_idx order; the final one has flags & 1 set.
print(f"Listening on {PORT}, collecting convergence frames...")
frames = []   # each: (iter_idx, total, recon, original, prd)
sock.settimeout(45.0)
while True:
    try:
        data, _ = sock.recvfrom(2048)
    except socket.timeout:
        print("  timed out waiting for frames; using what we have")
        break
    if len(data) != EXPECTED:
        print(f"  ! size mismatch ({len(data)}), ignoring")
        continue
    f = struct.unpack(FMT, data)
    win, iter_idx, total, flags = f[0:4]
    recon    = f[4:4+256]
    original = f[4+256:4+512]
    prd      = f[-1]
    frames.append((iter_idx, total, recon, original, prd))
    print(f"  got iter {iter_idx}/{total}  prd={prd:.2f}%"
          + ("  [FINAL]" if flags & 1 else ""))
    if flags & 1:
        break

if not frames:
    raise SystemExit("No frames received.")

# sort by iter_idx just in case UDP reordered anything
frames.sort(key=lambda fr: fr[0])
original = frames[-1][3]   # original is the same in every frame; use the last

# --- animate on a loop ---
fig, ax = plt.subplots(figsize=(10, 4))
ax.plot(original, color="0.6", linewidth=2, label="original")
(line,) = ax.plot([], [], color="tab:blue", linewidth=1.2,
                  label="reconstructed")
ax.set_xlim(0, 255)
lo = min(min(original), min(min(fr[2]) for fr in frames))
hi = max(max(original), max(max(fr[2]) for fr in frames))
pad = 0.05 * (hi - lo + 1)
ax.set_ylim(lo - pad, hi + pad)
ax.set_xlabel("sample index")
ax.set_ylabel("amplitude (raw int16)")
ax.legend(loc="upper right")
ax.grid(True, alpha=0.3)

def update(i):
    iter_idx, total, recon, _, prd = frames[i]
    line.set_data(range(256), recon)
    ax.set_title(f"OMP convergence  iter {iter_idx}/{total}   PRD = {prd:.2f}%")
    return line, ax.title

ani = FuncAnimation(fig, update, frames=len(frames),
                    interval=600, blit=False, repeat=True)
plt.tight_layout(rect=[0, 0, 1, 0.96])   # leave top 4% for the title
ani.save("convergence.gif", writer="pillow")
plt.show()