@echo off
setlocal

echo.
echo  RemoteGamepad Installer
echo  =======================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_setup.ps1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  Installation failed. See errors above.
)

echo.
pause
