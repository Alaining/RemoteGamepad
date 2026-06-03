# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Imports
# ─────────────────────────────────────────────────────────────────────────────
import subprocess              # spawn ffmpeg as a child process and read its stdout pipe
import sys
import socket
import struct                  # pack/unpack the binary frame header (seq + timestamp_ns)
import time
import msvcrt                  # Windows-only: convert a Python file object to a Win32 HANDLE
import ctypes                  # call Win32 APIs (window enumeration, DWM bounds, PeekNamedPipe)
import ctypes.wintypes
from collections import deque  # fixed-length rolling buffer for latency statistics

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Tunable constants
# ─────────────────────────────────────────────────────────────────────────────
UDP_PORT = 5006
ACK_PORT = 5007         # receiver sends latency ACKs back to this port
ACK_TIMEOUT = 0.025     # seconds to wait per ACK stage; 25ms gives 6x headroom over the ~4ms LAN RTT
FRAMERATE = 165         # capture and stream frame rate
JPEG_QUALITY = 25       # 2=best/largest, 31=worst/smallest (ffmpeg -q:v scale)
HEIGHT = 240            # stream height; width auto-scaled to maintain aspect ratio

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — JPEG frame delimiters
#   ffmpeg writes a raw concatenation of JPEG images to stdout.
#   We scan for SOI/EOI to extract individual frames from the pipe buffer.
# ─────────────────────────────────────────────────────────────────────────────
SOI = b'\xff\xd8'  # start-of-image: every JPEG begins with these 2 bytes
EOI = b'\xff\xd9'  # end-of-image:   every JPEG ends   with these 2 bytes

# Frame packet layout: [seq: 4B big-endian uint][timestamp_ns: 8B big-endian int64][JPEG data]
# ACK packet layout:   [seq: 4B][timestamp_ns: 8B][stage: 1B]  (receiver echoes header + stage)
# ACK stages: 0=frame received, 1=decoded (imdecode done), 2=drawn (imshow+pollKey done)


# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Window / monitor enumeration helpers (called once at startup)
# ─────────────────────────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — drain_pipe: drop stale frames that piled up during ACK wait
#   While we're blocked waiting for ACKs, ffmpeg keeps encoding and writing
#   to the pipe. We don't want to display those old frames — only the latest.
#   PeekNamedPipe tells us exactly how many bytes are ready so read1() never
#   blocks. We loop until the pipe is empty, then the caller picks the last
#   complete JPEG from the combined buffer.
# ─────────────────────────────────────────────────────────────────────────────
def drain_pipe(pipe):
    """Read all currently buffered pipe data without blocking (Windows only).
    Uses PeekNamedPipe to know exactly how many bytes are ready so read1()
    never blocks, clearing the stale-frame backlog that builds up during ACK waits."""
    avail = ctypes.c_ulong(0)
    handle = ctypes.c_void_p(msvcrt.get_osfhandle(pipe.fileno()))
    data = b""
    while True:
        ctypes.windll.kernel32.PeekNamedPipe(handle, None, 0, None, ctypes.byref(avail), None)
        if avail.value == 0:
            break
        data += pipe.read1(min(65536, avail.value))
    return data


# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — build_window_lavfi: construct the ffmpeg filter graph for window capture
#   ddagrab reads directly from the GPU framebuffer (DXGI Desktop Duplication),
#   which captures hardware-accelerated content that gdigrab cannot see.
#   offset_x/offset_y/video_size restrict the capture to the window's rectangle.
#   hwdownload + format=bgra move the frame from GPU memory to CPU memory.
# ─────────────────────────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — pick_capture_target: ask the user what to stream
# ─────────────────────────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Startup: get receiver IP and capture source from the user
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 — Socket setup
# ─────────────────────────────────────────────────────────────────────────────
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)  # small send buffer: prevents OS from queuing multiple frames ahead of us

ack_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)  # separate socket so ACK reads never interfere with frame sends
ack_sock.bind(("0.0.0.0", ACK_PORT))
ack_sock.settimeout(ACK_TIMEOUT)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 10 — Latency metric state
# ─────────────────────────────────────────────────────────────────────────────
seq = 0      # monotonically increasing frame counter; echoed in every ACK so we can match replies to the right frame
WINDOW = 60  # number of recent frames kept in each rolling latency average

_enc   = deque(maxlen=WINDOW)  # time from previous ACK-done to this frame ready in the pipe (encode + pipe wait)
_snd   = deque(maxlen=WINDOW)  # duration of the sendto() syscall
_net   = deque(maxlen=WINDOW)  # (stage-0 RTT) ÷ 2 ≈ one-way network latency
_dec   = deque(maxlen=WINDOW)  # stage-1 minus stage-0: imdecode time on the receiver
_drw   = deque(maxlen=WINDOW)  # stage-2 minus stage-1: imshow + pollKey time on the receiver
_rtt   = deque(maxlen=WINDOW)  # sendto to stage-2: round-trip until the frame is on screen
_total = deque(maxlen=WINDOW)  # previous ACK-done to stage-2: true end-to-end viewer latency

ack_miss = 0      # cumulative ACK stage timeouts across all frames
total_frames = 0  # cumulative frames sent (denominator for loss%)
fps_frames = 0    # frames sent since the last stats print; reset every second
t_prev_done = None  # timestamp after previous frame's ACK collection; next Encode is measured from here
t_stats = time.perf_counter()
t_fps_ref = time.perf_counter()
t_last_send = None   # perf_counter timestamp of the most recently sent frame; used for RTT backpressure
drop_count = 0       # frames skipped this second because send interval was shorter than 1/max_fps
_e2e_send_ms = 0.0  # latest E2E estimate (ms) embedded in every frame header for receiver overlay

# ─────────────────────────────────────────────────────────────────────────────
# STEP 11 — Outer loop: (re)start ffmpeg
#   For window capture, ffmpeg must restart whenever the window moves or resizes
#   because the capture rectangle is baked into the lavfi string at launch time.
#   For monitor capture, ffmpeg runs continuously until the script is stopped.
# ─────────────────────────────────────────────────────────────────────────────
process = None
needs_restart = False  # set True when window moves/resizes so outer loop relaunches ffmpeg
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

        # ─────────────────────────────────────────────────────────────────────
        # STEP 12 — Launch ffmpeg
        #   Pipeline: ddagrab (GPU framebuffer) → hwdownload (GPU→CPU) →
        #   scale + format=yuvj420p → MJPEG encode → image2pipe (stdout).
        #   yuvj420p is the JPEG colour space (full range); plain yuv420p
        #   causes washed-out colours. stderr goes to DEVNULL to keep the
        #   terminal clean.
        # ─────────────────────────────────────────────────────────────────────
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
        buf = b""           # accumulates raw bytes from the pipe until a complete JPEG can be extracted
        needs_restart = False
        _hold_until_ns = time.perf_counter_ns() + 50_000_000  # 50ms blackout: skip stale frame ddagrab outputs on startup

        # ─────────────────────────────────────────────────────────────────────
        # STEP 13 — Inner loop: one iteration = one frame sent
        # ─────────────────────────────────────────────────────────────────────
        while True:
            # Guard: check window state before blocking on the pipe (window capture only).
            # If the window moved or was minimized, set needs_restart and break so the
            # outer loop can relaunch ffmpeg with the updated rectangle.
            if hwnd is not None:
                if ctypes.windll.user32.IsIconic(hwnd):
                    print("\nWindow minimized, pausing stream...")
                    needs_restart = True
                    break
                if get_window_visual_rect(hwnd) != current_rect:
                    needs_restart = True
                    break

            chunk = process.stdout.read1(65536)  # blocks until ffmpeg writes at least one byte (~1/FRAMERATE s)
            if not chunk:
                break
            buf += chunk + drain_pipe(process.stdout)  # drain_pipe appends everything else already in the OS pipe buffer without blocking

            # Scan buf for complete JPEG frames and keep only the last one.
            # Any frames that accumulated while we were blocked on ACK collection
            # are silently discarded — the viewer always sees the most recent screen state.
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

            if latest_frame and len(latest_frame) <= 65493:  # 65507 max UDP payload − 14B header = 65493 usable bytes
                _now_ns = time.perf_counter_ns()
                if hwnd is not None and ctypes.windll.user32.GetForegroundWindow() != hwnd:
                    _hold_until_ns = _now_ns + 50_000_000  # extend 50ms blackout on every unfocused frame
                    continue

                if _now_ns < _hold_until_ns:
                    continue  # inside blackout window (startup or focus regain)

                # Drop this frame if we're sending faster than 70% of 1/RTT.
                # Use _net (stage-0 network RTT) rather than _rtt (end-to-end including imshow)
                # so that receiver display slowdowns don't incorrectly throttle the send rate.
                if _net and t_last_send is not None:
                    avg_net_rtt_ms = sum(_net) / len(_net)
                    if time.perf_counter() - t_last_send < avg_net_rtt_ms / 700.0:
                        drop_count += 1
                        continue
                t_last_send = time.perf_counter()

                try:
                    t_enc_start = t_prev_done
                    if t_enc_start is not None:
                        _enc.append((t_frame_ready - t_enc_start) / 1e6)  # pipe wait since last ACK-done

                    # Header: seq + timestamp_ns (echoed in ACKs) + e2e_ms for receiver overlay.
                    # ACKs only echo the first 12 bytes (seq+timestamp); the 2-byte e2e field is display-only.
                    header = struct.pack(">IQH", seq & 0xFFFFFFFF, t_frame_ready,
                                         max(0, min(65535, int(_e2e_send_ms))))
                    t0 = time.perf_counter_ns()
                    sock.sendto(header + latest_frame, (ip, UDP_PORT))
                    t1 = time.perf_counter_ns()
                    _snd.append((t1 - t0) / 1e6)
                    total_frames += 1
                    fps_frames += 1

                    # Discard any ACKs left over from a previously timed-out frame.
                    # Without this, an old ACK arriving just now could be mistaken for
                    # a stage-0 ACK of the frame we just sent.
                    ack_sock.setblocking(False)
                    while True:
                        try:
                            ack_sock.recvfrom(13)
                        except Exception:
                            break
                    ack_sock.settimeout(ACK_TIMEOUT)

                    # Collect stage 0 (received) and 1 (decoded) with timeout — these are fast (~4ms, ~6ms).
                    # Stage 2 (imshow done) is NOT awaited: cv2.imshow on the receiver can stall 30-100ms
                    # when the Windows compositor is slow, which would freeze the sender for that entire time.
                    # Instead we do one non-blocking peek after stage 1 to capture stage 2 for stats when
                    # it has already arrived, without ever blocking on it.
                    t_stages = {}
                    for _ in range(2):
                        try:
                            data, _ = ack_sock.recvfrom(13)
                            if len(data) == 13:
                                ack_seq, _, stage = struct.unpack(">IQB", data)
                                if ack_seq == (seq & 0xFFFFFFFF):
                                    t_stages[stage] = time.perf_counter_ns()
                        except socket.timeout:
                            ack_miss += 1
                            break
                    ack_sock.setblocking(False)
                    try:
                        data, _ = ack_sock.recvfrom(13)
                        if len(data) == 13:
                            ack_seq, _, stage = struct.unpack(">IQB", data)
                            if ack_seq == (seq & 0xFFFFFFFF) and stage == 2:
                                t_stages[2] = time.perf_counter_ns()
                    except Exception:
                        pass
                    ack_sock.settimeout(ACK_TIMEOUT)

                    if 0 in t_stages:
                        _net.append((t_stages[0] - t0) / 1e6)           # stage-0 RTT ÷ 2 ≈ one-way network
                    if 0 in t_stages and 1 in t_stages:
                        _dec.append((t_stages[1] - t_stages[0]) / 1e6)  # imdecode time on receiver
                    if 1 in t_stages and 2 in t_stages:
                        _drw.append((t_stages[2] - t_stages[1]) / 1e6)  # imshow + pollKey time on receiver
                    if 2 in t_stages:
                        _rtt.append((t_stages[2] - t0) / 1e6)
                        if t_enc_start is not None:
                            _total.append((t_stages[2] - t_enc_start) / 1e6)

                    t_prev_done = time.perf_counter_ns()  # mark end of this frame; next Encode is measured from here
                    seq += 1

                    # ─────────────────────────────────────────────────────────
                    # STEP 14 — Print latency stats once per second
                    # ─────────────────────────────────────────────────────────
                    now = time.perf_counter()
                    if now - t_stats >= 1.0:
                        fps = fps_frames / (now - t_fps_ref)
                        fps_frames = 0
                        t_fps_ref = now
                        t_stats = now
                        drops_this_sec = drop_count
                        drop_count = 0

                        def a(d):
                            return f"{sum(d)/len(d):.1f}" if d else "---"
                        net_one_way = sum(_net) / len(_net) / 2 if _net else None
                        net_est = f"{net_one_way:.1f}" if net_one_way is not None else "---"
                        loss = f"{100*ack_miss/total_frames:.1f}" if total_frames else "0.0"
                        if _enc and _net and _dec:
                            e2e = sum(_enc)/len(_enc) + net_one_way + sum(_dec)/len(_dec)
                            e2e_str = f"{e2e:.1f}"
                            _e2e_send_ms = e2e
                        else:
                            e2e_str = "---"
                        print(
                            f"E2E:{e2e_str}ms  "
                            f"[Encode:{a(_enc)}ms  Net:{net_est}ms  Decode:{a(_dec)}ms]  "
                            f"FPS:{fps:.1f}  Loss:{loss}%  Dropped:{drops_this_sec}/s"
                        )

                except OSError as e:
                    print(f"\nSend error: {e}")
                    break

        # ─────────────────────────────────────────────────────────────────────
        # STEP 15 — ffmpeg cleanup after inner loop exits
        # ─────────────────────────────────────────────────────────────────────
        process.terminate()
        process.wait()
        process = None

        if hwnd is not None:
            set_topmost(hwnd, False)
        if not needs_restart:
            break  # clean exit (no window change pending)

except KeyboardInterrupt:
    print("\nStopping stream...")
finally:
    # STEP 16 — Final cleanup
    if process:
        process.terminate()
    sock.close()
    ack_sock.close()
