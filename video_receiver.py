import socket
import sys
import time
import ctypes

try:
    import cv2
    import numpy as np
except ImportError:
    print("Missing dependencies. Run: pip install opencv-python")
    sys.exit(1)

UDP_PORT = 5006
ACK_PORT = 5007  # sender listens here for latency ACKs
HEARTBEAT_INTERVAL = 2.0  # seconds between heartbeats sent to sender when no frames arrive

DISPLAY_WIDTH  = 1280
DISPLAY_HEIGHT = 720

# Each received packet: [seq: 4B][timestamp_ns: 8B][JPEG data]
# Each ACK sent back:   [seq: 4B][timestamp_ns: 8B][stage: 1B]
# Stages: 0=received, 1=decoded, 2=drawn — sender uses these to measure per-stage latency.
# All timestamps are the sender's; receiver never does time calculations.

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
sock.bind(("0.0.0.0", UDP_PORT))
sock.settimeout(0.1)  # allows Ctrl+C and window-close checks even when no frames arrive
print(f"Listening on port {UDP_PORT}... (press Q in the video window to quit)")

_canvas      = None
_canvas_size = (0, 0)

def letterbox(frame, win_w, win_h):
    global _canvas, _canvas_size
    h, w = frame.shape[:2]
    scale = min(win_w / w, win_h / h)
    nw, nh = int(w * scale), int(h * scale)
    resized = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_LINEAR)
    if _canvas_size != (win_w, win_h):
        _canvas      = np.zeros((win_h, win_w, 3), dtype=np.uint8)
        _canvas_size = (win_w, win_h)
    else:
        _canvas[:] = 0
    y = (win_h - nh) // 2
    x = (win_w  - nw) // 2
    _canvas[y:y+nh, x:x+nw] = resized
    return _canvas

def window_closed():
    return cv2.getWindowProperty("RemoteGamepad", cv2.WND_PROP_VISIBLE) < 1

cv2.namedWindow("RemoteGamepad", cv2.WINDOW_NORMAL)
cv2.resizeWindow("RemoteGamepad", DISPLAY_WIDTH, DISPLAY_HEIGHT)

# Fix cursor: OpenCV registers its window class with a crosshair cursor.
# We change GCLP_HCURSOR on the top-level window AND all child windows
# (the image area is a child HWND with its own class cursor).
_arrow = ctypes.windll.user32.LoadCursorW(None, 32512)  # IDC_ARROW
_hwnd = 0
for _ in range(10):                                      # wait up to 100ms for window to exist
    cv2.waitKey(10)
    _hwnd = ctypes.windll.user32.FindWindowW(None, "RemoteGamepad")
    if _hwnd:
        break
if _hwnd:
    ctypes.windll.user32.SetClassLongPtrW(_hwnd, -12, _arrow)  # GCLP_HCURSOR on parent
    _EnumProc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    @_EnumProc
    def _fix_child(child, _):
        ctypes.windll.user32.SetClassLongPtrW(child, -12, _arrow)
        return True
    ctypes.windll.user32.EnumChildWindows(_hwnd, _fix_child, 0)


frames_shown   = 0
frames_dropped = 0
t_stats = time.perf_counter()

known_ack_addr = None   # sender's (ip, ACK_PORT), learned from first received frame
last_frame_time = time.perf_counter()
last_heartbeat_time = 0.0

# Drain any packets buffered by the OS while the receiver was not running,
# including frames that arrived during the window/cursor setup above.
sock.setblocking(False)
while True:
    try:
        sock.recvfrom(65536)
    except (BlockingIOError, OSError):
        break
sock.settimeout(0.1)

try:
    while True:
        try:
            data, addr = sock.recvfrom(65536)
        except socket.timeout:
            # No frame arrived — send heartbeat to sender so it knows we're alive
            if known_ack_addr is not None:
                _now = time.perf_counter()
                if _now - max(last_frame_time, last_heartbeat_time) >= HEARTBEAT_INTERVAL:
                    sock.sendto(b'HELO', known_ack_addr)
                    last_heartbeat_time = _now
            cv2.pollKey()
            if window_closed():
                break
            continue

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
        sock.settimeout(0.1)  # restore timeout (not setblocking(True) which would clear it)

        ack_addr = (addr[0], ACK_PORT)
        known_ack_addr = ack_addr
        last_frame_time = time.perf_counter()

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
            r = cv2.getWindowImageRect("RemoteGamepad")
            win_w = r[2] if r[2] > 0 else DISPLAY_WIDTH
            win_h = r[3] if r[3] > 0 else DISPLAY_HEIGHT
            cv2.imshow("RemoteGamepad", letterbox(frame, win_w, win_h))

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

        if key == ord('q') or key == ord('Q') or window_closed():
            break

except KeyboardInterrupt:
    print("\nExiting...")
finally:
    cv2.destroyAllWindows()
    sock.close()
