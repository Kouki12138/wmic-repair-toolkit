@echo off
setlocal
cd /d "%~dp0"
echo ============================================
echo   WMIC repair tool
echo ============================================
echo.
echo Removing the "downloaded from internet" block flag ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>&1
echo Starting repair (a UAC prompt will appear, click Yes) ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-wmic.ps1"
echo.
echo If the window closed before you could read it, open:
echo   %USERPROFILE%\Desktop\wmic-repair-log.txt
pause
