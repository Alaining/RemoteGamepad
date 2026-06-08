# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Imports
# ─────────────────────────────────────────────────────────────────────────────
import socket
import struct
import sys
import time

try:
    import cv2        # JPEG decode only — display is handled by pygame
    import numpy as np
    import pygame
except ImportError:
    print("Missing dependencies. Run: pip install opencv-python pygame")
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Constants
# ─────────────────────────────────────────────────────────────────────────────
_sender_ip = sys.argv[1] if len(sys.argv) > 1 else None

UDP_PORT = 5006
ACK_PORT = 5007              # server listens here for latency ACKs
HEARTBEAT_INTERVAL = 2.0     # seconds between heartbeats sent to server when idle

DISPLAY_WIDTH  = 1280        # initial window width  (user can resize freely)
DISPLAY_HEIGHT = 720         # initial window height

# Frame packet: [seq: 4B][timestamp_ns: 8B][e2e_ms: 2B][JPEG data]
# ACK packet:   [seq: 4B][timestamp_ns: 8B][stage: 1B]  (first 12B of header echoed verbatim)
# Stages: 0=received, 1=decoded, 2=drawn

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Socket setup
# ─────────────────────────────────────────────────────────────────────────────
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024 * 1024)  # 1MB: must fit at least one fully-reassembled frame; drain loop prevents queuing lag
sock.bind(("0.0.0.0", UDP_PORT))
sock.settimeout(0.1)  # short timeout so heartbeat and quit checks run even when idle
print(f"Listening on port {UDP_PORT}... (press Q or close the window to quit)")
if not _sender_ip:
    print(f"Tip: pass the sender's IP as an argument to punch a NAT hole at startup.")
    print(f"     e.g.  python video_receiver.py 1.2.3.4")

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — pygame window and font setup
#   pygame uses SDL2 with DXGI flip-model presentation on Windows, which has
#   lower DWM buffering latency than OpenCV's GDI path (~1 vsync vs ~2 vsyncs).
# ─────────────────────────────────────────────────────────────────────────────
pygame.init()
screen        = pygame.display.set_mode((DISPLAY_WIDTH, DISPLAY_HEIGHT), pygame.RESIZABLE)
is_fullscreen = False
pygame.display.set_caption("RemoteGamepad")
font = pygame.font.SysFont("Arial", 22)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Stats and heartbeat state
# ─────────────────────────────────────────────────────────────────────────────
frames_shown        = 0
frames_dropped      = 0
t_stats             = time.perf_counter()
display_fps         = 0.0  # updated once per second, drawn on each frame
display_e2e         = 0    # E2E ms from server header, drawn on each frame

known_ack_addr      = None
last_frame_time     = time.perf_counter()
last_heartbeat_time = 0.0

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Startup drain: discard packets that arrived before we were ready
# ─────────────────────────────────────────────────────────────────────────────
sock.setblocking(False)
while True:
    try:
        sock.recvfrom(65536)
    except (BlockingIOError, OSError):
        break
sock.settimeout(0.1)

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6b — NAT hole punch
#   Sends HELO from sock (bound to port 5006) to the sender's ACK port so the
#   router creates a mapping that lets the sender's video packets reach us.
#   Works for full-cone and address-restricted NATs; port-restricted NATs still
#   require explicit port forwarding on the receiver's router.
# ─────────────────────────────────────────────────────────────────────────────
if _sender_ip:
    for _ in range(3):
        sock.sendto(b'HELO', (_sender_ip, ACK_PORT))
    print(f"NAT hole punched: port {UDP_PORT} → {_sender_ip}:{ACK_PORT}")

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Event helper
# ─────────────────────────────────────────────────────────────────────────────
def pump_events():
    """Drain the pygame event queue. Returns True if the user requested quit."""
    global screen, is_fullscreen
    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            return True
        if event.type == pygame.KEYDOWN:
            if event.key == pygame.K_q:
                return True
            if event.key == pygame.K_F11:
                is_fullscreen = not is_fullscreen
                if is_fullscreen:
                    screen = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
                else:
                    screen = pygame.display.set_mode((DISPLAY_WIDTH, DISPLAY_HEIGHT), pygame.RESIZABLE)
    return False

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Main receive loop
# ─────────────────────────────────────────────────────────────────────────────
try:
    while True:
        try:
            data, addr = sock.recvfrom(65536)  # blocks up to 0.1s
        except socket.timeout:
            if known_ack_addr is not None:
                _now = time.perf_counter()
                if _now - max(last_frame_time, last_heartbeat_time) >= HEARTBEAT_INTERVAL:
                    sock.sendto(b'HELO', known_ack_addr)
                    last_heartbeat_time = _now
            if pump_events():
                break
            continue

        # ─────────────────────────────────────────────────────────────────────
        # STEP 9 — Drain backlogged frames: keep only the latest
        # ─────────────────────────────────────────────────────────────────────
        sock.setblocking(False)
        try:
            while True:
                newer, newer_addr = sock.recvfrom(65536)
                data, addr = newer, newer_addr
                frames_dropped += 1
        except (BlockingIOError, OSError):
            pass
        sock.settimeout(0.1)

        ack_addr        = (addr[0], ACK_PORT)
        known_ack_addr  = ack_addr
        last_frame_time = time.perf_counter()

        if len(data) < 14:
            continue
        header      = data[:12]                             # seq + timestamp_ns, echoed in ACKs
        display_e2e = struct.unpack(">H", data[12:14])[0]  # E2E ms from server
        jpeg        = data[14:]

        # ─────────────────────────────────────────────────────────────────────
        # STEP 10 — ACK stage 0: frame received
        # ─────────────────────────────────────────────────────────────────────
        sock.sendto(header + b'\x00', ack_addr)

        frame = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)

        # ─────────────────────────────────────────────────────────────────────
        # STEP 11 — ACK stage 1: decode complete
        # ─────────────────────────────────────────────────────────────────────
        sock.sendto(header + b'\x01', ack_addr)

        if frame is not None:
            # cv2 returns BGR; pygame needs RGB
            rgb  = frame[:, :, ::-1]
            surf = pygame.image.frombuffer(rgb.tobytes(),
                                           (rgb.shape[1], rgb.shape[0]), 'RGB')

            # Letterbox: scale to fit window preserving aspect ratio
            win_w, win_h = screen.get_size()
            fw, fh = surf.get_size()
            scale  = min(win_w / fw, win_h / fh)
            sw, sh = int(fw * scale), int(fh * scale)
            scaled = pygame.transform.smoothscale(surf, (sw, sh))

            screen.fill((0, 0, 0))
            screen.blit(scaled, ((win_w - sw) // 2, (win_h - sh) // 2))

            # Overlay: FPS and E2E in the top-left corner
            if display_fps > 0:
                fps_surf = font.render(f"FPS {display_fps:.0f}", True, (0, 255, 0))
                e2e_surf = font.render(f"E2E {display_e2e}ms",   True, (0, 255, 0))
                box_w    = max(fps_surf.get_width(), e2e_surf.get_width()) + 16
                pygame.draw.rect(screen, (0, 0, 0), (5, 5, box_w, 55))
                screen.blit(fps_surf, (10, 8))
                screen.blit(e2e_surf, (10, 31))

            pygame.display.flip()

        # ─────────────────────────────────────────────────────────────────────
        # STEP 12 — ACK stage 2: frame is on screen
        # ─────────────────────────────────────────────────────────────────────
        sock.sendto(header + b'\x02', ack_addr)

        frames_shown += 1

        # ─────────────────────────────────────────────────────────────────────
        # STEP 13 — Print stats once per second
        # ─────────────────────────────────────────────────────────────────────
        now = time.perf_counter()
        if now - t_stats >= 1.0:
            fps         = frames_shown / (now - t_stats)
            display_fps = fps
            print(f"FPS: {fps:.1f}  (dropped: {frames_dropped})")
            frames_shown   = 0
            frames_dropped = 0
            t_stats        = now

        if pump_events():
            break

except KeyboardInterrupt:
    print("\nExiting...")
finally:
    # STEP 14 — Cleanup
    pygame.quit()
    sock.close()
