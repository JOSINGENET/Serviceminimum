@echo off
rem Lance Service Minimum (demande les droits administrateur)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ServiceMinimum.ps1"
if errorlevel 1 pause
