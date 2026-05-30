import subprocess
import sys
import socket
import struct
import time
import ctypes
import ctypes.wintypes
from collections import deque

UDP_PORT = 5006
ACK_PORT = 5007
ACK_TIMEOUT = 0.15  # seconds to wait per stage ACK
FRAMERATE = 30
JPEG_QUALITY = 31  # 2=best, 31=worst
HEIGHT = 480       # Stream height (width scales to maintain aspect ratio)

SOI = b'\xff\xd8'
EOI = b'\xff\xd9'


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
        if w <= 0 or h <= 0:
            print("Window has no visible area, defaulting to monitor 0.")
            return ("monitor", 0)
        print(f"Capturing '{title}' at {w}x{h} ({x},{y})")
        return ("window", x, y, w, h)
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
    lavfi = f"ddagrab=output_idx={monitor_idx}:framerate={FRAMERATE},hwdownload,format=bgra"
    label = f"Monitor {monitor_idx}"
else:
    _, x, y, w, h = target
    lavfi = f"ddagrab=output_idx=0:framerate={FRAMERATE}:offset_x={x}:offset_y={y}:video_size={w}x{h},hwdownload,format=bgra"
    label = f"window ({w}x{h})"

print(f"\nStreaming {label} to {ip}:{UDP_PORT} at {HEIGHT}p {FRAMERATE}fps (MJPEG)")
print("Run video_receiver.py on the receiver to watch.\n")

# UDP socket — small send buffer to avoid frame queuing
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)

ack_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ack_sock.bind(("0.0.0.0", ACK_PORT))
ack_sock.settimeout(ACK_TIMEOUT)

seq = 0
WINDOW = 60
_enc = deque(maxlen=WINDOW)   # encode wait: prev send done → frame ready
_snd = deque(maxlen=WINDOW)   # sendto() call duration
_net = deque(maxlen=WINDOW)   # RTT to ACK stage 0 (frame received by receiver)
_dec = deque(maxlen=WINDOW)   # ACK1 - ACK0 (imdecode)
_drw = deque(maxlen=WINDOW)   # ACK2 - ACK1 (imshow + waitKey)
_rtt   = deque(maxlen=WINDOW)   # RTT from sendto → ACK stage 2 (frame drawn)
_total = deque(maxlen=WINDOW)   # frame ready in sender → drawn ACK received
ack_miss = 0
total_frames = 0
fps_frames = 0
t_prev_done = None
t_stats = time.perf_counter()
t_fps_ref = time.perf_counter()

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

process = None
try:
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    buf = b""
    while True:
        chunk = process.stdout.read1(65536)
        if not chunk:
            break
        buf += chunk

        # Extract all complete frames but only send the latest one —
        # any older frames accumulated during a slow iteration are dropped.
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

        if latest_frame and len(latest_frame) <= 65495:  # 65507 - 12 byte header
            try:
                if t_prev_done is not None:
                    _enc.append((t_frame_ready - t_prev_done) / 1e6)

                header = struct.pack(">IQ", seq & 0xFFFFFFFF, t_frame_ready)
                t0 = time.perf_counter_ns()
                sock.sendto(header + latest_frame, (ip, UDP_PORT))
                t1 = time.perf_counter_ns()
                _snd.append((t1 - t0) / 1e6)
                t_prev_done = t1
                total_frames += 1
                fps_frames += 1

                # Drain stale ACKs from any previous missed frames
                ack_sock.setblocking(False)
                while True:
                    try:
                        ack_sock.recvfrom(13)
                    except Exception:
                        break
                ack_sock.settimeout(ACK_TIMEOUT)

                # Collect up to 3 stage ACKs: 0=recv, 1=decoded, 2=drawn
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
                    _total.append((t_stages[2] - t_frame_ready) / 1e6)

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
                        f"\rTotal:{a(_total)}ms  "
                        f"[Encode:{a(_enc)}ms  SendCall:{a(_snd)}ms  Net:{net_est}ms  "
                        f"Decode:{a(_dec)}ms  Draw:{a(_drw)}ms  RTT:{a(_rtt)}ms]  "
                        f"FPS:{fps:.1f}  Loss:{loss}%"
                        "          ",
                        end="", flush=True
                    )

            except OSError as e:
                print(f"\nSend error: {e}")
                break

except KeyboardInterrupt:
    print("\nStopping stream...")
finally:
    if process:
        process.terminate()
    sock.close()
    ack_sock.close()
