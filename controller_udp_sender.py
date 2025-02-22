import pygame
import socket
import json
import time
import copy

# Prompt the user for the UDP_IP address
UDP_IP = input("Enter the receiver's IPv6 address (e.g., 2806:290:a80a:64cb:8fe5:b5e0:58dd:668a): ").strip()
UDP_PORT = 5005
DEADZONE = 0.1
PRINT_UPDATES = True

# Validate the IPv6 address (basic check)
if not UDP_IP or ":" not in UDP_IP:
    print("Invalid IPv6 address. Exiting...")
    exit()

# Initialize Pygame and Joystick
pygame.init()
pygame.joystick.init()

if pygame.joystick.get_count() == 0:
    print("No controller detected!")
    exit()

joystick = pygame.joystick.Joystick(0)
joystick.init()
print(f"Connected to: {joystick.get_name()}")

# Create an IPv6 UDP socket
sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)

# Store last button states to detect changes
last_buttons = {}

# Declare data vars
data = {
    "buttons": {},
    "axes": {}
}

prev_data = {
    "buttons": {},
    "axes": {}
}

# Main loop
try:
    while True:
        pygame.event.pump()

        # Detect button presses
        for i in range(joystick.get_numbuttons()):
            current_state = joystick.get_button(i)
            data["buttons"][f"button_{i}"] = current_state

        if data != prev_data:
            print(json.dumps(data, indent=2))
            prev_data = copy.deepcopy(data)

            # Send data over UDP
            message = json.dumps(data)
            sock.sendto(message.encode(), (UDP_IP, UDP_PORT))

        time.sleep(0.01)
except KeyboardInterrupt:
    print("\nExiting...")
finally:
    pygame.quit()