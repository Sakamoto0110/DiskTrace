@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0disk-report.ps1" %*
