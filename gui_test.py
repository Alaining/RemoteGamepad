import tkinter as tk
from tkinter import scrolledtext

import pygame
import socket
import json
import time
import copy

############################################################################################################
# Function to apply deadzone to axis values
def apply_deadzone(value, deadzone):
    if abs(value) < deadzone:
        return 0
    return value

def start_remote_gamepad(user_input):
    # Prompt the user for the UDP_IP address
    # print("IP controller by Alain")
    # UDP_IP = input("Enter the receiver's IP address (example 203.0.113.2): ").strip()
    UDP_IP = user_input
    if UDP_IP == "":
        UDP_IP = "127.0.0.1"
    UDP_PORT = 5005
    DEADZONE = 0.1
    PRINT_UPDATES = True

    # Validate the IPv6 address (basic check)
    if not UDP_IP or "." not in UDP_IP:
        print("Invalid IP address. Exiting...")
        terminal_print("Invalid IP address. Exiting...\n")
        exit()
    else:
        print(f"Connecting to IP {UDP_IP}")
        terminal_print(f"Connecting to IP {UDP_IP}\n")

    # Initialize Pygame and Joystick
    pygame.init()
    pygame.joystick.init()

    if pygame.joystick.get_count() == 0:
        print("No controller detected!")
        terminal_print("No controller detected!\n")
        exit()

    joystick = pygame.joystick.Joystick(0)
    joystick.init()
    print(f"Connected to: {joystick.get_name()}")
    terminal_print(f"Connected to: {joystick.get_name()}\n")

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
                    terminal_print(json.dumps(data, indent=2) + '\n')
                prev_data = copy.deepcopy(data)

                # Send data over UDP
                message = json.dumps(data)
                sock.sendto(message.encode(), (UDP_IP, UDP_PORT))

            time.sleep(0.01)
    except KeyboardInterrupt:
        print("\nExiting...")
    finally:
        pygame.quit()
############################################################################################################


# Functions for button clicks
def print_hello():
    terminal.insert(tk.END, "Hello\n")

def print_world():
    terminal.insert(tk.END, " World!\n")

def print_input():
    user_input = input_box.get()
    if user_input != "" and user_input != placeholder_text:
        terminal.insert(tk.END, user_input + '\n')
    input_box.delete(0, tk.END)
    set_placeholder(None)
    start_remote_gamepad(user_input)

def terminal_print(text):
    terminal.insert(tk.END, text)
    
# Placeholder handling functions
placeholder_text = "Enter IPv4 address here"

def set_placeholder(event):
    if input_box.get() == "":
        input_box.insert(0, placeholder_text)
        input_box.config(fg='grey')

def clear_placeholder(event):
    if input_box.get() == placeholder_text:
        input_box.delete(0, tk.END)
        input_box.config(fg='black')

# Create window
window = tk.Tk()
window.title("Alain Cloud")
window.geometry("400x320")

# Input box with placeholder
input_box = tk.Entry(window, width=40, fg='grey')
input_box.pack(pady=5)
input_box.insert(0, placeholder_text)
input_box.bind("<FocusIn>", clear_placeholder)
input_box.bind("<FocusOut>", set_placeholder)

# Button to print user input
btn_input = tk.Button(window, text="Print Input", command=print_input)
btn_input.pack(pady=5)

# Terminal-like output
terminal = scrolledtext.ScrolledText(window, width=40, height=10)
terminal.pack(pady=10)

# Start GUI event loop
window.mainloop()