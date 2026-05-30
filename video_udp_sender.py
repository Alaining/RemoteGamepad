import subprocess
import sys
import socket
import struct
import time
import ctypes
import ctypes.wintypes
from collections import deque

UDP_PORT = 5006
ACK_PORT = 5007         # receiver sends latency ACKs back to this port
ACK_TIMEOUT = 0.15      # seconds to wait per ACK stage before counting as lost
FRAMERATE = 120
JPEG_QUALITY = 31       # 2=best, 31=worst
HEIGHT = 720            # stream height; width scales to maintain aspect ratio

# JPEG frame delimiters used to extract frames from the ffmpeg byte stream
SOI = b'\xff\xd8'
EOI = b'\xff\xd9'

# Frame packet layout: [seq: 4B big-endian uint][timestamp_ns: 8B big-endian int64][JPEG data]
# ACK packet layout:   [seq: 4B][timestamp_ns: 8B][stage: 1B]  (receiver echoes header + stage)
# ACK stages: 0=frame received, 1=decoded (imdecode done), 2=drawn (imshow+waitKey done)


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
    x, y = rect.left, rect.top
    w, h = rect.right - rect.left, rect.bottom - rect.top
    return x, y, w, h


def get_window_visual_rect(hwnd):
    """Physical pixel bounds of the visible window, excluding the DWM shadow frame."""
    rect = ctypes.wintypes.RECT()
    ctypes.windll.dwmapi.DwmGetWindowAttribute(
        hwnd, 9,  # DWMWA_EXTENDED_FRAME_BOUNDS
        ctypes.byref(rect), ctypes.sizeof(rect)
    )
    return rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top


def set_topmost(hwnd, enable):
    flags = 0x0002 | 0x0001 | 0x0010  # SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
    z_order = -1 if enable else -2    # HWND_TOPMOST / HWND_NOTOPMOST
    ctypes.windll.user32.SetWindowPos(hwnd, z_order, 0, 0, 0, 0, flags)


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


def build_window_lavfi(hwnd):
    x, y, w, h = get_window_visual_rect(hwnd)
    if w <= 0 or h <= 0:
        return None, None
    lavfi = f"ddagrab=output_idx=0:framerate={FRAMERATE}:offset_x={x}:offset_y={y}:video_size={w}x{h},hwdownload,format=bgra"
    return lavfi, (x, y, w, h)


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
    base_lavfi = f"ddagrab=output_idx={monitor_idx}:framerate={FRAMERATE},hwdownload,format=bgra"
    label = f"Monitor {monitor_idx}"
    hwnd = None
else:
    _, hwnd, title = target
    base_lavfi = None  # built fresh each time from current window rect
    label = f"window '{title}'"

print(f"\nStreaming {label} to {ip}:{UDP_PORT} at {HEIGHT}p {FRAMERATE}fps (MJPEG)")
print("Run video_receiver.py on the receiver to watch.\n")

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
_enc   = deque(maxlen=WINDOW)  # prev-send-done → frame ready: inter-frame interval (~1/fps)
_snd   = deque(maxlen=WINDOW)  # sendto() syscall duration
_net   = deque(maxlen=WINDOW)  # RTT to ACK stage 0 ÷ 2 = one-way network estimate
_dec   = deque(maxlen=WINDOW)  # ACK1 − ACK0: imdecode time on receiver
_drw   = deque(maxlen=WINDOW)  # ACK2 − ACK1: imshow+waitKey time on receiver
_rtt   = deque(maxlen=WINDOW)  # sendto → ACK2: round-trip to frame drawn
_total = deque(maxlen=WINDOW)  # prev-send-done → ACK2: includes encode wait, the viewer's true wait

ack_miss = 0
total_frames = 0
fps_frames = 0
t_prev_done = None  # timestamp of the most recent sendto() completion
t_stats = time.perf_counter()
t_fps_ref = time.perf_counter()

process = None
try:
    while True:  # outer loop: restarts ffmpeg after minimization
        # For window capture, wait until the window is restored and get its current rect
        if hwnd is not None:
            while ctypes.windll.user32.IsIconic(hwnd):
                time.sleep(0.05)
            lavfi, current_rect = build_window_lavfi(hwnd)
            if lavfi is None:
                time.sleep(0.1)
                continue  # window rect not usable yet, retry
            set_topmost(hwnd, True)  # keep target window above others during capture
            print("Starting stream...")
        else:
            lavfi = base_lavfi

        cmd = [
            "ffmpeg",
            "-f", "lavfi",
            "-i", lavfi,
            "-vf", f"scale=-2:{HEIGHT},format=yuvj420p",
            "-c:v", "mjpeg",
            "-q:v", str(JPEG_QUALITY),
            "-f", "image2pipe",
            "pipe:1",
        ]

        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        buf = b""
        needs_restart = False

        while True:
            if hwnd is not None:
                if ctypes.windll.user32.IsIconic(hwnd):
                    print("\nWindow minimized, pausing stream...")
                    needs_restart = True
                    break
                # Restart ffmpeg if the window moved or resized
                if get_window_visual_rect(hwnd) != current_rect:
                    needs_restart = True
                    break

            chunk = process.stdout.read1(65536)
            if not chunk:
                break  # ffmpeg exited
            buf += chunk

            # Parse all complete JPEG frames from the buffer; keep only the latest
            # to drop frames that piled up while we were waiting for ACKs.
            latest_frame = None
            t_frame_ready = None
            while True:
                start = buf.find(SOI)
                if start == -1:
                    buf = b""
                    break
                end = buf.find(EOI, start + 2)
                if end == -1:
                    if start > 0:
                        buf = buf[start:]
                    break
                latest_frame = buf[start:end + 2]
                t_frame_ready = time.perf_counter_ns()
                buf = buf[end + 2:]

            if latest_frame and len(latest_frame) <= 65495:  # 65507 max UDP payload − 12B header
                try:
                    # t_enc_start is when the previous frame finished sending — the moment
                    # ffmpeg started working on this frame from the viewer's perspective.
                    t_enc_start = t_prev_done
                    if t_enc_start is not None:
                        _enc.append((t_frame_ready - t_enc_start) / 1e6)

                    header = struct.pack(">IQ", seq & 0xFFFFFFFF, t_frame_ready)
                    t0 = time.perf_counter_ns()
                    sock.sendto(header + latest_frame, (ip, UDP_PORT))
                    t1 = time.perf_counter_ns()
                    _snd.append((t1 - t0) / 1e6)
                    t_prev_done = t1
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

        process.terminate()
        process.wait()
        process = None

        if hwnd is not None:
            set_topmost(hwnd, False)  # restore normal Z-order
        if not needs_restart:
            break  # ffmpeg exited for a non-minimization reason, stop

except KeyboardInterrupt:
    print("\nStopping stream...")
finally:
    if process:
        process.terminate()
    sock.close()
    ack_sock.close()
