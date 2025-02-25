import pygame
import socket
import json
import time
import copy

# Prompt the user for the UDP_IP address
UDP_IP = input("Enter the receiver's IPv6 address (e.g., 2806:290:a80a:64cb:8fe5:b5e0:58dd:668a): ").strip()
UDP_PORT = 5005
DEADZONE = 0.01
PRINT_UPDATES = True

# # Validate the IPv6 address (basic check)
# if not UDP_IP or ":" not in UDP_IP:
#     print("Invalid IPv6 address. Exiting...")
#     exit()
    
# Create an IPv6 UDP socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

json_text = """
{
  "buttons": {
    "button_0": 0,
    "button_1": 0,
    "button_2": 0,
    "button_3": 0,
    "button_4": 0,
    "button_5": 0,
    "button_6": 0,
    "button_7": 0,
    "button_8": 0,
    "button_9": 0,
    "button_10": 0,
    "button_11": 0,
    "button_12": 0,
    "button_13": 0,
    "button_14": 0,
    "button_15": 0
  },
  "axes": {
    "axis_0": 0.0,
    "axis_1": 0.0,
    "axis_2": 0.0,
    "axis_3": 0.0,
    "axis_4": 0.0,
    "axis_5": 0.0,
    "axis_6": -1.0,
    "axis_7": -1.0
  },
  "dpad": {
    "dpad_0": [
      0,
      0
    ]
  }
}
"""

# Main loop
try:
    while True:
        
        # Print data before sending
        message = json_text
        print(message)

        # Send data over UDP
        sock.sendto(message.encode(), (UDP_IP, UDP_PORT))
        
        time.sleep(1)
    
    
except KeyboardInterrupt:
    print("\nExiting...")