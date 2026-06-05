param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [switch]$UseExported,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$LogRoot = Join-Path $ProjectRoot ".logs\smoke"
$BuildRoot = Join-Path $ProjectRoot "builds"

Remove-Item -Recurse -Force -Path $LogRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Get-Executable($name) {
    if (-not $UseExported) {
        return $Godot
    }
    switch ($name) {
        "client" { return Join-Path $BuildRoot "client\client.exe" }
        "master" { return Join-Path $BuildRoot "master\master.exe" }
        "chat" { return Join-Path $BuildRoot "chat\chat.exe" }
        "world1" { return Join-Path $BuildRoot "world1\world1.exe" }
        "world2" { return Join-Path $BuildRoot "world2\world2.exe" }
        "world3" { return Join-Path $BuildRoot "world3\world3.exe" }
    }
}

function Start-Role($name, $roleArgs) {
    $out = Join-Path $LogRoot "$name.out.log"
    $err = Join-Path $LogRoot "$name.err.log"
    $exe = Get-Executable $name
    if ($UseExported) {
        $args = @("--headless", "--") + $roleArgs
    }
    else {
        $args = @("--headless", "--path", $ProjectRoot, "--") + $roleArgs
    }
    Write-Host "SMOKE_LAUNCH $name"
    return Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
}

function Wait-LogMarker($name, $marker, $timeoutSeconds = 10) {
    $out = Join-Path $LogRoot "$name.out.log"
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $out) -and (Select-String -Path $out -SimpleMatch $marker -Quiet)) {
            Write-Host "SMOKE_READY $name $marker"
            return
        }
        Start-Sleep -Milliseconds 100
    }

    if (Test-Path $out) {
        Write-Host (Get-Content $out -Raw)
    }
    $err = Join-Path $LogRoot "$name.err.log"
    if (Test-Path $err) {
        Write-Host (Get-Content $err -Raw)
    }
    throw "Timed out waiting for marker '$marker' in $name logs"
}

$servers = @()
try {
    $servers += Start-Role "master" @("--role", "master")
    Wait-LogMarker "master" "MASTER_READY"

    $servers += Start-Role "chat" @("--role", "chat")
    Wait-LogMarker "chat" "CHAT_READY"

    $servers += Start-Role "world1" @("--role", "world", "--world", "1")
    Wait-LogMarker "world1" "WORLD_READY id=1"
    Wait-LogMarker "master" "MASTER_WORLD_REGISTERED id=1"

    $servers += Start-Role "world2" @("--role", "world", "--world", "2")
    Wait-LogMarker "world2" "WORLD_READY id=2"
    Wait-LogMarker "master" "MASTER_WORLD_REGISTERED id=2"

    $servers += Start-Role "world3" @("--role", "world", "--world", "3")
    Wait-LogMarker "world3" "WORLD_READY id=3"
    Wait-LogMarker "master" "MASTER_WORLD_REGISTERED id=3"

    $client = Start-Role "client" @("--role", "client", "--smoke-test")
    $client.WaitForExit($TimeoutSeconds * 1000) | Out-Null
    if (-not $client.HasExited) {
        Stop-Process -Id $client.Id -Force
        throw "Smoke client timed out after $TimeoutSeconds seconds"
    }

    $clientLog = Get-Content (Join-Path $LogRoot "client.out.log") -Raw
    if (-not $clientLog.Contains("SMOKE_PASS")) {
        Write-Host $clientLog
        $clientErrPath = Join-Path $LogRoot "client.err.log"
        if (Test-Path $clientErrPath) {
            Write-Host (Get-Content $clientErrPath -Raw)
        }
        throw "Smoke test did not produce SMOKE_PASS"
    }

    $requiredMarkers = @(
        "MASTER_READY",
        "CHAT_READY",
        "WORLD_READY id=1",
        "WORLD_READY id=2",
        "WORLD_READY id=3",
        "MASTER_WORLD_REGISTERED id=1",
        "MASTER_WORLD_REGISTERED id=2",
        "MASTER_WORLD_REGISTERED id=3"
    )
    foreach ($marker in $requiredMarkers) {
        $found = Get-ChildItem $LogRoot -Filter "*.out.log" | Select-String -SimpleMatch $marker -Quiet
        if (-not $found) {
            throw "Missing smoke marker: $marker"
        }
    }

    Write-Host "SMOKE_PASS logs=$LogRoot"
}
finally {
    foreach ($server in $servers) {
        if ($server -and -not $server.HasExited) {
            Stop-Process -Id $server.Id -Force
        }
    }
}
