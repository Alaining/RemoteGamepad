import subprocess
import sys
import os

if len(sys.argv) > 1:
    ip = sys.argv[1].strip()
else:
    ip = input("Enter the receiver's IP address: ").strip()
if not ip:
    ip = "127.0.0.1"

if "." not in ip:
    print("Invalid IP address. Exiting...")
    sys.exit(1)

python = sys.executable
script_dir = os.path.dirname(os.path.abspath(__file__))

CREATE_NEW_CONSOLE = 0x00000010

subprocess.Popen(
    [python, os.path.join(script_dir, "controller_udp_sender.py"), ip],
    creationflags=CREATE_NEW_CONSOLE,
)

subprocess.Popen(
    [python, os.path.join(script_dir, "video_udp_sender.py"), ip],
    creationflags=CREATE_NEW_CONSOLE,
)

print("Both senders launched. You can close this window.")
