@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "INSTALL_SCRIPT=%SCRIPT_DIR%installer\Install-360GS.ps1"
set "INSTALL_GUI_SCRIPT=%SCRIPT_DIR%installer\Install-360GS.Gui.ps1"
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"

if not exist "%INSTALL_SCRIPT%" (
  echo Installer script not found:
  echo %INSTALL_SCRIPT%
  pause
  exit /b 1
)

if exist "%PWSH%" (
  set "POWERSHELL_EXE=%PWSH%"
) else (
  set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
)

if not exist "%INSTALL_GUI_SCRIPT%" (
  echo Installer GUI script not found:
  echo %INSTALL_GUI_SCRIPT%
  pause
  exit /b 1
)

if /I "%~1"=="--self-test-gui" (
  "%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_GUI_SCRIPT%" -SelfTest
  exit /b %ERRORLEVEL%
)

if "%~1"=="" (
  "%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_GUI_SCRIPT%" -InitialInstallDir "%LOCALAPPDATA%\360GS"
  exit /b %ERRORLEVEL%
)

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_SCRIPT%" %*
exit /b %ERRORLEVEL%
