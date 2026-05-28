# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project does

RemoteGamepad forwards physical gamepad input from one machine (sender) to another (receiver) over UDP. The receiver translates the input into a virtual joystick using vJoy. Both sides are Windows Python scripts.

## Running the scripts

Activate the virtual environment first:
```powershell
.\.venv\Scripts\Activate.ps1
```

Run the sender (prompts for receiver IP):
```powershell
python controller_udp_sender.py
```

Run the sender with GUI:
```powershell
python sender_gui.py
```

Run the receiver (Windows only, requires vJoy installed):
```powershell
python controller_udp_receiver.py
```

Inspect raw controller input (useful for debugging axis/button mappings):
```powershell
python controller_raw_input.py
```

Test the receiver without a real controller (sends hardcoded neutral state):
```powershell
python controller_udp_sender_hardcoded.py
```

## Build standalone EXE (sender only)

```powershell
pyinstaller controller_udp_sender.spec
```

Output goes to `dist/controller_udp_sender.exe`.

## Dependencies

- `pygame` — reads physical controller input (sender side)
- `pyvjoy` — writes to vJoy virtual device (receiver side); requires the vJoy driver installed on Windows
- `tkinter` — GUI for `sender_gui.py` (stdlib)

## Architecture

**Data flow:** `pygame (physical controller)` → JSON over UDP port 5005 → `pyvjoy (vJoy virtual device)`

**JSON payload format:**
```json
{
  "buttons": {"button_0": 0, ..., "button_15": 0},
  "axes":    {"axis_0": 0.0, ..., "axis_5": 0.0},
  "dpad":    {"dpad_0": [0, 0]}
}
```

The sender only transmits when state changes (diff-based), polling at 10 ms intervals with a deadzone of 0.1 applied to all axes.

**D-pad dual encoding:** The sender encodes hat/d-pad input twice — once raw in `dpad` (x/y tuple) and once mapped into `buttons[13–16]` — so the receiver can use either representation.

**Trigger axes (4 & 5):** Physical triggers report in `[-1, 1]` but are remapped by the receiver to the upper half of the vJoy range `[16383, 32767]` because triggers only go one direction.

**Receiver axis mapping:**

| Pygame axis | vJoy axis |
|-------------|-----------|
| axis_0      | Z         |
| axis_1      | X         |
| axis_2      | Y         |
| axis_3      | RX        |
| axis_4      | RY (half-range) |
| axis_5      | RZ (half-range) |

**`sender_gui.py`** is a tkinter wrapper around the same logic as `controller_udp_sender.py`. It spawns the gamepad polling loop in a daemon thread and mirrors terminal output into a `ScrolledText` widget.
