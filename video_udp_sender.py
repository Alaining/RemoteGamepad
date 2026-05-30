import subprocess
import sys
import socket
import ctypes
import ctypes.wintypes

UDP_PORT = 5006
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
            buf = buf[end + 2:]

        if latest_frame and len(latest_frame) <= 65507:
            try:
                sock.sendto(latest_frame, (ip, UDP_PORT))
            except OSError as e:
                print(f"\nSend error: {e}")
                break

except KeyboardInterrupt:
    print("\nStopping stream...")
finally:
    if process:
        process.terminate()
    sock.close()
