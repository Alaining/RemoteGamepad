$OUT_ZIP = "$PSScriptRoot\RemoteGamepad_Client.zip"

$FILES = @(
    "Install RemoteGamepad.bat",
    "_setup.ps1",
    "sender_gui.py",
    "server_gui.py",
    "launch_server.py",
    "controller_udp_sender.py",
    "controller_udp_receiver.py",
    "video_udp_sender.py",
    "video_receiver.py",
    "network_diagnostics.ps1"
)

# Verify all files exist before doing anything
foreach ($f in $FILES) {
    if (-not (Test-Path "$PSScriptRoot\$f")) {
        Write-Host "ERROR: missing file: $f" -ForegroundColor Red
        exit 1
    }
}

# Remove old ZIP if present
if (Test-Path $OUT_ZIP) { Remove-Item $OUT_ZIP }

$paths = $FILES | ForEach-Object { "$PSScriptRoot\$_" }
Compress-Archive -Path $paths -DestinationPath $OUT_ZIP

Write-Host "Created: $OUT_ZIP" -ForegroundColor Green
