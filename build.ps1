# build.ps1 - Test, export and package Bridge to Friendship (Windows).
#
#   .\build.ps1              # full gate, then export
#   .\build.ps1 -Force       # package even if a test failed (never for a release)
#   .\build.ps1 -SkipTests   # export only -- the build is UNVERIFIED
param (
    [switch]$Force,
    [switch]$SkipTests
)

$GameName = "BridgeToFriendship"
$ExportPreset = "Windows Desktop"

function Normalize-ProcessPath {
    if ($env:PATH) {
        $env:Path = $env:PATH
        [Environment]::SetEnvironmentVariable("PATH", $null, "Process")
    }
}

Normalize-ProcessPath

# The exported game, if still running, holds its own binary open.
Write-Host "Stopping any running instances of the game..." -ForegroundColor Yellow
Stop-Process -Name $GameName -ErrorAction SilentlyContinue

$godotPath = "$PSScriptRoot\Godot_v4.4.1-stable_win64.exe"
$buildDir = "$PSScriptRoot\build"
$windowsBuildDir = "$buildDir\windows"
$exportPath = "$windowsBuildDir\$GameName.exe"
$buildVersion = Get-Date -Format "yyyy-MM-dd.HHmmss"

Write-Host "Build Version: $buildVersion" -ForegroundColor Cyan

if (-not (Test-Path $godotPath)) {
    Write-Error "Godot executable not found at $godotPath."
    exit 1
}

# Reimport up front, once, before the parallel test runners below -- each of
# those self-checks too (test_runner.ps1), but by then this pass will have left
# nothing stale, so they are a cheap no-op scan rather than N processes racing
# to reimport into .godot/imported/.
. "$PSScriptRoot\import_check.ps1"
Import-IfStale -ProjectRoot $PSScriptRoot -GodotPath $godotPath

# --- Syntax validation: deliberately NOT a step -------------------------------
# `--headless --check-only` reports FALSE parse errors on autoload identifiers
# (DebugSettings, NetworkManager, SteamManager -- which this codebase uses
# everywhere), so a syntax gate built on it fails on correct code. A gate that
# cries wolf is worse than no gate. Scripts are validated by the tests that load
# them; test_smoke is the one that fails first and cheapest when a script does
# not compile.

# --- Test gate ----------------------------------------------------------------
$testsPassed = $true

if ($SkipTests) {
    Write-Host "SKIPPING the test gate (-SkipTests). This build is UNVERIFIED." -ForegroundColor Yellow
} else {
    Write-Host "Running automated test suite (parallel)..." -ForegroundColor Cyan
    $allTestFiles = Get-ChildItem -Path "$PSScriptRoot\scripts\tests\*.gd"

    # PERF TESTS RUN ALONE, AFTER EVERYTHING ELSE.
    #
    # Anything that measures wall time per physics step measures, inside a
    # parallel batch, however much CPU it happened to get -- i.e. the SCHEDULER
    # rather than the game. That fails gates on hundredths of a millisecond
    # while the code is fine, which trains everyone to ignore the one real
    # regression the budget exists to catch. Add the name of any timing test
    # here and it will be run serially with the box otherwise idle.
    $perfTestNames = @()
    $testFiles = $allTestFiles | Where-Object { $perfTestNames -notcontains $_.BaseName }
    $perfTestFiles = $allTestFiles | Where-Object { $perfTestNames -contains $_.BaseName }

    # Cap concurrency. Uncapped, a full gate launches one PowerShell host AND
    # one headless Godot per test file simultaneously; past ~100 tests that is
    # heavy CPU oversubscription and tens of GB of RAM in a single burst.
    # Correctness is unaffected either way (every test runs under --fixed-fps
    # 60, so frame counts are identical regardless of contention) -- what
    # contention changes is wall clock. Leave headroom for the OS and the editor
    # rather than saturating every core.
    $maxParallel = [Math]::Max(2, [Math]::Min(12, [Environment]::ProcessorCount - 8))
    Write-Host "Test concurrency capped at $maxParallel (of $([Environment]::ProcessorCount) logical CPUs)" -ForegroundColor DarkCyan

    $logDir = "$PSScriptRoot\test_logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

    function Start-TestRunner {
        param([string]$Name)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\test_runner.ps1`" -TestName $Name"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # Start-Process -PassThru does not reliably expose ExitCode once output
        # is redirected -- use raw .NET Process objects, which do.
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        return [PSCustomObject]@{
            Name = $Name
            Process = $proc
            StdOutTask = $proc.StandardOutput.ReadToEndAsync()
            StdErrTask = $proc.StandardError.ReadToEndAsync()
        }
    }

    $runners = @()
    foreach ($file in $testFiles) {
        # Hold here until a slot frees. Polling rather than WaitHandle juggling:
        # these are multi-second processes, so a 200ms tick costs nothing and
        # keeps the loop readable.
        while (@($runners | Where-Object { -not $_.Process.HasExited }).Count -ge $maxParallel) {
            Start-Sleep -Milliseconds 200
        }
        Write-Host "Launching $($file.BaseName)..."
        # += rather than collecting the loop's output, because the throttle
        # above has to inspect $runners WHILE the loop is still running.
        $runners += Start-TestRunner -Name $file.BaseName
    }

    foreach ($r in $runners) {
        $r.Process.WaitForExit()
        Set-Content -Path "$logDir\$($r.Name).runner.log" -Value $r.StdOutTask.Result
        Set-Content -Path "$logDir\$($r.Name).runner.err.log" -Value $r.StdErrTask.Result
        if ($r.Process.ExitCode -eq 0) {
            Write-Host ("  PASS  " + $r.Name) -ForegroundColor Green
        } else {
            Write-Host ("  FAIL  " + $r.Name) -ForegroundColor Red
            Write-Host $r.StdOutTask.Result
            if ($r.StdErrTask.Result.Trim().Length -gt 0) { Write-Host $r.StdErrTask.Result }
            $testsPassed = $false
        }
    }

    # Perf tests, serialised, with the box otherwise idle. Everything above has
    # exited by now (the wait loop is a barrier), so these measure the game
    # rather than the scheduler.
    if ($perfTestFiles.Count -gt 0) {
        Write-Host "`nRunning perf tests serially (contention would make these meaningless)..." -ForegroundColor Cyan
        foreach ($file in $perfTestFiles) {
            $r = Start-TestRunner -Name $file.BaseName
            $r.Process.WaitForExit()
            Set-Content -Path "$logDir\$($r.Name).runner.log" -Value $r.StdOutTask.Result
            Set-Content -Path "$logDir\$($r.Name).runner.err.log" -Value $r.StdErrTask.Result
            Write-Host "`n========== $($r.Name) (serial) ==========" -ForegroundColor Cyan
            Write-Host $r.StdOutTask.Result
            if ($r.Process.ExitCode -ne 0) { $testsPassed = $false }
        }
    }

    if (-not $testsPassed) {
        if ($Force) {
            Write-Host "WARNING: one or more tests failed, but -Force was specified. Proceeding..." -ForegroundColor Yellow
        } else {
            Write-Host "BUILD ABORTED: one or more tests failed." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "All tests passed successfully." -ForegroundColor Green
    }
}

# --- Export templates ---------------------------------------------------------
$templateDir = "$env:APPDATA\Godot\export_templates\4.4.1.stable"
if (-not (Test-Path "$templateDir\windows_release_x86_64.exe")) {
    Write-Host "Export templates for 4.4.1.stable not found. Downloading (~1.2 GB)..." -ForegroundColor Cyan

    # DOWNLOAD AS .zip, NOT .tpz. A .tpz IS an ordinary zip archive -- but
    # Expand-Archive validates the FILE EXTENSION rather than the contents and
    # accepts only ".zip", so handing it the upstream ".tpz" name fails with
    # ".tpz is not a supported archive file format".
    $tpzPath = "$PSScriptRoot\export_templates.zip"
    $tempExtract = "$PSScriptRoot\temp_templates"

    # PS 5.1 (the Windows default) does not negotiate TLS 1.2 on every box, and
    # GitHub requires it -- force it or the download can fail outright.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # -ErrorAction Stop on every step: these cmdlets raise NON-terminating
    # errors by default, so without it a failure prints red and the script
    # carries on regardless, straight past "installed successfully" and into an
    # export that never had a chance. It is also what makes the catch fire.
    try {
        # Invoke-WebRequest's progress bar makes a 1.2 GB download roughly an
        # order of magnitude slower in PS 5.1. Suppress it for the transfer.
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri "https://github.com/godotengine/godot/releases/download/4.4.1-stable/Godot_v4.4.1-stable_export_templates.tpz" -OutFile $tpzPath -ErrorAction Stop
        $ProgressPreference = $oldProgress

        Write-Host "Extracting templates..." -ForegroundColor Cyan
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
        Expand-Archive -Path $tpzPath -DestinationPath $tempExtract -Force -ErrorAction Stop

        New-Item -ItemType Directory -Force -Path $templateDir | Out-Null
        Copy-Item -Path "$tempExtract\templates\*" -Destination $templateDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "BUILD ABORTED: could not install export templates. $_" -ForegroundColor Red
        Write-Host "Install them manually via the Godot editor (Editor > Manage Export Templates)." -ForegroundColor Yellow
        exit 1
    } finally {
        if (Test-Path $tpzPath) { Remove-Item $tpzPath -Force }
        if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    }

    # Verify rather than assume.
    if (-not (Test-Path "$templateDir\windows_release_x86_64.exe")) {
        Write-Host "BUILD ABORTED: export templates did not install to $templateDir." -ForegroundColor Red
        exit 1
    }
    Write-Host "Export templates installed successfully." -ForegroundColor Green
}

# --- Export -------------------------------------------------------------------
Write-Host "Preparing build directory: $buildDir" -ForegroundColor Cyan
if (Test-Path $buildDir) { Remove-Item -Path $buildDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $windowsBuildDir | Out-Null

Set-Content -Path "$PSScriptRoot\version.txt" -Value $buildVersion
Write-Host "Exporting '$ExportPreset' to $exportPath..." -ForegroundColor Cyan
$godotArgs = "--path `"$PSScriptRoot`" --headless --export-release `"$ExportPreset`" `"$exportPath`""
$process = Start-Process -FilePath $godotPath -ArgumentList $godotArgs -Wait -PassThru -NoNewWindow

# Steam needs its appid file next to the binary, or a build launched outside the
# Steam client reports "app not running" and never initialises.
if (Test-Path "$PSScriptRoot\steam_appid.txt") {
    Copy-Item "$PSScriptRoot\steam_appid.txt" -Destination $windowsBuildDir
}

# Godot exits 0 even when an export "completed with warnings", so the exit code
# alone is not proof -- the artifact check is what decides.
if ($process.ExitCode -ne 0 -or -not (Test-Path $exportPath)) {
    Write-Host "BUILD FAILED!" -ForegroundColor Red
    exit 1
}
Write-Host "Export successful!" -ForegroundColor Green

# --- Package ------------------------------------------------------------------
$zipPath = "$buildDir\${GameName}_Windows_v$buildVersion.zip"
Write-Host "Packaging build into $zipPath..." -ForegroundColor Cyan
Set-Content -Path "$windowsBuildDir\version.txt" -Value $buildVersion
Compress-Archive -Path "$windowsBuildDir\*" -DestinationPath $zipPath -Force

$exeSize = [math]::Round((Get-Item $exportPath).Length / 1MB, 1)
$zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)

Write-Host "Build Complete!" -ForegroundColor Green
Write-Host "Executable: $exportPath ($exeSize MB)"
Write-Host "ZIP: $zipPath ($zipSize MB)"

if (-not $testsPassed -or $SkipTests) {
    Write-Host "`nWARNING: this build did NOT pass a clean test gate!" -ForegroundColor Yellow
}
