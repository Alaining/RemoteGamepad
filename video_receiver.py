import socket
import sys

try:
    import cv2
    import numpy as np
except ImportError:
    print("Missing dependencies. Run: pip install opencv-python")
    sys.exit(1)

UDP_PORT = 5006
ACK_PORT = 5007  # sender listens here for latency ACKs

# Each received packet: [seq: 4B][timestamp_ns: 8B][JPEG data]
# Each ACK sent back:   [seq: 4B][timestamp_ns: 8B][stage: 1B]
# Stages: 0=received, 1=decoded, 2=drawn — sender uses these to measure per-stage latency.
# All timestamps are the sender's; receiver never does time calculations.

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
sock.bind(("0.0.0.0", UDP_PORT))
print(f"Listening on port {UDP_PORT}... (press Q in the video window to quit)")

try:
    while True:
        data, addr = sock.recvfrom(65536)
        ack_addr = (addr[0], ACK_PORT)

        if len(data) < 12:
            continue
        header = data[:12]   # seq + timestamp, echoed back verbatim in every ACK
        jpeg = data[12:]

        # Stage 0: frame received, no processing yet
        sock.sendto(header + b'\x00', ack_addr)

        frame = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)

        # Stage 1: decode complete
        sock.sendto(header + b'\x01', ack_addr)

        if frame is not None:
            cv2.imshow("RemoteGamepad", frame)

        key = cv2.waitKey(1) & 0xFF  # pumps the OpenCV event loop, actually renders the frame

        # Stage 2: frame on screen
        sock.sendto(header + b'\x02', ack_addr)

        if key == ord('q'):
            break

except KeyboardInterrupt:
    print("\nExiting...")
finally:
    cv2.destroyAllWindows()
    sock.close()
