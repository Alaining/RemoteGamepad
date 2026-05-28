import subprocess
import sys
import ctypes
import ctypes.wintypes

UDP_PORT = 5006


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
    lavfi = f"ddagrab=output_idx={monitor_idx}:framerate=24,hwdownload,format=bgra"
    label = f"Monitor {monitor_idx}"
else:
    _, x, y, w, h = target
    lavfi = f"ddagrab=output_idx=0:framerate=24:offset_x={x}:offset_y={y}:video_size={w}x{h},hwdownload,format=bgra"
    label = f"window ({w}x{h})"

print(f"\nStreaming {label} to {ip}:{UDP_PORT} at 480p 24fps")
print(f"Receive with: ffplay udp://0.0.0.0:{UDP_PORT} -fflags nobuffer -flags low_delay -framedrop -probesize 32 -analyzeduration 0 -sync ext\n")

cmd = [
    "ffmpeg",
    "-f", "lavfi",
    "-i", lavfi,
    "-vf", "scale=-2:480,format=yuv420p",
    "-c:v", "libx264",
    "-preset", "ultrafast",
    "-tune", "zerolatency",
    "-g", "4",
    "-b:v", "1000k",
    "-maxrate", "1000k",
    "-bufsize", "1000k",
    "-flush_packets", "1",
    "-f", "mpegts",
    f"udp://{ip}:{UDP_PORT}",
]

process = None
try:
    process = subprocess.Popen(cmd)
    process.wait()
except KeyboardInterrupt:
    print("\nStopping stream...")
    if process:
        process.terminate()
except FileNotFoundError:
    print("FFmpeg not found. Install FFmpeg and ensure it is on PATH.")
    sys.exit(1)
