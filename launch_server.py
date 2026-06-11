import subprocess
import sys
import os

script_dir = os.path.dirname(os.path.abspath(__file__))
subprocess.run([sys.executable, os.path.join(script_dir, "server_gui.py")])
