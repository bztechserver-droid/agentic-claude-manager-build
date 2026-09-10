# ---------------------------------------------------------------------------
# Christopher OS - INSTALL or UPDATE, in the current folder.
#
#   https://github.com/bztechserver-droid/agentic-claude-manager-build
#
# Hand this file (with Update.bat) to anyone. They drop the pair into the folder
# they want the app to live in, run it, and:
#
#   * empty folder      -> INSTALLS the latest release into it
#   * existing install  -> UPDATES it to the latest release
#
# After installing, the script is sitting inside the install it just made, so
# running it again is the update. One file does both jobs on purpose: a separate
# installer is a second thing to keep in step with the release format.
#
# THE TARGET IS THE CURRENT DIRECTORY, not the folder this script came from.
# Copy it somewhere and run it there and that is where the app lands. Because
# "current directory" is easy to get wrong - Explorer starts a double-clicked
# .bat in its own folder, but a shortcut or an elevated shell can start it in
# C:\Windows\System32 - section 2 refuses the handful of places nobody means.
#
# WHY reset/checkout AND NOT pull. A release folder is a build OUTPUT, not a
# working tree - nothing here is meant to have been edited, and every file is
# hashed in integrity.json. A merge can leave a conflicted file on disk, and a
# conflicted file is one whose hash no longer matches the manifest: the app
# would refuse to start with "MODIFIED FILE", reading as corruption rather than
# as a half-finished merge. Reset makes the tree exactly the commit, which is
# the only state the signature can ever verify.
#
# UNTRACKED FILES SURVIVE, which is what lets this script live in the folder it
# rewrites: reset --hard and checkout -f rewrite TRACKED files and touch nothing
# else. Nothing here runs `git clean`, deliberately - it would delete this
# script mid-run.
#
# WHAT THIS DOES NOT DO. It does not start the app and it does not stop it.
# Stopping belongs to ship-launcher.ps1, which owns a named mutex to do it with;
# reaching in from here would be a second opinion about who is running. So it
# refuses to touch a live install and asks you to close the window instead.
# ---------------------------------------------------------------------------
param(
  # Skip the confirmation prompt. For a scheduled run - every safety check still
  # applies, this only removes the keystroke.
  [switch]$Yes,
  # Install/update somewhere other than the current directory.
  [string]$Path
)

$ErrorActionPreference = 'Stop'

$REPO = 'https://github.com/bztechserver-droid/agentic-claude-manager-build.git'
$REPO_NAME = 'agentic-claude-manager-build'

function Fail($msg, $code = 1) {
  Write-Host ""
  Write-Host "  $msg" -ForegroundColor Red
  Write-Host ""
  exit $code
}

# Who, if anyone, is listening on this copy's port - and crucially, whether it
# is THIS copy or a different one.
#
# "Is the port busy" is the wrong question and answering it that way blocked a
# real update: two installs share the shipped default 4740, so a second copy
# running made the first one un-updatable, with a message telling the user to
# close a window that had nothing to do with it. The owning process's command
# line carries the path of the server\index.js it was started with, which is
# direct evidence of WHICH folder is running.
#
# .Contains, not -like: a path is a literal here, and -like would read [ ] in a
# folder name as a character class.
function Get-PortOwner($portNumber, $rootPath) {
  $result = @{ Ours = $false; Other = $null }
  $conns = Get-NetTCPConnection -State Listen -LocalPort $portNumber -ErrorAction SilentlyContinue
  foreach ($c in $conns) {
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.OwningProcess)" -ErrorAction SilentlyContinue
    if ($proc -and $proc.CommandLine -and $proc.CommandLine.Contains($rootPath)) {
      $result.Ours = $true
    } elseif ($proc) {
      $result.Other = "$($proc.Name) (PID $($c.OwningProcess))"
    } else {
      $result.Other = "PID $($c.OwningProcess)"
    }
  }
  return $result
}

# --- 1. Where we are working. ------------------------------------------------
#
#     $PWD, not $PSScriptRoot: the point of this file is that it can be carried
#     to a fresh machine and run in the folder somebody wants the app in. -Path
#     is the escape hatch for a scheduled task, which has no meaningful cwd.
$root = if ($Path) { $Path } else { (Get-Location).Path }
try {
  if (-not (Test-Path $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
  $root = (Resolve-Path $root).Path
} catch { Fail "Cannot use that folder: $root" }
Set-Location $root

Write-Host ""
Write-Host "  Christopher OS - install / update" -ForegroundColor Cyan
Write-Host "  $root"
Write-Host ""

# --- 2. Places nobody means to install into. ---------------------------------
#
#     Explorer starts a double-clicked .bat in its own folder, but a shortcut
#     with a blank "Start in", an elevated prompt, or a scheduled task can all
#     hand us System32. Cloning a few hundred files there is not something to
#     discover afterwards. Also refuses a drive root and the profile root, where
#     the mess is just as unwelcome and just as hard to undo.
$bad = @(
  $env:SystemRoot,
  (Join-Path $env:SystemRoot 'System32'),
  $env:ProgramFiles,
  ${env:ProgramFiles(x86)},
  $env:USERPROFILE,
  $env:TEMP
) | Where-Object { $_ }
foreach ($b in $bad) {
  if ($root.TrimEnd('\') -ieq $b.TrimEnd('\')) {
    Fail "Refusing to install into $root.`n  Make a folder for the app and run this from inside it."
  }
}
if ($root -match '^[A-Za-z]:\\?$') {
  Fail "Refusing to install into a drive root ($root).`n  Make a folder for the app and run this from inside it."
}

try { $null = & git --version } catch { Fail "git is not installed, or not on PATH.`n  Install Git for Windows, then run this again." }

# --- 3. Install or update? ---------------------------------------------------
#
#     An install is a folder that already holds this repo. Checked by REMOTE
#     rather than by "is there a .git", so pointing this at some unrelated
#     checkout refuses instead of resetting it to our main - which would be a
#     spectacular way to lose someone's work.
$isRepo = Test-Path (Join-Path $root '.git')
$remote = $null
if ($isRepo) { $remote = (& git remote get-url origin 2>$null) }

$mode = $null
if ($isRepo -and $remote -and $remote -match $REPO_NAME) {
  $mode = 'update'
} elseif ($isRepo) {
  Fail "This folder is already a git repository, but not this app's:`n    $(if ($remote) { $remote } else { '(no origin remote)' })`n  Run this in an empty folder instead."
} else {
  # A fresh install writes into this folder, so it has to be empty - bar the
  # two files we arrived as, and the junk Windows leaves lying about. Anything
  # else and we would be scattering a release over somebody's documents.
  $ours = @('update.ps1', 'Update.bat', 'desktop.ini', 'Thumbs.db', '.DS_Store')
  $strangers = Get-ChildItem -Force -Path $root |
    Where-Object { $ours -notcontains $_.Name }
  if ($strangers) {
    Write-Host "  This folder is not empty:" -ForegroundColor Yellow
    $strangers | Select-Object -First 8 | ForEach-Object { Write-Host "    $($_.Name)" }
    if ($strangers.Count -gt 8) { Write-Host "    ... and $($strangers.Count - 8) more" }
    Fail "Refusing to install on top of files that are not ours.`n  Run this in an empty folder."
  }
  $mode = 'install'
}

# --- 4. Never rewrite a LIVE install.
#
#     Files replaced under a running server are the worst kind of half-update:
#     node already holds the bundle it started with, but frontend/dist is read
#     from disk per request, so the browser gets a mix of two builds and nothing
#     on screen says so. The port is the honest signal, and it is what the
#     launcher itself preflights on. Only meaningful for an update - a fresh
#     install has no server of its own yet. ---
$port = 4740
$envFile = Join-Path $root '.env'
if (Test-Path $envFile) {
  foreach ($line in (Get-Content $envFile)) {
    if ($line -match '^\s*MDV2_PORT\s*=\s*(\d+)') { $port = [int]$Matches[1] }
  }
}
$owner = Get-PortOwner $port $root
if ($mode -eq 'update' -and $owner.Ours) {
  Fail "This copy of Christopher OS is running on port $port.`n  Close its window first, then run this again."
}
if ($owner.Other) {
  # NOT a refusal. Something else on the port is a runtime collision for
  # whenever this copy is next started - it is no reason to block rewriting
  # files that belong to a different folder entirely.
  Write-Host "  Note: port $port is already held by $($owner.Other)." -ForegroundColor Yellow
  Write-Host "  That is a different program - change MDV2_PORT in .env before starting" -ForegroundColor Yellow
  Write-Host "  this copy, or its server will fail to bind." -ForegroundColor Yellow
  Write-Host ""
}

# --- 5. Fetch. ---------------------------------------------------------------
if ($mode -eq 'install') {
  Write-Host "  Installing from $REPO"
  Write-Host ""
  # init + fetch + checkout, NOT `git clone`. Clone refuses a non-empty
  # directory, and this one is not empty - it holds the two files we arrived
  # as. This reaches the same place and leaves them alone.
  & git init --quiet
  if ($LASTEXITCODE -ne 0) { Fail "git init failed in $root" }
  & git remote add origin $REPO
  if ($LASTEXITCODE -ne 0) { Fail "Could not add the remote." }
} else {
  $before = (& git rev-parse --short HEAD)
  $relFile = Join-Path $root 'RELEASE.json'
  if (Test-Path $relFile) {
    $rel = Get-Content $relFile -Raw | ConvertFrom-Json
    Write-Host "  Installed : $before  (source $($rel.commit), built $($rel.builtAt))"
  } else {
    Write-Host "  Installed : $before"
  }

  # A dirty tree means somebody edited a sealed file. Name the files rather than
  # discarding them silently: the app would already be refusing to start with
  # "MODIFIED FILE", and this is where that gets explained.
  #
  # --untracked-files=no is load-bearing twice over. This very script is an
  # untracked file in the folder, so a plain --porcelain listed Update.bat and
  # update.ps1 under "will be overwritten" - which was false, reset --hard does
  # not touch untracked files - and, worse, kept $dirty permanently truthy, so
  # the "already up to date" branch below could never be reached and every run
  # did a pointless reset and re-verify.
  $dirty = & git status --porcelain --untracked-files=no
  if ($dirty) {
    Write-Host ""
    Write-Host "  These tracked files differ from the release and WILL be overwritten:" -ForegroundColor Yellow
    $dirty | ForEach-Object { Write-Host "    $_" }
    Write-Host ""
  }
}

Write-Host "  Fetching..."
& git fetch --quiet origin main
if ($LASTEXITCODE -ne 0) {
  # git has already printed the real reason immediately above; do not assert a
  # cause over the top of it. An early version of this blamed credentials for
  # what was actually a path-length failure, which sent the reader looking in
  # the wrong place entirely.
  Fail "git could not fetch the release - its reason is printed just above.`n  Common ones: no network; no access to this private repo ('gh auth status');`n  or the folder is nested too deep and git hit Windows' 260-character path`n  limit - install somewhere shorter, like C:\ChristopherOS."
}
$after = (& git rev-parse --short origin/main)

if ($mode -eq 'update') {
  if ($before -eq $after -and -not $dirty) {
    Write-Host ""
    Write-Host "  Already up to date ($before). Nothing to do." -ForegroundColor Green
    Write-Host ""
    exit 0
  }
  Write-Host "  Available : $after"
  Write-Host ""
  $log = & git log --oneline --no-decorate "HEAD..origin/main"
  if ($log) {
    Write-Host "  Releases to apply:"
    $log | ForEach-Object { Write-Host "    $_" }
    Write-Host ""
  }
}

if (-not $Yes) {
  $verb = if ($mode -eq 'install') { "Install here" } else { "Apply this update" }
  $answer = Read-Host "  $verb`? (y/N)"
  if ($answer -notmatch '^(y|yes)$') {
    Write-Host "  Cancelled - nothing was changed."
    Write-Host ""
    exit 0
  }
}

# --- 6. Apply.
#
#     .env is TRACKED (so a reset overwrites it) but deliberately EXCLUDED from
#     integrity.json, because changing the port is a supported thing to do and
#     re-sealing per deployment is not a workflow anyone would follow. That
#     exclusion is precisely why restoring it cannot break the signature - and
#     why it MUST be restored, or every update would quietly move this copy back
#     to whichever port the release shipped with. ---
$savedEnv = if ($mode -eq 'update' -and (Test-Path $envFile)) { Get-Content $envFile -Raw } else { $null }

Write-Host ""
Write-Host "  Applying..."
if ($mode -eq 'install') {
  & git checkout --quiet -B main origin/main
  if ($LASTEXITCODE -ne 0) {
    Fail "Could not check the release out into this folder.`n  If git named a file it would overwrite, that file is not ours - move it and`n  run this again."
  }
} else {
  & git reset --hard --quiet origin/main
  if ($LASTEXITCODE -ne 0) { Fail "git reset failed - this copy has NOT been updated." }
}

if ($null -ne $savedEnv) {
  $shipped = if (Test-Path $envFile) { Get-Content $envFile -Raw } else { '' }
  if ($shipped -ne $savedEnv) {
    Set-Content -Path $envFile -Value $savedEnv -NoNewline -Encoding UTF8
    Write-Host "  Kept your .env (port $port). The release shipped a different one -" -ForegroundColor Yellow
    Write-Host "  'git diff .env' shows what you are now missing, if anything." -ForegroundColor Yellow
  }
}

# --- 7. Verify with the app's OWN gate rather than a second implementation.
#
#     server/index.js checks integrity.json against a pinned Ed25519 key before
#     anything else, and --verify-only makes it do exactly that and exit. Its
#     codes: 3 manifest missing/malformed, 4 bad signature, 5 missing file,
#     6 modified file, 7 foreign signer.
#
#     TIMEOUT, AND NOT A PLAIN CALL. ship-launcher.ps1 makes this point in its
#     own preflight and it is the whole reason this is not one line: a build
#     OLDER than the gate does not know --verify-only, ignores the argument, and
#     STARTS THE WHOLE APP - express listening, node-pty ready. A blocking
#     `& node ...` would then never return, and would sit holding the port we
#     just checked was free. So: separate process, 90 seconds, killed with
#     taskkill /T because a real server has children that would otherwise be
#     orphaned still holding it.
#
#     Two log files, not one: PS 5.1 hard-errors with "RedirectStandardOutput
#     and RedirectStandardError are same" if both point at one path. They go to
#     TEMP rather than into the folder, which is meant to hold only what the
#     manifest lists. ---
Write-Host ""
$serverEntry = Join-Path $root 'server\index.js'
if (-not (Test-Path $serverEntry)) {
  Fail "server\index.js is missing after checkout - the release did not land properly."
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host "  Node is not on PATH, so the build could not be verified here." -ForegroundColor Yellow
  Write-Host "  Start.bat runs the same check on the next launch. Install Node to run it." -ForegroundColor Yellow
} else {
  Write-Host "  Verifying..."
  $vOut = Join-Path $env:TEMP 'cos-verify.out.log'
  $vErr = Join-Path $env:TEMP 'cos-verify.err.log'
  $pf = Start-Process node `
    -ArgumentList "`"$serverEntry`"", '--verify-only' `
    -NoNewWindow -PassThru -WorkingDirectory $root `
    -RedirectStandardOutput $vOut -RedirectStandardError $vErr
  # Touch .Handle while the child is alive: in PS 5.1 a -PassThru process
  # without -Wait has no cached handle, and .ExitCode reads back empty once it
  # dies - on the one path where that number is what you wanted.
  try { $null = $pf.Handle } catch { }
  $exited = $false
  try { $exited = $pf.WaitForExit(90000) } catch { $exited = $false }

  if (-not $exited) {
    cmd /c "taskkill /F /T /PID $($pf.Id) >nul 2>&1"
    Fail "This release did not answer --verify-only within 90s, so it has no boot`n  integrity gate and nothing here can tell a sealed copy from an edited one.`n  That is a BUILD problem - ask for a newer release."
  }
  $code = 'unknown'
  try { $code = $pf.ExitCode } catch { }
  if ($code -ne 0) {
    $msg = (Get-Content $vOut -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content $vErr -Raw -ErrorAction SilentlyContinue)
    Write-Host ""
    Write-Host "  $($msg.Trim())" -ForegroundColor Red
    Fail "The build FAILED its integrity check (exit $code). Do not run it.`n  Re-run this script, or ask for a fresh release." $code
  }
  Write-Host "  Integrity OK." -ForegroundColor Green
}

# --- 8. Done. ---
$relFile = Join-Path $root 'RELEASE.json'
Write-Host ""
if ($mode -eq 'install') {
  Write-Host "  Installed $after into this folder." -ForegroundColor Green
} else {
  Write-Host "  Updated  : $before -> $after" -ForegroundColor Green
}
if (Test-Path $relFile) {
  $rel = Get-Content $relFile -Raw | ConvertFrom-Json
  Write-Host "  Source   : $($rel.commit), built $($rel.builtAt)"
}

# Said only now, and only as a note: a port held by ANOTHER copy is a runtime
# collision, not a reason to refuse an install that has changed nothing yet.
if ($mode -eq 'install' -and (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
  Write-Host ""
  Write-Host "  Note: something else is already listening on port $port. Change MDV2_PORT" -ForegroundColor Yellow
  Write-Host "  in .env before starting this copy, or the server will fail to bind." -ForegroundColor Yellow
}

Write-Host "  Start it with Start.bat."
Write-Host ""
exit 0
