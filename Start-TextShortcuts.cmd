@echo off
REM Launches the Text Shortcuts Manager (GUI). It runs the expander and lets you
REM add / edit / delete shortcuts. Closing the window keeps it running in the tray.
start "Text Shortcuts" powershell.exe -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0TextShortcutsManager.ps1"
