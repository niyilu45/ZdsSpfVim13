@echo off
setlocal
title spf13-vim Offline Installer - No Caps Mapping

echo.
echo ============================================
echo   spf13-vim Installer - Caps Mapping Off
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

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -SkipCapsCtrl
set "INSTALL_RESULT=%ERRORLEVEL%"

echo.
if not "%INSTALL_RESULT%"=="0" (
    echo Installation failed. See the message above.
) else (
    echo Installation finished successfully without the Caps mapping.
)
echo.
pause
exit /b %INSTALL_RESULT%
