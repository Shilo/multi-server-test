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
    switch ($name) {
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
$clients = @()
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

    for ($i = 1; $i -le $ClientCount; $i++) {
        $clientName = if ($ClientCount -eq 1) { "client" } else { "client$i" }
        $clients += @{
            Name = $clientName
            Process = Start-Role $clientName @("--role", "client", "--smoke-test")
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

    $expectedChatMessages = 5 * $ClientCount
    $chatMessages = (Select-String -Path (Join-Path $LogRoot "chat.out.log") -SimpleMatch "[CHAT] received from peer").Count
    if ($chatMessages -lt $expectedChatMessages) {
        Write-Host (Get-Content (Join-Path $LogRoot "chat.out.log") -Raw)
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
