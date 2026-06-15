param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [int]$TimeoutSeconds = 40,
    [switch]$UseExported
)

# End-to-end test for the database MVP: name-only login, world + position
# persistence, and resume. Runs two client phases against a master that is
# restarted in between, so phase 2 reads phase 1's data back off disk.

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$LogRoot = Join-Path $ProjectRoot ".logs\dbtest"
$BuildRoot = Join-Path $ProjectRoot "builds"
$WorldPackPort = 19100

Remove-Item -Recurse -Force -Path $LogRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

# Unique name so reruns never collide with an existing account.
$UserName = "PersistBot_{0}" -f ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())

function Get-Executable($name) {
    if (-not $UseExported) {
        return $Godot
    }
    if ($name -like "client*") {
        return Join-Path $BuildRoot "client\client.exe"
    }
    return Join-Path $BuildRoot "server\server.exe"
}

function Start-Scene($name, $scenePath, $userArgs = @()) {
    $out = Join-Path $LogRoot "$name.out.log"
    $err = Join-Path $LogRoot "$name.err.log"
    $exe = Get-Executable $name
    $args = @("--headless")
    if (-not $UseExported) {
        $args += @("--path", $ProjectRoot, "--scene", $scenePath)
    }
    if ($userArgs.Count -gt 0) {
        $args += "--"
        $args += $userArgs
    }
    Write-Host "DBTEST_LAUNCH $name"
    return Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
}

function Wait-LogMarker($name, $marker, $timeoutSeconds = 10) {
    $out = Join-Path $LogRoot "$name.out.log"
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $out) -and (Select-String -Path $out -SimpleMatch $marker -Quiet)) {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path $out) { Write-Host (Get-Content $out -Raw) }
    $err = Join-Path $LogRoot "$name.err.log"
    if (Test-Path $err) { Write-Host (Get-Content $err -Raw) }
    throw "Timed out waiting for '$marker' in $name"
}

function Stop-Tree($process) {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit(5000) | Out-Null
    }
}

function Start-WorldPackServer {
    $worldPackRoot = Join-Path $BuildRoot "world_packs"
    if (-not (Test-Path -LiteralPath $worldPackRoot)) {
        throw "Missing exported world packs: $worldPackRoot. Run tools\export_all.ps1 first."
    }

    $out = Join-Path $LogRoot "world_pack_http.out.log"
    $err = Join-Path $LogRoot "world_pack_http.err.log"
    Write-Host "DBTEST_LAUNCH world_pack_http"
    $process = Start-Process `
        -FilePath "python" `
        -ArgumentList @("-m", "http.server", "$WorldPackPort", "--bind", "127.0.0.1", "--directory", $BuildRoot) `
        -RedirectStandardOutput $out `
        -RedirectStandardError $err `
        -WindowStyle Hidden `
        -PassThru
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) {
        if (Test-Path $out) { Write-Host (Get-Content $out -Raw) }
        if (Test-Path $err) { Write-Host (Get-Content $err -Raw) }
        throw "World pack HTTP server exited early"
    }
    return $process
}

$procs = @()
try {
    if ($UseExported) {
        $env:MULTI_SERVER_WORLD_PACK_DIR = Join-Path $BuildRoot "world_packs"
        $env:MULTI_SERVER_WORLD_PACK_BASE_URL = "http://127.0.0.1:$WorldPackPort/world_packs"
        $procs += Start-WorldPackServer
    }

    # --- Phase 1: create account, travel, park, persist ---
    $master1 = Start-Scene "master1" "res://server/master/master.tscn"
    $procs += $master1
    Wait-LogMarker "master1" "MASTER_READY"

    $client1 = Start-Scene "client1" "res://client/client.tscn" @("db_persist_test", "phase1", $UserName)
    $procs += $client1
    $client1.WaitForExit($TimeoutSeconds * 1000) | Out-Null
    if (-not $client1.HasExited) { Stop-Tree $client1; throw "phase1 client timed out" }

    $client1Log = Get-Content (Join-Path $LogRoot "client1.out.log") -Raw
    if (-not $client1Log.Contains("DBTEST_PHASE1_DONE")) {
        Write-Host $client1Log
        throw "phase1 did not complete"
    }
    Write-Host "DBTEST_PHASE1_OK name=$UserName"

    # Restart the master to prove the data is on disk, not just in RAM.
    Stop-Tree $master1

    # --- Phase 2: log in again, assert resume into saved world + position ---
    $master2 = Start-Scene "master2" "res://server/master/master.tscn"
    $procs += $master2
    Wait-LogMarker "master2" "MASTER_READY"

    $client2 = Start-Scene "client2" "res://client/client.tscn" @("db_persist_test", "phase2", $UserName)
    $procs += $client2
    $client2.WaitForExit($TimeoutSeconds * 1000) | Out-Null
    if (-not $client2.HasExited) { Stop-Tree $client2; throw "phase2 client timed out" }

    $client2Log = Get-Content (Join-Path $LogRoot "client2.out.log") -Raw
    if (-not $client2Log.Contains("DBTEST_PASS")) {
        Write-Host $client2Log
        throw "phase2 did not pass"
    }

    Write-Host "DBTEST_PASS name=$UserName logs=$LogRoot"
}
finally {
    foreach ($p in $procs) { Stop-Tree $p }
}
