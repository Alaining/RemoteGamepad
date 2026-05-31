import subprocess
import sys
import socket
import struct
import time
import msvcrt
import ctypes
import ctypes.wintypes
from collections import deque

UDP_PORT = 5006
ACK_PORT = 5007         # receiver sends latency ACKs back to this port
ACK_TIMEOUT = 0.15        # seconds to wait per ACK stage before counting as lost
MAX_CONSECUTIVE_MISS = 5  # frames with zero ACKs before pausing (~5 × 0.15s ≈ 0.75s)
PROBE_INTERVAL = 2.0      # seconds between probe frames sent while receiver is gone
FRAMERATE = 160         # capture and stream frame rate
JPEG_QUALITY = 20       # 2=best, 31=worst (ffmpeg -q:v scale)
HEIGHT = 480            # stream height; width auto-scaled to maintain aspect ratio

# JPEG frame delimiters used to extract frames from the ffmpeg byte stream
SOI = b'\xff\xd8'
EOI = b'\xff\xd9'

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


def get_window_visual_rect(hwnd):
    """Physical pixel bounds of the visible window, excluding the DWM shadow frame."""
    rect = ctypes.wintypes.RECT()
    ctypes.windll.dwmapi.DwmGetWindowAttribute(
        hwnd, 9,  # DWMWA_EXTENDED_FRAME_BOUNDS
        ctypes.byref(rect), ctypes.sizeof(rect)
    )
    return rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top


def set_topmost(hwnd, enable):
    """Keep the window on top so ddagrab captures only it, no overlapping windows."""
    flags = 0x0002 | 0x0001 | 0x0010  # SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE
    ctypes.windll.user32.SetWindowPos(hwnd, -1 if enable else -2, 0, 0, 0, 0, flags)


def wait_for_window_stable(hwnd):
    """Wait for the user to finish dragging/resizing before restarting the stream."""
    VK_LBUTTON = 0x01
    if ctypes.windll.user32.GetAsyncKeyState(VK_LBUTTON) & 0x8000:
        print("Window moving, waiting...")
        while ctypes.windll.user32.GetAsyncKeyState(VK_LBUTTON) & 0x8000:
            time.sleep(0.05)
    # Wait for the rect to stop changing (covers resize animations too)
    prev = get_window_visual_rect(hwnd)
    while True:
        time.sleep(0.1)
        curr = get_window_visual_rect(hwnd)
        if curr == prev:
            break
        prev = curr


def drain_pipe(pipe_raw):
    """Read all currently buffered pipe data without blocking (Windows only).
    Operates on the raw FileIO to bypass Python's BufferedReader, so PeekNamedPipe
    accurately reflects all unread bytes and no frames hide in Python's IO buffer."""
    avail = ctypes.c_ulong(0)
    handle = ctypes.c_void_p(msvcrt.get_osfhandle(pipe_raw.fileno()))
    data = b""
    while True:
        ctypes.windll.kernel32.PeekNamedPipe(handle, None, 0, None, ctypes.byref(avail), None)
        if avail.value == 0:
            break
        chunk = pipe_raw.read(min(65536, avail.value))
        if chunk:
            data += chunk
    return data


def build_window_lavfi(hwnd):
    """Build a ddagrab lavfi string from the window's current visible bounds."""
    x, y, w, h = get_window_visual_rect(hwnd)
    if w <= 0 or h <= 0:
        return None, None
    lavfi = (
        f"ddagrab=output_idx=0:framerate={FRAMERATE}"
        f":offset_x={x}:offset_y={y}:video_size={w}x{h}"
        f",hwdownload,format=bgra"
    )
    return lavfi, (x, y, w, h)


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
    base_lavfi = f"ddagrab=output_idx={monitor_idx}:framerate={FRAMERATE},hwdownload,format=bgra"
    label = f"Monitor {monitor_idx}"
    hwnd = None
else:
    _, hwnd, title = target
    base_lavfi = None  # built fresh each restart from current window rect
    label = f"window '{title}'"

print(f"\nStreaming {label} to {ip}:{UDP_PORT} at {HEIGHT}p {FRAMERATE}fps (MJPEG q={JPEG_QUALITY})")
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
_enc   = deque(maxlen=WINDOW)  # prev-done → frame ready: WGC/pipe delivery wait
_snd   = deque(maxlen=WINDOW)  # sendto() syscall duration
_net   = deque(maxlen=WINDOW)  # RTT to ACK stage 0 ÷ 2 = one-way network estimate
_dec   = deque(maxlen=WINDOW)  # ACK1 − ACK0: imdecode time on receiver
_drw   = deque(maxlen=WINDOW)  # ACK2 − ACK1: imshow+pollKey time on receiver
_rtt   = deque(maxlen=WINDOW)  # sendto → ACK2: round-trip to frame drawn
_total = deque(maxlen=WINDOW)  # prev-done → ACK2: viewer's true end-to-end wait

ack_miss = 0
total_frames = 0
fps_frames = 0
t_prev_done = None  # set after ACK collection; Encode measures from here to next frame
t_stats = time.perf_counter()
t_fps_ref = time.perf_counter()

receiver_ready = True
consecutive_miss = 0       # frames with zero ACKs in a row; resets on any ACK or heartbeat
last_receiver_contact = time.perf_counter()
last_probe_time = 0.0

process = None
needs_restart = False
try:
    while True:  # outer loop: restarts ffmpeg after window move/resize/minimize
        if hwnd is not None:
            # Bail out if the window was closed entirely
            if not ctypes.windll.user32.IsWindow(hwnd):
                print("Window closed, stopping.")
                break
            # If we're restarting due to a move/resize, wait for it to finish
            if needs_restart and not ctypes.windll.user32.IsIconic(hwnd):
                wait_for_window_stable(hwnd)
            # Wait for window to be restored if minimized
            while ctypes.windll.user32.IsIconic(hwnd):
                time.sleep(0.05)
            lavfi, current_rect = build_window_lavfi(hwnd)
            if lavfi is None:
                time.sleep(0.1)
                continue  # window rect not usable yet, retry
            set_topmost(hwnd, True)
            print("Starting stream...")
        else:
            lavfi = base_lavfi
            current_rect = None

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
        stdout_raw = process.stdout.raw  # bypass Python's BufferedReader entirely
        buf = b""
        needs_restart = False
        _hold_until_ns = time.perf_counter_ns() + 50_000_000  # 50ms blackout after ffmpeg starts

        while True:
            # Check window state before blocking on the pipe
            if hwnd is not None:
                if ctypes.windll.user32.IsIconic(hwnd):
                    print("\nWindow minimized, pausing stream...")
                    needs_restart = True
                    break
                if get_window_visual_rect(hwnd) != current_rect:
                    needs_restart = True
                    break

            chunk = stdout_raw.read(65536)  # one OS read, no Python IO buffering
            if not chunk:
                break
            buf += chunk + drain_pipe(stdout_raw)  # drain any backlog without blocking

            # Extract all complete JPEG frames; keep only the latest —
            # frames that piled up during ACK wait are dropped.
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

            if latest_frame and len(latest_frame) <= 65495:  # 65507 max UDP − 12B header
                _now_ns = time.perf_counter_ns()
                if hwnd is not None and ctypes.windll.user32.GetForegroundWindow() != hwnd:
                    _hold_until_ns = _now_ns + 50_000_000  # extend 50ms blackout on every unfocused frame
                    continue

                if _now_ns < _hold_until_ns:
                    continue  # inside blackout window (startup or focus regain)

                if not receiver_ready:
                    # Drain ack_sock and look for a genuine "alive" signal:
                    # - probe ACK: 13-byte packet whose seq matches our current probe seq
                    # - receiver heartbeat: b'HELO' sent proactively by the receiver
                    # Delayed ACKs from frames sent before the disconnect have a lower seq
                    # and are therefore ignored, preventing false resumes.
                    ack_sock.setblocking(False)
                    _resumed = False
                    while True:
                        try:
                            _pkt, _ = ack_sock.recvfrom(64)
                            _is_probe_ack = (len(_pkt) == 13 and
                                             struct.unpack(">I", _pkt[:4])[0] == (seq & 0xFFFFFFFF))
                            if _is_probe_ack or _pkt == b'HELO':
                                _resumed = True
                        except (BlockingIOError, OSError):
                            break
                    ack_sock.settimeout(ACK_TIMEOUT)
                    if _resumed:
                        consecutive_miss = 0
                        receiver_ready = True
                        print("\nReceiver ready, resuming stream.")
                        continue
                    # Send a probe frame every PROBE_INTERVAL (lets receiver respond on LAN)
                    _pnow = time.perf_counter()
                    if _pnow - last_probe_time >= PROBE_INTERVAL:
                        last_probe_time = _pnow
                        _phdr = struct.pack(">IQ", seq & 0xFFFFFFFF, time.perf_counter_ns())
                        try:
                            sock.sendto(_phdr + latest_frame, (ip, UDP_PORT))
                        except OSError:
                            pass
                    continue

                try:
                    t_enc_start = t_prev_done
                    if t_enc_start is not None:
                        _enc.append((t_frame_ready - t_enc_start) / 1e6)

                    header = struct.pack(">IQ", seq & 0xFFFFFFFF, t_frame_ready)
                    t0 = time.perf_counter_ns()
                    sock.sendto(header + latest_frame, (ip, UDP_PORT))
                    t1 = time.perf_counter_ns()
                    _snd.append((t1 - t0) / 1e6)
                    total_frames += 1
                    fps_frames += 1

                    # Drain stale ACKs; any packet updates last_receiver_contact
                    ack_sock.setblocking(False)
                    while True:
                        try:
                            ack_sock.recvfrom(64)
                            last_receiver_contact = time.perf_counter()
                        except Exception:
                            break
                    ack_sock.settimeout(ACK_TIMEOUT)

                    # Collect up to 3 stage ACKs; break early on timeout
                    t_stages = {}
                    for _ in range(3):
                        try:
                            data, _ = ack_sock.recvfrom(64)
                            last_receiver_contact = time.perf_counter()
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

                    if t_stages:
                        consecutive_miss = 0
                    else:
                        consecutive_miss += 1
                        if consecutive_miss >= MAX_CONSECUTIVE_MISS and receiver_ready:
                            print("\nReceiver not responding, pausing stream...")
                            receiver_ready = False

                    # t_prev_done after ACKs so Encode measures only pipe-delivery wait
                    t_prev_done = time.perf_counter_ns()
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
            set_topmost(hwnd, False)
        if not needs_restart:
            break

except KeyboardInterrupt:
    print("\nStopping stream...")
finally:
    if process:
        process.terminate()
    sock.close()
    ack_sock.close()
