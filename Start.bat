@echo off
cd /d "%~dp0"
set "SCRIPT="
for %%F in (Tweaks*.ps1) do if not defined SCRIPT set "SCRIPT=%%~fF"
if not defined SCRIPT (
  echo Tweaks_by_yzemu.ps1 not found next to this file.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
exit /b 0
