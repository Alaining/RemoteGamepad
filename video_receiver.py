import socket
import struct
import sys

try:
    import cv2
    import numpy as np
except ImportError:
    print("Missing dependencies. Run: pip install opencv-python")
    sys.exit(1)

TCP_PORT = 5007


def recv_all(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", TCP_PORT))
server.listen(1)
print(f"Waiting for sender on port {TCP_PORT}... (press Q in the video window to quit)")

conn, addr = server.accept()
conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
print(f"Connected: {addr[0]}")

try:
    while True:
        header = recv_all(conn, 4)
        if not header:
            print("Sender disconnected.")
            break

        size = struct.unpack(">I", header)[0]
        data = recv_all(conn, size)
        if not data:
            break

        frame = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
        if frame is not None:
            cv2.imshow("RemoteGamepad", frame)

        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

except KeyboardInterrupt:
    print("\nExiting...")
finally:
    cv2.destroyAllWindows()
    conn.close()
    server.close()
