@echo off
rem ---------------------------------------------------------------------------
rem Christopher OS - double-click this to SWITCH to another published version.
rem
rem Lists the recent releases (newest first, the installed one marked), asks
rem which number to switch to, and installs exactly that one - older, to step
rem back from a bad release, or newer. Update.bat still means "the latest".
rem
rem All the work and every safety check is update.ps1's (-Choose): it refuses
rem while this copy is running, keeps your .env, and verifies the build's
rem signature before saying it is done. Close the app's window first.
rem
rem Same shape as Update.bat, for the same reason: update.ps1 may rewrite this
rem file while it runs, so everything after the powershell call stays on its
rem line (cmd re-reads a .bat from disk line by line).
rem ---------------------------------------------------------------------------

title Christopher OS - switch version

cd /d "%~dp0"

if not exist "%~dp0update.ps1" (
  echo.
  echo   update.ps1 is missing from this folder - it does the switching.
  echo.
  pause
  exit /b 1
)

setlocal EnableDelayedExpansion
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" -Choose %* & set "rc=!ERRORLEVEL!" & pause & exit /b !rc!
