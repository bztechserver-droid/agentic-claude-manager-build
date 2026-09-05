@echo off
rem ---------------------------------------------------------------------------
rem Christopher OS - the thing you double-click in a sealed release folder.
rem
rem It exists because ship-launcher.ps1 cannot be double-clicked usefully:
rem Windows' default action for a .ps1 is "edit in Notepad", and even when it is
rem not, the default execution policy refuses an unsigned script. This file is
rem the one-line answer to both.
rem
rem %~dp0 is THIS file's own folder, with a trailing backslash, so the launcher
rem is found no matter what working directory cmd was handed - Explorer commonly
rem starts a double-clicked .bat in C:\Windows\System32, and a bare
rem "ship-launcher.ps1" would miss.
rem
rem This .bat is itself covered by integrity.json, so repointing it at some
rem other script changes its hash and the server's own boot check then refuses
rem to start. That is deterrence against a casual edit, not security: whoever
rem owns the machine can still run node directly, and ship-launcher.ps1's header
rem says so at length rather than letting anyone discover it after a promise.
rem ---------------------------------------------------------------------------

rem Names the taskbar button and the window. Worth one line: a recipient running
rem two releases side by side otherwise has two identical "Administrator: cmd"
rem buttons and no way to tell which window belongs to which folder.
title Christopher OS

rem Fail here, with a sentence, rather than letting powershell.exe fail with its
rem own multi-line error about a path the reader did not choose and cannot
rem place. The commonest cause is someone copying just the .bat out of the
rem release folder to their desktop, or a zip that was only half extracted.
if not exist "%~dp0ship-launcher.ps1" (
  echo.
  echo   ship-launcher.ps1 is missing from this folder.
  echo   Keep Start.bat inside the release folder - it starts the app from here.
  echo.
  pause
  exit /b 1
)

rem -NoProfile so a recipient's own PowerShell profile cannot change how the app
rem starts, or add output above the launcher's first line.
rem -ExecutionPolicy Bypass because a release is not code-signed. It overrides
rem the per-user and per-process policy, and it CANNOT override a MachinePolicy
rem or UserPolicy set by Group Policy - on a locked-down corporate machine
rem powershell.exe will refuse the file and print why, which is the honest
rem outcome and not something this .bat should try to work around.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ship-launcher.ps1"

rem Captured BEFORE pause, because pause runs a command and the launcher's exit
rem code is the thing a shortcut or a scheduled task would want to read:
rem   0 ran and stopped normally | 1 could not start | 2 this copy already open
rem A caller that wants those codes without a window waiting on a keypress
rem should run ship-launcher.ps1 directly; this file is for the double-click.
set "rc=%ERRORLEVEL%"

rem The trailing PAUSE is deliberate, not leftover debug. When the launcher
rem REFUSES a modified copy it prints the exact file that changed, and without
rem PAUSE this window would close before anyone could read it. That message is
rem the entire point of shipping a sealed folder.
pause
exit /b %rc%
