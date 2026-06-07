import subprocess
import sys
import os

wait_mode = "--wait" in sys.argv
ip_args   = [a for a in sys.argv[1:] if a != "--wait"]
if ip_args:
    ip = ip_args[0].strip()
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
# Pass -Wait to let the diagnostics wait indefinitely for the other machine.
diag_cmd = ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File",
            os.path.join(script_dir, "network_diagnostics.ps1"), ip, "SERVER"]
if wait_mode:
    diag_cmd.append("-Wait")
try:
    diag = subprocess.run(diag_cmd)
except KeyboardInterrupt:
    print()
    sys.exit(0)
if diag.returncode != 0:
    sys.exit(1)   # user aborted inside the diagnostics (already asked there)

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
