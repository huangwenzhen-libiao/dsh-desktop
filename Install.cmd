@echo off
setlocal
title DSH Desktop Setup
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set "installResult=%ERRORLEVEL%"
if not "%installResult%"=="0" echo Installation was not completed. See the message above.
pause
exit /b %installResult%
