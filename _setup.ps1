# _setup.ps1 - run via "Install RemoteGamepad.bat", not directly.

$INSTALL_DIR = $PSScriptRoot

function Write-Step($n, $total, $msg) {
    Write-Host ""
    Write-Host "  [$n/$total] $msg" -ForegroundColor Yellow
}

function Write-OK($msg) { Write-Host "      OK: $msg" -ForegroundColor Green }

function Write-Err($msg) {
    Write-Host "      ERROR: $msg" -ForegroundColor Red
    exit 1
}

function Find-Python {
    $machine = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    $user    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = "$machine;$user"

    $p = Get-Command python -ErrorAction SilentlyContinue
    if ($p -and $p.Source -notlike "*WindowsApps*") { return $p.Source }

    $globs = @(
        "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
        "C:\Python3*\python.exe",
        "C:\Program Files\Python3*\python.exe"
    )
    foreach ($g in $globs) {
        $hit = Get-Item $g -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

Write-Host ""
Write-Host "  =========================" -ForegroundColor Cyan
Write-Host "   RemoteGamepad Installer  " -ForegroundColor Cyan
Write-Host "  =========================" -ForegroundColor Cyan

# --- Step 1: Python ---
Write-Step 1 2 "Checking for Python"

$pythonExe = Find-Python

if (-not $pythonExe) {
    Write-Host "      Python not found - installing via winget..." -ForegroundColor Yellow

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "      winget is not available." -ForegroundColor Red
        Write-Host "      Install Python 3 from https://www.python.org/downloads/ then re-run the installer." -ForegroundColor White
        exit 1
    }

    $pythonIds = @("Python.Python.3.13", "Python.Python.3.12", "Python.Python.3.11", "Python.Python.3.10")
    $wingetOk = $false
    foreach ($pkgId in $pythonIds) {
        Write-Host "      Trying $pkgId..." -ForegroundColor Yellow
        winget install --id $pkgId --scope user --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -eq 0) { $wingetOk = $true; break }
    }

    if (-not $wingetOk) {
        Write-Host "      winget could not install Python automatically." -ForegroundColor Red
        Write-Host "      Install Python 3 from https://www.python.org/downloads/ then re-run the installer." -ForegroundColor White
        exit 1
    }

    $pythonExe = Find-Python
    if (-not $pythonExe) {
        Write-Err "Python was installed but could not be located. Please restart your PC and re-run the installer."
    }
}

$pyVer = & "$pythonExe" --version
Write-OK "$pyVer"

# --- Step 2: Python environment ---
Write-Step 2 2 "Installing Python packages"

$venvDir    = "$INSTALL_DIR\.venv"
$venvPython = "$venvDir\Scripts\python.exe"

try {
    & "$pythonExe" -m venv $venvDir
} catch {
    Write-Err "Failed to create virtual environment: $_"
}

try {
    & $venvPython -m pip install --upgrade pip --quiet --disable-pip-version-check
    & $venvPython -m pip install pygame opencv-python numpy pyvjoy --disable-pip-version-check
} catch {
    Write-Err "Package installation failed: $_"
}

Write-OK "Packages installed."

# --- Launcher batch files (Python scripts) ---
$pyLaunchers = @{
    "Launch Server.bat" = "launch_server.py"
    "Launch Client.bat" = "launch_client.py"
}

foreach ($bat in $pyLaunchers.Keys) {
    $pyScript = $pyLaunchers[$bat]
    Set-Content -Path "$INSTALL_DIR\$bat" -Encoding ASCII -Value "@echo off
cd /d `"$INSTALL_DIR`"
call .venv\Scripts\activate.bat
python $pyScript
pause"
}

# --- Launcher batch file (Network Diagnostics) ---
Set-Content -Path "$INSTALL_DIR\Network Diagnostics.bat" -Encoding ASCII -Value "@echo off
cd /d `"$INSTALL_DIR`"
powershell -NoProfile -ExecutionPolicy Bypass -File `"$INSTALL_DIR\network_diagnostics.ps1`"
pause"

# --- Desktop shortcuts ---
$shell   = New-Object -ComObject WScript.Shell
$desktop = [System.Environment]::GetFolderPath("Desktop")

$shortcuts = @{
    "RemoteGamepad - Launch Server"       = "Launch Server.bat"
    "RemoteGamepad - Launch Client"       = "Launch Client.bat"
    "RemoteGamepad - Network Diagnostics" = "Network Diagnostics.bat"
}

foreach ($name in $shortcuts.Keys) {
    $bat = $shortcuts[$name]
    $lnk = $shell.CreateShortcut("$desktop\$name.lnk")
    $lnk.TargetPath       = "$INSTALL_DIR\$bat"
    $lnk.WorkingDirectory = $INSTALL_DIR
    $lnk.Save()
}

# --- Done ---
Write-Host ""
Write-Host "  =========================" -ForegroundColor Cyan
Write-Host "   Installation complete!   " -ForegroundColor Cyan
Write-Host "  =========================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Desktop shortcuts created:" -ForegroundColor White
foreach ($name in $shortcuts.Keys) {
    Write-Host "    - $name" -ForegroundColor White
}
Write-Host ""
