import sys
import socket
import struct
import time
import ctypes
import ctypes.wintypes
from collections import deque
import threading

try:
    import cv2
    from windows_capture import WindowsCapture, Frame, InternalCaptureControl
except ImportError:
    print("Missing dependencies. Run: pip install opencv-python windows-capture")
    sys.exit(1)

UDP_PORT = 5006
ACK_PORT = 5007         # receiver sends latency ACKs back to this port
ACK_TIMEOUT = 0.15      # seconds to wait per ACK stage before counting as lost
FRAMERATE = 160         # max frames per second to send; capped by display refresh rate
JPEG_QUALITY = 50       # 0=worst, 100=best (cv2 scale); auto-reduced if frame exceeds UDP limit
HEIGHT = 240            # output height; width auto-scaled to maintain aspect ratio

# Frame packet layout: [seq: 4B big-endian uint][timestamp_ns: 8B big-endian int64][JPEG data]
# ACK packet layout:   [seq: 4B][timestamp_ns: 8B][stage: 1B]  (receiver echoes header + stage)
# ACK stages: 0=frame received, 1=decoded (imdecode done), 2=drawn (imshow+pollKey done)


def get_monitor_count():
    return ctypes.windll.user32.GetSystemMetrics(80)  # SM_CMONITORS


def list_windows():
    windows = []

    def callback(hwnd, _):
        if ctypes.windll.user32.IsWindowVisible(hwnd):
            length = ctypes.windll.user32.GetWindowTextLengthW(hwnd)
            if length > 0:
                buf = ctypes.create_unicode_buffer(length + 1)
                ctypes.windll.user32.GetWindowTextW(hwnd, buf, length + 1)
                windows.append((hwnd, buf.value))
        return True

    proc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.wintypes.HWND, ctypes.wintypes.LPARAM)
    ctypes.windll.user32.EnumWindows(proc(callback), 0)
    return windows


def get_window_rect(hwnd):
    rect = ctypes.wintypes.RECT()
    ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect))
    return rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top


def pick_capture_target():
    monitor_count = get_monitor_count()
    windows = list_windows()

    print("\n--- Monitors ---")
    for i in range(monitor_count):
        label = " (primary)" if i == 0 else ""
        print(f"{i}: Monitor {i}{label}")

    print("\n--- Windows ---")
    for i, (_, title) in enumerate(windows, start=monitor_count):
        print(f"{i}: {title}")

    choice = input("\nSelect source: ").strip()

    try:
        idx = int(choice)
        if idx < monitor_count:
            return ("monitor", idx)
        hwnd, title = windows[idx - monitor_count]
        x, y, w, h = get_window_rect(hwnd)
        print(f"Capturing '{title}' at {w}x{h} ({x},{y})")
        return ("window", hwnd, title)
    except (ValueError, IndexError):
        print("Invalid selection, defaulting to monitor 0.")
        return ("monitor", 0)


if len(sys.argv) > 1:
    ip = sys.argv[1].strip()
else:
    ip = input("Enter the receiver's IP address: ").strip()
if ip == "":
    ip = "127.0.0.1"

if "." not in ip:
    print("Invalid IP address. Exiting...")
    sys.exit(1)

target = pick_capture_target()

if target[0] == "monitor":
    monitor_idx = target[1]
    label = f"Monitor {monitor_idx}"
    hwnd = None
else:
    _, hwnd, title = target
    label = f"window '{title}'"

print(f"\nStreaming {label} to {ip}:{UDP_PORT} at {HEIGHT}p JPEG q={JPEG_QUALITY} (cap: {FRAMERATE}fps)")
print("Run video_receiver.py on the receiver to watch.\n")

# WGC delivers frames on a background thread; we store only the latest here.
# The send loop always consumes the most recent frame, dropping any that piled up.
_latest_frame = None
_frame_lock = threading.Lock()
_frame_event = threading.Event()  # set by callback the moment a frame is stored
_stop_requested = False
_capture_closed = threading.Event()


def _current_window_title():
    """Read the live title from the stored hwnd — stable across browser title changes."""
    buf = ctypes.create_unicode_buffer(512)
    ctypes.windll.user32.GetWindowTextW(hwnd, buf, 512)
    return buf.value or title  # fall back to original title if empty


def _make_capture():
    if target[0] == "monitor":
        cap = WindowsCapture(cursor_capture=False, draw_border=False, monitor_index=monitor_idx + 1)
    else:
        cap = WindowsCapture(cursor_capture=False, draw_border=False,
                             window_name=_current_window_title())

    @cap.event
    def on_frame_arrived(frame: Frame, _capture_control: InternalCaptureControl):
        global _latest_frame
        try:
            # Resize in the callback — cv2.resize allocates a fresh numpy array,
            # decoupling from WGC memory without the slow bytes() copy of the
            # full native-resolution frame. The main loop only ever sees small frames.
            h, w = frame.height, frame.width
            w_scaled = max(2, int(w * HEIGHT / h) & ~1)
            scaled = cv2.resize(frame.frame_buffer, (w_scaled, HEIGHT),
                                interpolation=cv2.INTER_LINEAR)
            with _frame_lock:
                _latest_frame = scaled
            _frame_event.set()
        except Exception as e:
            print(f"\nFrame callback error: {e}")

    @cap.event
    def on_closed():
        _capture_closed.set()

    return cap


def _capture_manager():
    """Restarts the WGC session whenever it closes (e.g. window resize/maximize)."""
    while not _stop_requested:
        _capture_closed.clear()
        cap = _make_capture()
        try:
            cap.start_free_threaded()
        except AttributeError:
            threading.Thread(target=cap.start, daemon=True).start()
        _capture_closed.wait()          # block until WGC closes the session
        if _stop_requested:
            break
        time.sleep(0.05)                # brief pause before restarting


threading.Thread(target=_capture_manager, daemon=True).start()

# Small send buffer prevents the OS from queuing multiple frames ahead
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)

# Separate socket for receiving ACKs so the send socket stays unblocked
ack_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ack_sock.bind(("0.0.0.0", ACK_PORT))
ack_sock.settimeout(ACK_TIMEOUT)

seq = 0
WINDOW = 60  # rolling average window (frames)

# Latency sample buffers — all values in milliseconds
_enc   = deque(maxlen=WINDOW)  # prev-send-done → frame ready (~1/fps, WGC frame interval)
_snd   = deque(maxlen=WINDOW)  # sendto() syscall duration
_net   = deque(maxlen=WINDOW)  # RTT to ACK stage 0 ÷ 2 = one-way network estimate
_dec   = deque(maxlen=WINDOW)  # ACK1 − ACK0: imdecode time on receiver
_drw   = deque(maxlen=WINDOW)  # ACK2 − ACK1: imshow+pollKey time on receiver
_rtt   = deque(maxlen=WINDOW)  # sendto → ACK2: round-trip to frame drawn
_total = deque(maxlen=WINDOW)  # prev-send-done → ACK2: viewer's true end-to-end wait

ack_miss = 0
total_frames = 0
fps_frames = 0
t_prev_done = None       # timestamp of the most recent sendto() completion
_t_last_frame_sent = None
_frame_interval_ns = int(1e9 / FRAMERATE)
t_stats = time.perf_counter()
t_fps_ref = time.perf_counter()

try:
    while not _stop_requested:
        with _frame_lock:
            frame = _latest_frame
            _latest_frame = None

        if frame is None:
            _frame_event.wait(timeout=0.1)
            _frame_event.clear()
            continue

        t_frame_ready = time.perf_counter_ns()

        # Rate limiter: drop frames that arrive faster than FRAMERATE.
        # Effective FPS = min(FRAMERATE, display_refresh_rate).
        if _t_last_frame_sent is not None:
            if (t_frame_ready - _t_last_frame_sent) < _frame_interval_ns:
                continue

        # Encode to JPEG — frame is pre-scaled in the callback; drop alpha (imencode expects BGR)
        # Reduce quality in steps until the frame fits within the UDP payload limit.
        frame_bgr = frame[:, :, :3]
        jpeg_bytes = None
        quality = JPEG_QUALITY
        while quality >= 5:
            ok, jpeg_buf = cv2.imencode('.jpg', frame_bgr, [cv2.IMWRITE_JPEG_QUALITY, quality])
            if ok and len(jpeg_buf) <= 65495:
                jpeg_bytes = jpeg_buf.tobytes()
                break
            quality -= 10
        if jpeg_bytes is None:
            continue  # couldn't compress small enough even at minimum quality, skip frame

        try:
            # t_enc_start is when the previous frame finished sending — start of the
            # encode wait period, and therefore the earliest a screen change could be captured.
            t_enc_start = t_prev_done
            if t_enc_start is not None:
                _enc.append((t_frame_ready - t_enc_start) / 1e6)

            header = struct.pack(">IQ", seq & 0xFFFFFFFF, t_frame_ready)
            t0 = time.perf_counter_ns()
            sock.sendto(header + jpeg_bytes, (ip, UDP_PORT))
            t1 = time.perf_counter_ns()
            _snd.append((t1 - t0) / 1e6)
            total_frames += 1
            fps_frames += 1

            # Drain any stale ACKs left over from a previously missed frame
            # so we don't misattribute them to this frame's seq number.
            ack_sock.setblocking(False)
            while True:
                try:
                    ack_sock.recvfrom(13)
                except Exception:
                    break
            ack_sock.settimeout(ACK_TIMEOUT)

            # Collect up to 3 stage ACKs. Break early on timeout — if one
            # stage is lost the remaining ones are likely lost too.
            t_stages = {}
            for _ in range(3):
                try:
                    data, _ = ack_sock.recvfrom(13)
                    if len(data) == 13:
                        ack_seq, _, stage = struct.unpack(">IQB", data)
                        if ack_seq == (seq & 0xFFFFFFFF):
                            t_stages[stage] = time.perf_counter_ns()
                except socket.timeout:
                    ack_miss += 1
                    break

            # t_prev_done marks when this frame is fully done (sent + ACKs received),
            # so Encode for the next frame measures only WGC delivery wait, not ACK wait.
            t_prev_done = time.perf_counter_ns()

            if 0 in t_stages:
                _net.append((t_stages[0] - t0) / 1e6)
            if 0 in t_stages and 1 in t_stages:
                _dec.append((t_stages[1] - t_stages[0]) / 1e6)
            if 1 in t_stages and 2 in t_stages:
                _drw.append((t_stages[2] - t_stages[1]) / 1e6)
            if 2 in t_stages:
                _rtt.append((t_stages[2] - t0) / 1e6)
                if t_enc_start is not None:
                    _total.append((t_stages[2] - t_enc_start) / 1e6)

            _t_last_frame_sent = t_frame_ready
            seq += 1

            now = time.perf_counter()
            if now - t_stats >= 1.0:
                fps = fps_frames / (now - t_fps_ref)
                fps_frames = 0
                t_fps_ref = now
                t_stats = now

                def a(d):
                    return f"{sum(d)/len(d):.1f}" if d else "---"
                net_est = f"{sum(_net)/len(_net)/2:.1f}" if _net else "---"
                loss = f"{100*ack_miss/total_frames:.1f}" if total_frames else "0.0"
                print(
                    f"Total:{a(_total)}ms  "
                    f"[Encode:{a(_enc)}ms  SendCall:{a(_snd)}ms  Net:{net_est}ms  "
                    f"Decode:{a(_dec)}ms  Draw:{a(_drw)}ms  RTT:{a(_rtt)}ms]  "
                    f"FPS:{fps:.1f}  Loss:{loss}%"
                )

        except OSError as e:
            print(f"\nSend error: {e}")
            break

except KeyboardInterrupt:
    _stop_requested = True
    print("\nStopping stream...")
finally:
    sock.close()
    ack_sock.close()
