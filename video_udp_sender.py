import subprocess
import sys

UDP_PORT = 5006

ip = input("Enter the receiver's IP address: ").strip()
if ip == "":
    ip = "127.0.0.1"

if "." not in ip:
    print("Invalid IP address. Exiting...")
    sys.exit(1)

print(f"Streaming desktop to {ip}:{UDP_PORT} at 480p 24fps")
print(f"Receive with: ffplay udp://0.0.0.0:{UDP_PORT} -fflags nobuffer -flags low_delay -framedrop -probesize 32 -analyzeduration 0 -sync ext\n")

cmd = [
    "ffmpeg",
    "-f", "gdigrab",       # Windows screen capture
    "-framerate", "24",
    "-i", "desktop",
    "-vf", "scale=-2:480", # Scale to 480p, keep aspect ratio
    "-c:v", "libx264",
    "-preset", "ultrafast",
    "-tune", "zerolatency",
    "-b:v", "600k",
    "-maxrate", "600k",
    "-bufsize", "600k",    # Small buffer = low latency, less smoothing
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
