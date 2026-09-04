@echo off
setlocal

echo ========================================
echo Bootstrap Starting...
echo ========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-All.ps1"

set EXITCODE=%ERRORLEVEL%

echo.
if %EXITCODE% EQU 0 (
    echo SUCCESS: All operations completed successfully.
) else (
    echo ERROR: One or more operations failed. Exit Code: %EXITCODE%
)

echo.
pause
exit /b %EXITCODE%
