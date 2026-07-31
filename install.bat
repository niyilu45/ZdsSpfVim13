@echo off
setlocal
title spf13-vim Offline Installer

echo.
echo ============================================
echo       spf13-vim Offline Installer
echo ============================================
echo.

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: Windows PowerShell was not found.
    echo This installer requires Windows PowerShell.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "INSTALL_RESULT=%ERRORLEVEL%"

echo.
if not "%INSTALL_RESULT%"=="0" (
    echo Installation failed. See the message above.
) else (
    echo Installation finished successfully.
)
echo.
pause
exit /b %INSTALL_RESULT%
