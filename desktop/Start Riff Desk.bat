@echo off
rem Double-click to start Riff Desk from source (needs Python 3.10+).
rem Prefer the ready-made RiffDesk.exe from the project's GitHub Actions page if you don't have Python.
cd /d "%~dp0"
where python >nul 2>nul
if errorlevel 1 (
  echo Python 3.10 or newer is required: https://www.python.org/downloads/
  echo Tick "Add python.exe to PATH" during setup, then double-click this file again.
  pause
  exit /b 1
)
python riffdesk.py %*
pause
