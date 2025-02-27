import socket
import json
import pyvjoy
import math

# Configuration
UDP_IP = "0.0.0.0"  # Listen on all available interfaces
UDP_PORT = 5005

# Create an UDP socket
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((UDP_IP, UDP_PORT))

# Initialize vJoy device (Assuming ID 1)
j = pyvjoy.VJoyDevice(1)

print(f"Listening for UDP packets on {UDP_IP}:{UDP_PORT}...")

def set_vjoy_buttons(buttons):
    for button, state in buttons.items():
        button_id = int(button.split('_')[1]) + 1  # Convert button_0 to vJoy button 1
        j.set_button(button_id, state)

def set_vjoy_axes(axes):
    for axis, value in axes.items():
        axis_value = int((value + 1) * 16383)  # Normalize to vJoy range (0-32767)
        if "axis_0" in axis:
            j.set_axis(pyvjoy.HID_USAGE_Z, axis_value)
        elif "axis_1" in axis:
            j.set_axis(pyvjoy.HID_USAGE_X, axis_value)
        elif "axis_2" in axis:
            j.set_axis(pyvjoy.HID_USAGE_Y, axis_value)
        elif "axis_3" in axis:
            j.set_axis(pyvjoy.HID_USAGE_RX, axis_value)
        elif "axis_4" in axis:
            j.set_axis(pyvjoy.HID_USAGE_RY, axis_value)
        elif "axis_5" in axis:
            j.set_axis(pyvjoy.HID_USAGE_RZ, axis_value)

def set_vjoy_hat(dpads):
    # Set the POV hat based on d-pad (hat) input
    if "dpad_0" in dpads:
        x, y = dpads["dpad_0"]
        
        # Handle the neutral position properly
        if x == 0 and y == 0:
            pov_value = -1  # Neutral position for vJoy
        else:
            angle = math.degrees(math.atan2(x, y))  # Calculate angle in degrees
            if angle < 0:
                angle += 360  # Ensure positive angle
            
            # Convert to vJoy expected format (hundredths of a degree)
            pov_value = int(angle * 100)

        # Set the POV hat value
        try:
            j.set_cont_pov(1,pov_value)
        except pyvjoy.exceptions.vJoyException as e:
            print("Failed to set POV hat:", e)

try:
    while True:
        # Receive data
        data, addr = sock.recvfrom(1024)  # Buffer size of 1024 bytes
        
        # Decode JSON data
        try:
            controller_data = json.loads(data.decode())
            print(json.dumps(controller_data, indent=2))
            
            # Map buttons, axes, and d-pad to vJoy
            set_vjoy_buttons(controller_data.get("buttons", {}))
            set_vjoy_axes(controller_data.get("axes", {}))
            set_vjoy_hat(controller_data.get("dpad", {}))
        except json.JSONDecodeError:
            print("Received invalid JSON data")
except KeyboardInterrupt:
    print("\nReceiver shutting down...")
finally:
    sock.close()