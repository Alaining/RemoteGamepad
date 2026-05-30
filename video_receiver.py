import socket
import sys
import time

try:
    import cv2
    import numpy as np
except ImportError:
    print("Missing dependencies. Run: pip install opencv-python")
    sys.exit(1)

UDP_PORT = 5006
ACK_PORT = 5007  # sender listens here for latency ACKs

DISPLAY_WIDTH  = 1280
DISPLAY_HEIGHT = 720

# Each received packet: [seq: 4B][timestamp_ns: 8B][JPEG data]
# Each ACK sent back:   [seq: 4B][timestamp_ns: 8B][stage: 1B]
# Stages: 0=received, 1=decoded, 2=drawn — sender uses these to measure per-stage latency.
# All timestamps are the sender's; receiver never does time calculations.

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
sock.bind(("0.0.0.0", UDP_PORT))
print(f"Listening on port {UDP_PORT}... (press Q in the video window to quit)")

_canvas = np.zeros((DISPLAY_HEIGHT, DISPLAY_WIDTH, 3), dtype=np.uint8)

def letterbox(frame):
    h, w = frame.shape[:2]
    scale = min(DISPLAY_WIDTH / w, DISPLAY_HEIGHT / h)
    nw, nh = int(w * scale), int(h * scale)
    resized = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_LINEAR)
    _canvas[:] = 0  # clear black bars from previous frame
    y = (DISPLAY_HEIGHT - nh) // 2
    x = (DISPLAY_WIDTH  - nw) // 2
    _canvas[y:y+nh, x:x+nw] = resized
    return _canvas

cv2.namedWindow("RemoteGamepad", cv2.WINDOW_NORMAL)
cv2.resizeWindow("RemoteGamepad", DISPLAY_WIDTH, DISPLAY_HEIGHT)

frames_shown   = 0
frames_dropped = 0
t_stats = time.perf_counter()

try:
    while True:
        data, addr = sock.recvfrom(65536)

        # Drain any backlogged frames — discard all but the latest so we never
        # fall behind. Frames skipped here will time out as ACK losses on the sender.
        sock.setblocking(False)
        try:
            while True:
                newer, newer_addr = sock.recvfrom(65536)
                data, addr = newer, newer_addr
                frames_dropped += 1
        except (BlockingIOError, OSError):
            pass
        sock.setblocking(True)

        ack_addr = (addr[0], ACK_PORT)

        if len(data) < 12:
            continue
        header = data[:12]   # seq + timestamp, echoed back verbatim in every ACK
        jpeg = data[12:]

        # Stage 0: frame received, no processing yet
        sock.sendto(header + b'\x00', ack_addr)

        frame = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)

        # Stage 1: decode complete
        sock.sendto(header + b'\x01', ack_addr)

        if frame is not None:
            cv2.imshow("RemoteGamepad", letterbox(frame))

        key = cv2.pollKey()  # pumps the OpenCV event loop without sleeping (avoids vsync lock)

        # Stage 2: frame on screen
        sock.sendto(header + b'\x02', ack_addr)

        frames_shown += 1

        now = time.perf_counter()
        if now - t_stats >= 1.0:
            elapsed = now - t_stats
            fps = frames_shown / elapsed
            print(f"FPS: {fps:.1f}  (dropped: {frames_dropped})")
            frames_shown   = 0
            frames_dropped = 0
            t_stats = now

        if key == ord('q') or key == ord('Q'):
            break

except KeyboardInterrupt:
    print("\nExiting...")
finally:
    cv2.destroyAllWindows()
    sock.close()
