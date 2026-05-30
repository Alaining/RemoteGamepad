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
- `opencv-python` (`cv2`) + `numpy` — video receiver display (`pip install opencv-python`)
- `FFmpeg` (full build from gyan.dev, **not** the essentials build) — required by `video_udp_sender.py` for screen capture and MJPEG encoding; must be on PATH

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

## Video streaming

Two additional scripts stream low-latency screen video from the sender machine to the receiver.

**Run the receiver first**, then the sender:
```powershell
# Receiver machine
python video_receiver.py

# Sender machine (prompts for receiver IP, or pass as argument)
python video_udp_sender.py
python video_udp_sender.py 192.168.1.50
```

**Data flow:** `ddagrab (GPU framebuffer)` → MJPEG via FFmpeg pipe → Python → UDP port 5006 → `cv2.imdecode` → `cv2.imshow`

### Key design decisions

**Why MJPEG over H.264:** Each MJPEG frame is a self-contained JPEG — no inter-frame dependencies, no GOP wait, no decoder buffer. H.264 with a player like ffplay introduced 600ms–1s of receiver buffer latency that couldn't be fully eliminated with flags. MJPEG + custom OpenCV receiver bypasses all player buffering.

**Why ddagrab instead of gdigrab:** `gdigrab` uses the GDI pipeline and cannot capture hardware-accelerated windows (browsers, games using DirectX/GPU). `ddagrab` reads directly from the GPU's composited framebuffer via DXGI Desktop Duplication API. It is a filter (not a device) in this FFmpeg build, so it's invoked via `-f lavfi -i "ddagrab=...,hwdownload,format=bgra"`.

**Why UDP instead of TCP:** TCP buffers frames in the send/receive queue. If the receiver is briefly slow, TCP queues multiple frames — causing the display to lag behind. UDP is fire-and-forget; old frames are simply dropped, keeping the display at the latest available frame.

**Drop-stale-frames on sender:** The Python loop reads from the FFmpeg pipe with `read1()` (non-blocking, returns whatever is immediately available). If multiple frames accumulate in the buffer during a slow iteration, only the latest complete JPEG is sent — older ones are discarded. This prevents the latency from growing over time.

**Why `read1()` not `read()`:** `read(n)` blocks until the buffer has n bytes. At low JPEG quality (`q=31`) with ~4KB frames, `read(65536)` would accumulate ~16 frames before returning, causing burst delivery. `read1()` returns as soon as any bytes are available.

### Tunable constants in `video_udp_sender.py`

| Constant | Default | Effect |
|---|---|---|
| `FRAMERATE` | `30` | Capture and encode fps |
| `JPEG_QUALITY` | `31` | JPEG quality (2=best/largest, 31=worst/smallest) |
| `HEIGHT` | `480` | Output height in pixels; width scales to maintain aspect ratio |

### FFmpeg capture pipeline

```
ddagrab=output_idx=N:framerate=30,hwdownload,format=bgra
```
- `output_idx` — monitor index (0 = primary). For window capture, adds `offset_x`, `offset_y`, `video_size`.
- `hwdownload,format=bgra` — downloads from Vulkan GPU memory to CPU memory. Required after ddagrab.
- `format=yuvj420p` — converts BGRA → JPEG color space. Must use `yuvj420p` (JPEG range), not `yuv420p` (MPEG range), to avoid color banding.

### FFmpeg build requirement

The `ddagrab` filter is **not** present in the essentials build. It requires the **full** build from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/). Verify with:
```powershell
ffmpeg -filters 2>&1 | Select-String "dda"
```

### Frame size constraint

Each MJPEG frame must fit in a single UDP datagram (≤ 65,507 bytes). At `q=31` and 480p, frames are typically 4–30KB — well within the limit. At higher quality or resolution, frames may exceed this and be silently dropped by the sender (`len(latest_frame) <= 65507` guard). Switch to TCP if higher quality is needed.
