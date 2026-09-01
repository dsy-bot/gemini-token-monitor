@echo off
setlocal
echo ======================================================
echo   Building Antigravity Token Monitor v4.3 (.exe)
echo ======================================================

set CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe

if not exist "%CSC%" (
    echo [ERROR] csc.exe not found at %CSC%
    pause
    exit /b 1
)

"%CSC%" /target:winexe /optimize+ /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll /r:System.Management.dll /out:AntigravityTokenMonitor.exe Program.cs

if %ERRORLEVEL% equ 0 (
    echo.
    echo [SUCCESS] AntigravityTokenMonitor.exe build completed successfully!
) else (
    echo.
    echo [ERROR] Build failed with exit code %ERRORLEVEL%
)

endlocal
