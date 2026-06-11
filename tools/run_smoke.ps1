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
    return Join-Path $BuildRoot "server\server.exe"
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

function Wait-WorldProcessId($masterName, $worldKey, $timeoutSeconds = 10) {
    $out = Join-Path $LogRoot "$masterName.out.log"
    $escapedKey = [regex]::Escape($worldKey)
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $out) {
            $worldPid = $null
            foreach ($line in Get-Content $out) {
                if ($line -match "MASTER_WORLD_STARTED key=$escapedKey pid=(\d+)") {
                    $worldPid = [int]$Matches[1]
                }
            }
            if ($worldPid) {
                Write-Host "SMOKE_WORLD_PID $worldKey $worldPid"
                return $worldPid
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for launched world pid for '$worldKey'"
}

function Wait-ProcessGone($processId, $label, $timeoutSeconds = 10) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if (-not $process) {
            Write-Host "SMOKE_PROCESS_GONE $label pid=$processId"
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for process to exit: $label pid=$processId"
}

function Get-WorldKeys {
    $worldRoot = Join-Path $ProjectRoot "server\worlds"
    $keys = @()
    foreach ($directory in Get-ChildItem -Path $worldRoot -Directory | Sort-Object Name) {
        $scenePath = Join-Path $directory.FullName "$($directory.Name).tscn"
        if (Test-Path $scenePath) {
            $keys += $directory.Name
        }
        else {
            throw "World folder '$($directory.Name)' must contain $($directory.Name).tscn"
        }
    }
    return $keys
}

$worldKeys = Get-WorldKeys
if (-not ($worldKeys -contains "hub")) {
    throw "Smoke test requires discovered hub world"
}

$servers = @()
$clients = @()
$expectedChatMessages = 0
try {
    $servers += Start-Scene "master" "res://server/master/master.tscn" @() -Headless
    Wait-LogMarker "master" "MASTER_READY"

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

        $transferCount = (Select-String -Path $clientLogPath -SimpleMatch "SMOKE_STEP transfer ").Count
        $expectedChatMessages += 1 + $transferCount
    }

    $requiredMarkers = @("MASTER_READY")
    foreach ($worldKey in $worldKeys) {
        $requiredMarkers += "MASTER_WORLD_STARTED key=$worldKey"
        $requiredMarkers += "MASTER_WORLD_REGISTERED key=$worldKey"
        $requiredMarkers += "MASTER_WORLD_RUNNING key=$worldKey"
    }
    foreach ($marker in $requiredMarkers) {
        $found = Get-ChildItem $LogRoot -Filter "*.out.log" | Select-String -SimpleMatch $marker -Quiet
        if (-not $found) {
            throw "Missing smoke marker: $marker"
        }
    }

    $chatMessages = (Select-String -Path (Join-Path $LogRoot "master.out.log") -SimpleMatch "[CHAT] received from peer").Count
    if ($chatMessages -lt $expectedChatMessages) {
        Write-Host (Get-Content (Join-Path $LogRoot "master.out.log") -Raw)
        throw "Expected at least $expectedChatMessages chat messages, found $chatMessages"
    }

    foreach ($worldKey in $worldKeys) {
        Wait-LogMarker "master" "MASTER_WORLD_STOP_REQUESTED key=$worldKey reason=idle" 15
        Wait-LogMarker "master" "MASTER_WORLD_STOPPED key=$worldKey" 15
    }

    $masterProcess = $servers[0]
    if ($masterProcess -and -not $masterProcess.HasExited) {
        Stop-Process -Id $masterProcess.Id -Force
        $masterProcess.WaitForExit(5000) | Out-Null
    }

    $cleanupMaster = Start-Scene "master_cleanup" "res://server/master/master.tscn" @() -Headless
    $servers += $cleanupMaster
    Wait-LogMarker "master_cleanup" "MASTER_READY"
    $cleanupClient = Start-Scene "client_cleanup" "res://client/client.tscn" @("smoke_test") -Headless
    $clients += @{
        Name = "client_cleanup"
        Process = $cleanupClient
    }
    Wait-LogMarker "master_cleanup" "MASTER_WORLD_REGISTERED key=hub" 10
    $cleanupWorldPid = Wait-WorldProcessId "master_cleanup" "hub" 10
    Stop-Process -Id $cleanupMaster.Id -Force
    $cleanupMaster.WaitForExit(5000) | Out-Null
    if (-not $cleanupClient.HasExited) {
        Stop-Process -Id $cleanupClient.Id -Force
        $cleanupClient.WaitForExit(5000) | Out-Null
    }
    Wait-ProcessGone $cleanupWorldPid "hub_after_master_kill" 10

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
