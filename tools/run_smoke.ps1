param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [switch]$UseExported,
    [int]$TimeoutSeconds = 30,
    [int]$ClientCount = 1
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
    if ($name -like "client*") {
        return Join-Path $BuildRoot "client\client.exe"
    }
    if ($name -eq "master") {
        return Join-Path $BuildRoot "master_server\master_server.exe"
    }
    return Join-Path $BuildRoot "world_server\world_server.exe"
}

function Start-Scene($name, $scenePath, $userArgs = @(), [switch]$Headless) {
    $out = Join-Path $LogRoot "$name.out.log"
    $err = Join-Path $LogRoot "$name.err.log"
    $exe = Get-Executable $name
    if ($UseExported) {
        $args = @()
        if ($Headless) {
            $args += "--headless"
        }
    }
    else {
        $args = @()
        if ($Headless) {
            $args += "--headless"
        }
        $args += @("--path", $ProjectRoot, "--scene", $scenePath)
    }
    if ($userArgs.Count -gt 0) {
        $args += "--"
        $args += $userArgs
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
$clients = @()
try {
    $servers += Start-Scene "master" "res://master_server/master_server.tscn" @() -Headless
    Wait-LogMarker "master" "MASTER_READY"
    Wait-LogMarker "master" "CHAT_READY"

    $servers += Start-Scene "hub" "res://world_server/world_server.tscn" @("hub") -Headless
    Wait-LogMarker "hub" "WORLD_READY key=hub"
    Wait-LogMarker "master" "MASTER_WORLD_REGISTERED key=hub"

    $servers += Start-Scene "left_world" "res://world_server/world_server.tscn" @("left_world") -Headless
    Wait-LogMarker "left_world" "WORLD_READY key=left_world"
    Wait-LogMarker "master" "MASTER_WORLD_REGISTERED key=left_world"

    $servers += Start-Scene "right_world" "res://world_server/world_server.tscn" @("right_world") -Headless
    Wait-LogMarker "right_world" "WORLD_READY key=right_world"
    Wait-LogMarker "master" "MASTER_WORLD_REGISTERED key=right_world"

    for ($i = 1; $i -le $ClientCount; $i++) {
        $clientName = if ($ClientCount -eq 1) { "client" } else { "client$i" }
        $clients += @{
            Name = $clientName
            Process = Start-Scene $clientName "res://client/client.tscn" @("smoke_test") -Headless
        }
    }

    foreach ($clientEntry in $clients) {
        $clientName = $clientEntry.Name
        $clientProcess = $clientEntry.Process
        $clientProcess.WaitForExit($TimeoutSeconds * 1000) | Out-Null
        if (-not $clientProcess.HasExited) {
            Stop-Process -Id $clientProcess.Id -Force
            throw "Smoke client $clientName timed out after $TimeoutSeconds seconds"
        }

        $clientLogPath = Join-Path $LogRoot "$clientName.out.log"
        $clientLog = Get-Content $clientLogPath -Raw
        if (-not $clientLog.Contains("SMOKE_PASS")) {
            Write-Host $clientLog
            $clientErrPath = Join-Path $LogRoot "$clientName.err.log"
            if (Test-Path $clientErrPath) {
                Write-Host (Get-Content $clientErrPath -Raw)
            }
            throw "Smoke test did not produce SMOKE_PASS for $clientName"
        }
    }

    $requiredMarkers = @(
        "MASTER_READY",
        "CHAT_READY",
        "WORLD_READY key=hub",
        "WORLD_READY key=left_world",
        "WORLD_READY key=right_world",
        "MASTER_WORLD_REGISTERED key=hub",
        "MASTER_WORLD_REGISTERED key=left_world",
        "MASTER_WORLD_REGISTERED key=right_world"
    )
    foreach ($marker in $requiredMarkers) {
        $found = Get-ChildItem $LogRoot -Filter "*.out.log" | Select-String -SimpleMatch $marker -Quiet
        if (-not $found) {
            throw "Missing smoke marker: $marker"
        }
    }

    $expectedChatMessages = 5 * $ClientCount
    $chatMessages = (Select-String -Path (Join-Path $LogRoot "master.out.log") -SimpleMatch "[CHAT] received from peer").Count
    if ($chatMessages -lt $expectedChatMessages) {
        Write-Host (Get-Content (Join-Path $LogRoot "master.out.log") -Raw)
        throw "Expected at least $expectedChatMessages chat messages, found $chatMessages"
    }

    Write-Host "SMOKE_PASS clients=$ClientCount chat_messages=$chatMessages logs=$LogRoot"
}
finally {
    foreach ($clientEntry in $clients) {
        $clientProcess = $clientEntry.Process
        if ($clientProcess -and -not $clientProcess.HasExited) {
            Stop-Process -Id $clientProcess.Id -Force
        }
    }
    foreach ($server in $servers) {
        if ($server -and -not $server.HasExited) {
            Stop-Process -Id $server.Id -Force
        }
    }
}
