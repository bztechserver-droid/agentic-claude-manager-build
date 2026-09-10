@echo off
rem ---------------------------------------------------------------------------
rem Christopher OS - double-click this to INSTALL or UPDATE the app.
rem
rem   Empty folder     -> installs the latest release into it
rem   Existing install -> updates it to the latest release
rem
rem TO GIVE THIS TO SOMEONE: send them this file AND update.ps1, together. They
rem put the pair in the folder they want the app to live in and double-click
rem this one. After installing, both files are sitting inside the install they
rem just made, so double-clicking again is the update.
rem
rem It exists for the same two reasons Start.bat does: Windows' default action
rem for a .ps1 is "edit in Notepad", and even when it is not, the default
rem execution policy refuses an unsigned script. This file answers both and is
rem deliberately thin - all the work, and all the safety checks, are in
rem update.ps1 beside it.
rem
rem NOT SIGNED, unlike everything the manifest covers. This pair is published in
rem the release repo but kept out of integrity.json - the boot gate only checks
rem the files that manifest lists and does not object to extra ones. So read
rem both files before trusting them, the way you would any script that rewrites
rem a folder.
rem
rem cd /d "%~dp0" because the SCRIPT'S OWN FOLDER is the one a double-click
rem means, and the working directory Windows hands a .bat is not reliably that -
rem a shortcut with a blank "Start in", or an elevated prompt, can hand it
rem C:\Windows\System32. update.ps1 targets the current directory, so this line
rem is what makes "the folder this file is in" the answer. update.ps1 refuses
rem System32 and friends anyway, as a second line of defence.
rem ---------------------------------------------------------------------------

title Christopher OS - install / update

cd /d "%~dp0"

if not exist "%~dp0update.ps1" (
  echo.
  echo   update.ps1 is missing from this folder.
  echo   Update.bat and update.ps1 travel together - copy both, not just this one.
  echo.
  pause
  exit /b 1
)

rem -NoProfile so a user's own PowerShell profile cannot change how this runs or
rem add output above the first line. -ExecutionPolicy Bypass because a release is
rem not code-signed; it cannot override a Group Policy MachinePolicy/UserPolicy,
rem in which case powershell.exe refuses and prints why - the honest outcome, and
rem not something this .bat should work around.
rem
rem Arguments are forwarded: `Update.bat -Yes` skips the confirmation for a
rem scheduled run, and `Update.bat -Path D:\apps\cos` targets another folder.
rem
rem ONE LINE BELOW, ON PURPOSE. The release tracks this file, so update.ps1
rem rewrites it while it is running. cmd.exe does not load a .bat into memory -
rem it re-reads the file at a byte offset for every line - so anything on a
rem LATER line would be read out of whichever Update.bat the release just wrote,
rem at an offset that may now land mid-word. Everything after the powershell
rem call is therefore chained onto its line with &: cmd parses the whole line
rem before running any of it, so the rest of this run comes from the file as it
rem was when it started. Delayed expansion (!rc!) because %rc% on that same line
rem would be expanded at parse time, before powershell has run.
rem
rem Exit codes:   0  installed, updated, or already current
rem               1  refused (app running, folder not empty, no git, bad remote, ...)
rem            3..7  the build failed its own integrity check - do not run it
rem The trailing pause is deliberate: when this refuses - app still open, folder
rem not empty, new build failed to verify - the window would otherwise close
rem before anyone could read which it was.
setlocal EnableDelayedExpansion
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" %* & set "rc=!ERRORLEVEL!" & pause & exit /b !rc!
