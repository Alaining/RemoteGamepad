import pygame

# Initialize pygame and joystick
pygame.init()
pygame.joystick.init()

# Check if a controller is connected
if pygame.joystick.get_count() == 0:
    print("No controller detected.")
    exit()

joystick = pygame.joystick.Joystick(0)
joystick.init()
print(f"Connected to: {joystick.get_name()}")

try:
    while True:
        pygame.event.pump()  # Process events

        # Read buttons
        for i in range(joystick.get_numbuttons()):
            print(f"Button {i}: {'Pressed' if joystick.get_button(i) else 'Released'}")

        # Read axes
        for i in range(joystick.get_numaxes()):
            print(f"Axis {i}: {joystick.get_axis(i):.3f}")

        # Read hats (D-Pad)
        for i in range(joystick.get_numhats()):
            hat = joystick.get_hat(i)
            print(f"Hat {i}: X={hat[0]}, Y={hat[1]}")

        pygame.time.wait(100)  # Avoid spamming output

except KeyboardInterrupt:
    print("\nExiting...")
    pygame.quit()
