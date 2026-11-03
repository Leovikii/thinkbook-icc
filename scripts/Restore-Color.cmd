@echo off
setlocal
rem Reset inherited PowerShell 7 module paths before starting Windows PowerShell.
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-Color.ps1" %*
set "restore_exit=%errorlevel%"
echo.
pause
exit /b %restore_exit%
