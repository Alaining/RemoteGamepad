import tkinter as tk
from tkinter import ttk, scrolledtext
import subprocess
import threading
import time
import json
import re
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PYTHON = sys.executable
CREATE_NO_WINDOW = 0x08000000
CONFIG_FILE = os.path.join(SCRIPT_DIR, ".server_gui_config.json")

# ── ANSI palette (VS Code dark theme) ────────────────────────────────────────
_FG = {
    30: "#1e1e1e", 31: "#cd3131", 32: "#0dbc79", 33: "#e5e510",
    34: "#2472c8", 35: "#bc3fbc", 36: "#11a8cd", 37: "#e5e5e5",
    90: "#666666", 91: "#f14c4c", 92: "#23d18b", 93: "#f5f543",
    94: "#3b8eea", 95: "#d670d6", 96: "#29b8db", 97: "#ffffff",
}
_BG = {
     40: "#1e1e1e",  41: "#cd3131",  42: "#0dbc79",  43: "#e5e510",
     44: "#2472c8",  45: "#bc3fbc",  46: "#11a8cd",  47: "#e5e5e5",
    100: "#666666", 101: "#f14c4c", 102: "#23d18b", 103: "#f5f543",
    104: "#3b8eea", 105: "#d670d6", 106: "#29b8db", 107: "#ffffff",
}

# Matches any CSI escape sequence: ESC [ <params> <letter>
_ANSI_RE = re.compile(r'\x1b\[([0-9;]*)([A-Za-z])')


def _load_config():
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _save_config(data):
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f)
    except Exception:
        pass


def _kill_port_holder(port):
    """Kill any process currently bound to port. Returns list of killed PIDs."""
    try:
        result = subprocess.run(
            ["netstat", "-ano"], capture_output=True, text=True, check=False
        )
        pids = set()
        for line in result.stdout.splitlines():
            if f":{port} " in line or f":{port}\t" in line:
                parts = line.split()
                pid = parts[-1] if parts else ""
                if pid.isdigit() and pid != "0":
                    pids.add(pid)
        for pid in pids:
            subprocess.run(
                ["taskkill", "/F", "/PID", pid], capture_output=True, check=False
            )
        return list(pids)
    except OSError:
        return []


class ProcessTab:
    """A notebook tab with a terminal-style output widget and a stdin input bar."""

    def __init__(self, notebook, title, root):
        self._root = root
        self.proc = None
        self._tags = set()
        # current ANSI render state
        self._fg = None
        self._bg = None
        self._bold = False
        self._underline = False

        frame = tk.Frame(notebook)
        notebook.add(frame, text=title)

        self.output = scrolledtext.ScrolledText(
            frame, state=tk.DISABLED,
            bg="#1e1e1e", fg="#d4d4d4",
            font=("Consolas", 9), wrap=tk.WORD,
        )
        self.output.pack(fill=tk.BOTH, expand=True)

        bottom = tk.Frame(frame)
        bottom.pack(fill=tk.X, padx=4, pady=2)
        self.stdin_entry = tk.Entry(bottom, font=("Consolas", 9))
        self.stdin_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.stdin_entry.bind("<Return>", self._send)
        tk.Button(bottom, text="Send", command=self._send).pack(
            side=tk.LEFT, padx=(4, 0)
        )

    # ── stdin ─────────────────────────────────────────────────────────────────

    def _send(self, _event=None):
        text = self.stdin_entry.get().strip()
        self.stdin_entry.delete(0, tk.END)
        if not text:
            return
        if self.proc and self.proc.stdin:
            try:
                self.proc.stdin.write(text + "\n")
                self.proc.stdin.flush()
                self.append(f"> {text}\n")
            except OSError:
                self.append("[stdin closed]\n")

    # ── ANSI rendering ────────────────────────────────────────────────────────

    def _apply_codes(self, codes):
        if not codes or codes == [0]:
            self._fg = self._bg = None
            self._bold = self._underline = False
            return
        for c in codes:
            if c == 0:
                self._fg = self._bg = None
                self._bold = self._underline = False
            elif c == 1:
                self._bold = True
            elif c in (2, 22):
                self._bold = False
            elif c == 4:
                self._underline = True
            elif c == 24:
                self._underline = False
            elif 30 <= c <= 37 or 90 <= c <= 97:
                self._fg = c
            elif 40 <= c <= 47 or 100 <= c <= 107:
                self._bg = c

    def _get_tag(self):
        key = (self._fg, self._bg, self._bold, self._underline)
        if key == (None, None, False, False):
            return None
        name = f"a{hash(key) & 0xFFFFFFFF}"
        if name not in self._tags:
            opts = {}
            if self._fg is not None:
                # promote standard color to bright variant when bold
                fg = self._fg + 60 if self._bold and 30 <= self._fg <= 37 else self._fg
                opts["foreground"] = _FG.get(fg) or _FG.get(self._fg)
            if self._bg is not None:
                opts["background"] = _BG.get(self._bg)
            if self._bold:
                opts["font"] = ("Consolas", 9, "bold")
            if self._underline:
                opts["underline"] = True
            self.output.tag_configure(name, **opts)
            self._tags.add(name)
        return name

    def append(self, text):
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        self.output.config(state=tk.NORMAL)
        pos = 0
        for m in _ANSI_RE.finditer(text):
            if m.start() > pos:
                chunk = text[pos:m.start()]
                tag = self._get_tag()
                if tag:
                    self.output.insert(tk.END, chunk, tag)
                else:
                    self.output.insert(tk.END, chunk)
            if m.group(2) == "m":
                raw = m.group(1)
                codes = [int(c) for c in raw.split(";") if c] if raw else [0]
                self._apply_codes(codes)
            # all other CSI sequences (cursor movement, clear screen…) are dropped
            pos = m.end()
        if pos < len(text):
            tag = self._get_tag()
            if tag:
                self.output.insert(tk.END, text[pos:], tag)
            else:
                self.output.insert(tk.END, text[pos:])
        self.output.see(tk.END)
        self.output.config(state=tk.DISABLED)

    # ── subprocess ────────────────────────────────────────────────────────────

    def attach(self, proc):
        self.proc = proc
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while True:
            line = self.proc.stdout.readline()
            if not line:
                break
            self._root.after(0, lambda l=line: self.append(l))
        self._root.after(0, lambda: self.append("--- process exited ---\n"))


class BatchedProcessTab(ProcessTab):
    """ProcessTab that flushes output every BATCH_LINES lines or every INTERVAL seconds."""

    BATCH_LINES = 20
    INTERVAL = 0.3

    def _read(self):
        buf = []
        lock = threading.Lock()
        running = [True]

        def flush():
            with lock:
                if not buf:
                    return
                text = "".join(buf)
                buf.clear()
            self._root.after(0, lambda t=text: self.append(t))

        def timer():
            while running[0]:
                time.sleep(self.INTERVAL)
                flush()

        threading.Thread(target=timer, daemon=True).start()

        while True:
            line = self.proc.stdout.readline()
            if not line:
                break
            do_flush = False
            with lock:
                buf.append(line)
                if len(buf) >= self.BATCH_LINES:
                    do_flush = True
            if do_flush:
                flush()

        running[0] = False
        flush()
        self._root.after(0, lambda: self.append("--- process exited ---\n"))


class ServerGUI:
    def __init__(self, root):
        self.root = root
        root.title("RemoteGamepad Server")
        root.geometry("700x520")

        cfg = _load_config()

        # ── top bar ───────────────────────────────────────────────────────────
        bar = tk.Frame(root)
        bar.pack(fill=tk.X, padx=8, pady=6)

        tk.Label(bar, text="Client IP:").pack(side=tk.LEFT)
        self.ip_entry = tk.Entry(bar, width=18)
        self.ip_entry.pack(side=tk.LEFT, padx=4)
        self.ip_entry.insert(0, cfg.get("last_ip", ""))
        self.ip_entry.bind("<Return>", lambda _: self._start())

        self.start_btn = tk.Button(bar, text="Start", command=self._start, width=8)
        self.start_btn.pack(side=tk.LEFT)

        self.stop_btn = tk.Button(
            bar, text="Stop", command=self._stop, width=8, state=tk.DISABLED
        )
        self.stop_btn.pack(side=tk.LEFT, padx=(4, 0))

        self.diag_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(bar, text="Diagnostics", variable=self.diag_var).pack(
            side=tk.LEFT, padx=(8, 0)
        )

        self.status_var = tk.StringVar()
        self.status_label = tk.Label(bar, textvariable=self.status_var, fg="#888888")
        self.status_label.pack(side=tk.LEFT, padx=10)

        # ── notebook ──────────────────────────────────────────────────────────
        nb = ttk.Notebook(root)
        nb.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))
        self.nb = nb

        self.diag_tab  = ProcessTab(nb,        "Diagnostics",  root)
        self.video_tab = ProcessTab(nb,        "Video Sender", root)
        self.ctrl_tab  = BatchedProcessTab(nb, "Controller",   root)

        root.protocol("WM_DELETE_WINDOW", self._on_close)
        self._set_status("Ready")

    # ── actions ───────────────────────────────────────────────────────────────

    def _start(self):
        ip = self.ip_entry.get().strip()
        if not ip or "." not in ip:
            self.diag_tab.append("Invalid IP address.\n")
            self.nb.select(0)
            return
        _save_config({"last_ip": ip})
        self.start_btn.config(state=tk.DISABLED)
        self.stop_btn.config(state=tk.NORMAL)
        self.ip_entry.config(state=tk.DISABLED)
        run_diag = self.diag_var.get()
        self.nb.select(0 if run_diag else 1)
        threading.Thread(target=self._sequence, args=(ip, run_diag), daemon=True).start()

    def _sequence(self, ip, run_diag):
        env = os.environ.copy()
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"

        def log(msg):
            self.root.after(0, lambda m=msg: self.diag_tab.append(m))

        # ── 1. diagnostics (optional, blocking) ──────────────────────────────
        if run_diag:
            self._set_status("Running diagnostics…")
            diag = subprocess.Popen(
                ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File",
                 os.path.join(SCRIPT_DIR, "network_diagnostics.ps1"), ip, "SERVER"],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                stdin=subprocess.PIPE, encoding="utf-8", bufsize=1,
                creationflags=CREATE_NO_WINDOW,
            )
            self.diag_tab.attach(diag)
            diag.wait()

            if diag.returncode != 0:
                log("\nDiagnostics failed — aborting.\n")
                self._set_status("Failed")
                self.root.after(0, self._re_enable)
                return

            log("\nDiagnostics passed. Launching server processes…\n")
        else:
            log("Diagnostics skipped.\n")

        # ── kill orphaned processes still holding server ports ────────────────
        for port, label in [(5005, "controller (port 5005)"),
                            (5007, "video ACK listener (port 5007)")]:
            for pid in _kill_port_holder(port):
                log(f"Killed orphaned process PID {pid} holding {label}\n")

        # ── 2. video sender ───────────────────────────────────────────────────
        self._set_status("Running")
        video = subprocess.Popen(
            [PYTHON, os.path.join(SCRIPT_DIR, "video_udp_sender.py"), ip],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE, encoding="utf-8", bufsize=1,
            env=env, creationflags=CREATE_NO_WINDOW,
        )
        self.video_tab.attach(video)

        # ── 3. controller receiver ────────────────────────────────────────────
        ctrl = subprocess.Popen(
            [PYTHON, os.path.join(SCRIPT_DIR, "controller_udp_receiver.py")],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE, encoding="utf-8", bufsize=1,
            env=env, creationflags=CREATE_NO_WINDOW,
        )
        self.ctrl_tab.attach(ctrl)

        self.root.after(0, lambda: self.nb.select(1))

    # ── helpers ───────────────────────────────────────────────────────────────

    def _kill_procs(self):
        for tab in (self.diag_tab, self.video_tab, self.ctrl_tab):
            proc = tab.proc
            if proc and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()

    def _stop(self):
        self._kill_procs()
        self._set_status("Stopped")
        self._re_enable()

    def _on_close(self):
        self._kill_procs()
        self.root.destroy()

    def _re_enable(self):
        self.start_btn.config(state=tk.NORMAL)
        self.stop_btn.config(state=tk.DISABLED)
        self.ip_entry.config(state=tk.NORMAL)

    _STATUS = {
        "Ready":                   ("○  Ready",               "#888888"),
        "Running diagnostics…":    ("◎  Running diagnostics…", "#e5a00d"),
        "Running":                 ("●  Running",              "#23d18b"),
        "Stopped":                 ("○  Stopped",              "#c07000"),
        "Failed":                  ("✕  Failed",               "#f14c4c"),
    }

    def _set_status(self, key):
        label, color = self._STATUS.get(key, (f"○  {key}", "#888888"))
        title_dot = "●  " if key == "Running" else ""
        def _apply():
            self.status_var.set(label)
            self.status_label.config(fg=color)
            self.root.title(f"{title_dot}RemoteGamepad Server")
        self.root.after(0, _apply)


root = tk.Tk()
ServerGUI(root)
root.mainloop()
