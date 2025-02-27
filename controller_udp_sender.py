import pygame
import socket
import json
import time
import copy

# Prompt the user for the UDP_IP address
UDP_IP = input("Enter the receiver's IP address (example 203.0.113.2): ").strip()
if UDP_IP == "":
    UDP_IP = "127.0.0.1"
UDP_PORT = 5005
DEADZONE = 0.1
PRINT_UPDATES = True

# Validate the IPv6 address (basic check)
if not UDP_IP or "." not in UDP_IP:
    print("Invalid IP address. Exiting...")
    exit()
else:
    print(f"Connecting to IP {UDP_IP}")

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
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

# Store last button states to detect changes
last_buttons = {}

# Initialize the data dictionary with empty lists or dictionaries for buttons, axes, and dpad
data = {
    "buttons": {},
    "axes": {},
    "dpad": {}
}


prev_data = copy.deepcopy(data)

# Function to apply deadzone to axis values
def apply_deadzone(value, deadzone):
    if abs(value) < deadzone:
        return 0
    return value

# Main loop
try:
    while True:
        pygame.event.pump()

        # Detect button presses
        for i in range(joystick.get_numbuttons()):
            current_state = joystick.get_button(i)
            data["buttons"][f"button_{i}"] = current_state

        # Detect axis movements
        for i in range(joystick.get_numaxes()):
            current_state = round(joystick.get_axis(i),1)
            data["axes"][f"axis_{i}"] = current_state

        # Detect hat (d-pad) movements
        for i in range(joystick.get_numhats()):
            data["dpad"][f"dpad_{i}"] = joystick.get_hat(i)
            
        # Map dpat to button 13-16
        for i in range(joystick.get_numhats()):
            # Map dpat to buttons 13-16
            num_elements = len(data["dpad"][f"dpad_{i}"])
            for k in range(num_elements):
                hat_value = data["dpad"][f"dpad_{i}"][k]
                if (hat_value == 0):
                    data["buttons"][f"button_{13+k*2}"] = 0
                    data["buttons"][f"button_{14+k*2}"] = 0
                elif (hat_value == -1):
                    data["buttons"][f"button_{13+k*2}"] = 1
                elif (hat_value == 1):
                    data["buttons"][f"button_{14+k*2}"] = 1

        if data != prev_data:
            if PRINT_UPDATES:
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