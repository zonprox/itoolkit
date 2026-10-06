@echo off
rem ==============================================================================
rem Run-IToolkit.bat
rem Windows Shell Launcher & Self-Elevation Wrapper for IToolkit
rem Checks for Administrator privileges and relaunches elevated if needed,
rem then executes Start-IToolkit.ps1 with ExecutionPolicy Bypass.
rem ==============================================================================
setlocal EnableDelayedExpansion

rem Set current working directory to the directory where this batch file resides
cd /d "%~dp0"

rem 1. Check for administrative privileges
rem Uses openfiles and net session to verify elevated security token
openfiles >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    net session >nul 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo [IToolkit] Administrative privileges required. Requesting elevation via UAC...
        if "%~1"=="" (
            powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
        ) else (
            powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
        )
        if !ERRORLEVEL! NEQ 0 (
            echo [IToolkit] Elevation was cancelled or failed.
        )
        exit /b !ERRORLEVEL!
    )
)

rem 2. Detect PowerShell executable (pwsh.exe for PS 7+, fallback to powershell.exe for PS 5.1)
set "PS_EXE=powershell.exe"
where pwsh.exe >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set "PS_EXE=pwsh.exe"
)

rem 3. Launch Start-IToolkit.ps1 with ExecutionPolicy Bypass
echo [IToolkit] Launching IToolkit administrative console...
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-IToolkit.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

exit /b %EXIT_CODE%
