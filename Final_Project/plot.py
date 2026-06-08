# import socket
# import struct
# import matplotlib.pyplot as plt

# PORT = 5005

# # now: 4 bytes + 256 recon + 256 original + 1 float
# FMT = "<BBBB256h256hf"
# EXPECTED = struct.calcsize(FMT)   # 1032

# sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
# sock.bind(("0.0.0.0", PORT))
# print(f"Listening on port {PORT}, waiting for one frame...")

# while True:
#     data, sender = sock.recvfrom(2048)
#     if len(data) != EXPECTED:
#         print(f"  ! size mismatch ({len(data)} vs {EXPECTED}), ignoring")
#         continue
#     fields = struct.unpack(FMT, data)
#     window_id, iter_idx, total_iters, flags = fields[0:4]
#     recon    = fields[4:4+256]
#     original = fields[4+256:4+512]
#     prd = fields[-1]
#     print(f"Got window {window_id}: prd={prd:.2f}")
#     break

# plt.figure(figsize=(10, 4))
# plt.plot(original, color="0.6", linewidth=2, label="original")        # grey, behind
# plt.plot(recon,    color="tab:blue", linewidth=1.2, label="reconstructed")
# plt.title(f"window {window_id}   PRD = {prd:.2f}%")
# plt.xlabel("sample index")
# plt.ylabel("amplitude (raw int16)")
# plt.legend()
# plt.grid(True, alpha=0.3)
# plt.tight_layout()
# plt.show()

import socket
import struct

PORT = 5005
FMT = "<BBBB256h256hf"
EXPECTED = struct.calcsize(FMT)   # 1032

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", PORT))
sock.settimeout(10.0)
print(f"Listening on {PORT}. Expecting 2 frames (probe + final)...")

count = 0
while True:
    try:
        data, sender = sock.recvfrom(2048)
    except socket.timeout:
        print(f"\nTimed out. Received {count} frame(s) total.")
        break
    if len(data) != EXPECTED:
        print(f"  ! size mismatch ({len(data)} vs {EXPECTED}), ignoring")
        continue
    win, iter_idx, total, flags = struct.unpack(FMT, data)[0:4]
    prd = struct.unpack(FMT, data)[-1]
    count += 1
    tag = "FINAL" if flags & 1 else "probe"
    print(f"  frame #{count}: win={win} iter_idx={iter_idx} total={total} "
          f"flags={flags} ({tag})  prd={prd:.2f}%")