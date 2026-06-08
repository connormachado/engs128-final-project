import socket
import struct

PORT = 5005

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", PORT))
print(f"Listening on port {PORT}... (Ctrl-C to stop)")

# This format string MUST mirror the C struct, field for field:
#   <  = little-endian, no padding (matches #pragma pack(1) on a LE machine)
#   B  = uint8   (window_id)
#   B  = uint8   (iter_idx)
#   B  = uint8   (total_iters)
#   B  = uint8   (flags)
#   256h = 256 × int16 (the samples)
#   f  = float32 (prd)
FMT = "<BBBB256hf"
EXPECTED = struct.calcsize(FMT)   # should be 520

print(f"Expecting {EXPECTED}-byte frames")

while True:
    data, sender = sock.recvfrom(2048)
    print(f"\nGot {len(data)} bytes from {sender}")

    if len(data) != EXPECTED:
        print(f"  ! size mismatch (got {len(data)}, expected {EXPECTED}) — layout is off")
        continue

    fields = struct.unpack(FMT, data)
    window_id, iter_idx, total_iters, flags = fields[0:4]
    samples = fields[4:4+256]
    prd = fields[-1]

    print(f"  window_id={window_id}  iter={iter_idx}/{total_iters}  flags={flags}")
    print(f"  first 5 samples: {samples[:5]}")
    print(f"  last 5 samples:  {samples[-5:]}")
    print(f"  prd={prd:.3f}")