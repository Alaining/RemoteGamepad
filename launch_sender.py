import subprocess
import sys
import os

if len(sys.argv) > 1:
    ip = sys.argv[1].strip()
else:
    ip = input("Enter the client's IP address: ").strip()
if not ip:
    ip = "127.0.0.1"

if "." not in ip:
    print("Invalid IP address. Exiting...")
    sys.exit(1)

python = sys.executable
script_dir = os.path.dirname(os.path.abspath(__file__))

# Run network diagnostics first (blocking, output shown in this console).
diag = subprocess.run(
    ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File",
     os.path.join(script_dir, "network_diagnostics.ps1"), ip, "SERVER"],
)
if diag.returncode != 0:
    answer = input("\nNetwork diagnostics reported issues. Launch anyway? [Y/N]: ").strip()
    if not answer.lower().startswith("y"):
        sys.exit(1)

CREATE_NEW_CONSOLE = 0x00000010

subprocess.Popen(
    [python, os.path.join(script_dir, "video_udp_sender.py"), ip],
    creationflags=CREATE_NEW_CONSOLE,
)

subprocess.Popen(
    [python, os.path.join(script_dir, "controller_udp_receiver.py")],
    creationflags=CREATE_NEW_CONSOLE,
)

print("Both server scripts launched. You can close this window.")
