# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Imports
# ─────────────────────────────────────────────────────────────────────────────
import socket
import struct
import sys
import time
import ctypes  # Win32 APIs: find/fix the OpenCV window cursor

try:
    import cv2       # decode JPEG frames and display them in a window
    import numpy as np  # wrap raw bytes into an array that cv2.imdecode can read
except ImportError:
    print("Missing dependencies. Run: pip install opencv-python")
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Constants
# ─────────────────────────────────────────────────────────────────────────────
UDP_PORT = 5006
ACK_PORT = 5007              # sender listens here for latency ACKs
HEARTBEAT_INTERVAL = 2.0     # seconds between heartbeats sent to sender when no frames arrive

DISPLAY_WIDTH  = 1280        # initial window width  (user can resize freely)
DISPLAY_HEIGHT = 720         # initial window height

# Each received packet: [seq: 4B][timestamp_ns: 8B][JPEG data]
# Each ACK sent back:   [seq: 4B][timestamp_ns: 8B][stage: 1B]
# Stages: 0=received, 1=decoded, 2=drawn — sender uses these to measure per-stage latency.
# All timestamps are the sender's; receiver never does time calculations.

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Socket setup
# ─────────────────────────────────────────────────────────────────────────────
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)  # small receive buffer: OS drops old packets when full, preventing queuing
sock.bind(("0.0.0.0", UDP_PORT))
sock.settimeout(0.1)  # short timeout so Ctrl+C and window-close checks run even when no frames arrive
print(f"Listening on port {UDP_PORT}... (press Q in the video window to quit)")

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Letterbox helper: fit frame inside display window with black bars
# ─────────────────────────────────────────────────────────────────────────────
_canvas      = None       # reused black backing canvas (avoids reallocating every frame)
_canvas_size = (0, 0)     # tracks current canvas dimensions so we only reallocate on resize

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

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Create the display window
# ─────────────────────────────────────────────────────────────────────────────
cv2.namedWindow("RemoteGamepad", cv2.WINDOW_NORMAL)
cv2.resizeWindow("RemoteGamepad", DISPLAY_WIDTH, DISPLAY_HEIGHT)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Fix cursor: OpenCV registers its window class with a crosshair.
#   We replace it with the standard arrow on the top-level HWND and all child
#   HWNDs (the image canvas is a separate child window with its own class cursor).
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Stats and heartbeat state
# ─────────────────────────────────────────────────────────────────────────────
frames_shown   = 0   # frames displayed this stats window
frames_dropped = 0   # packets discarded by the drain loop this stats window
t_stats = time.perf_counter()
display_fps    = 0.0 # last computed FPS, drawn on each frame as an overlay
display_e2e    = 0   # latest E2E latency (ms) received from sender header, drawn on each frame

known_ack_addr    = None  # sender's (ip, ACK_PORT), learned from the first received frame
last_frame_time   = time.perf_counter()  # time of the last successfully received frame
last_heartbeat_time = 0.0  # time of the last HELO sent to the sender

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Startup drain: discard packets that arrived before we were ready
#   Frames may have accumulated in the OS socket buffer during the window/cursor
#   setup above. Drain them so we start fresh with the latest frame.
# ─────────────────────────────────────────────────────────────────────────────
sock.setblocking(False)
while True:
    try:
        sock.recvfrom(65536)
    except (BlockingIOError, OSError):
        break
sock.settimeout(0.1)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Main receive loop
# ─────────────────────────────────────────────────────────────────────────────
try:
    while True:
        try:
            data, addr = sock.recvfrom(65536)  # blocks up to 0.1s waiting for the next frame
        except socket.timeout:
            # No frame arrived — send a heartbeat to the sender so it knows we're alive.
            # Only sent if no frame (or heartbeat) has been exchanged for HEARTBEAT_INTERVAL seconds.
            if known_ack_addr is not None:
                _now = time.perf_counter()
                if _now - max(last_frame_time, last_heartbeat_time) >= HEARTBEAT_INTERVAL:
                    sock.sendto(b'HELO', known_ack_addr)  # 4-byte signal; sender recognises this as "receiver alive"
                    last_heartbeat_time = _now
            cv2.pollKey()
            if window_closed():
                break
            continue

        # ─────────────────────────────────────────────────────────────────────
        # STEP 10 — Drain backlogged frames: keep only the latest
        #   If frames accumulated while we were decoding/displaying, discard all
        #   but the newest so we never fall behind. Skipped packets time out as
        #   ACK losses on the sender side — that's intentional.
        # ─────────────────────────────────────────────────────────────────────
        sock.setblocking(False)
        try:
            while True:
                newer, newer_addr = sock.recvfrom(65536)
                data, addr = newer, newer_addr  # update to the newest packet
                frames_dropped += 1
        except (BlockingIOError, OSError):
            pass
        sock.settimeout(0.1)  # restore timeout (not setblocking(True) which would clear it)

        ack_addr = (addr[0], ACK_PORT)  # where to send ACKs back to
        known_ack_addr = ack_addr
        last_frame_time = time.perf_counter()

        if len(data) < 14:
            continue
        header = data[:12]   # seq + timestamp only — echoed back verbatim in every ACK
        display_e2e = struct.unpack(">H", data[12:14])[0]
        jpeg = data[14:]

        # ─────────────────────────────────────────────────────────────────────
        # STEP 11 — ACK stage 0: frame received (before any processing)
        # ─────────────────────────────────────────────────────────────────────
        sock.sendto(header + b'\x00', ack_addr)

        frame = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)  # decode JPEG bytes → BGR numpy array

        # ─────────────────────────────────────────────────────────────────────
        # STEP 12 — ACK stage 1: decode complete
        # ─────────────────────────────────────────────────────────────────────
        sock.sendto(header + b'\x01', ack_addr)

        if frame is not None:
            r = cv2.getWindowImageRect("RemoteGamepad")
            win_w = r[2] if r[2] > 0 else DISPLAY_WIDTH
            win_h = r[3] if r[3] > 0 else DISPLAY_HEIGHT
            display = letterbox(frame, win_w, win_h)
            if display_fps > 0:
                cv2.rectangle(display, (5, 5), (130, 58), (0, 0, 0), -1)
                cv2.putText(display, f"FPS {display_fps:.0f}", (10, 25),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2, cv2.LINE_AA)
                cv2.putText(display, f"E2E {display_e2e}ms", (10, 50),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2, cv2.LINE_AA)
            cv2.imshow("RemoteGamepad", display)

        key = cv2.pollKey()  # pump the OpenCV event loop without sleeping (avoids vsync lock)

        # ─────────────────────────────────────────────────────────────────────
        # STEP 13 — ACK stage 2: frame is on screen
        # ─────────────────────────────────────────────────────────────────────
        sock.sendto(header + b'\x02', ack_addr)

        frames_shown += 1

        # ─────────────────────────────────────────────────────────────────────
        # STEP 14 — Print stats once per second
        # ─────────────────────────────────────────────────────────────────────
        now = time.perf_counter()
        if now - t_stats >= 1.0:
            elapsed = now - t_stats
            fps = frames_shown / elapsed
            display_fps = fps
            print(f"FPS: {fps:.1f}  (dropped: {frames_dropped})")
            frames_shown   = 0
            frames_dropped = 0
            t_stats = now

        if key == ord('q') or key == ord('Q') or window_closed():
            break

except KeyboardInterrupt:
    print("\nExiting...")
finally:
    # STEP 15 — Cleanup
    cv2.destroyAllWindows()
    sock.close()
