import socket
import struct
import sys

try:
    import cv2
    import numpy as np
except ImportError:
    print("Missing dependencies. Run: pip install opencv-python")
    sys.exit(1)

UDP_PORT = 5006
ACK_PORT = 5007

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
        header = data[:12]
        jpeg = data[12:]

        # Stage 0: frame received (before any processing)
        sock.sendto(header + b'\x00', ack_addr)

        frame = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)

        # Stage 1: frame decoded
        sock.sendto(header + b'\x01', ack_addr)

        if frame is not None:
            cv2.imshow("RemoteGamepad", frame)

        key = cv2.waitKey(1) & 0xFF

        # Stage 2: frame drawn (waitKey triggers actual render)
        sock.sendto(header + b'\x02', ack_addr)

        if key == ord('q'):
            break

except KeyboardInterrupt:
    print("\nExiting...")
finally:
    cv2.destroyAllWindows()
    sock.close()
