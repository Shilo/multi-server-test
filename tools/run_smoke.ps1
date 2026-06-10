param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [switch]$UseExported,
    [switch]$InitialOnly,
    [switch]$ClearWorldPackCache,
    [ValidateSet("Any", "Download", "CacheHit")]
    [string]$WorldPackExpectation = "Any",
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

function Start-PackServer {
    $hubPack = Join-Path $BuildRoot "world_packs\hub.pck"
    if (-not (Test-Path $hubPack)) {
        throw "Missing $hubPack. Run tools\export_world_pack.ps1 before exported smoke."
    }

    $out = Join-Path $LogRoot "pack_server.out.log"
    $err = Join-Path $LogRoot "pack_server.err.log"
    $python = Get-Command python -ErrorAction SilentlyContinue
    $pythonArgs = @("-m", "http.server", "19100", "--bind", "127.0.0.1", "--directory", $BuildRoot)
    if (-not $python) {
        $python = Get-Command py -ErrorAction SilentlyContinue
        $pythonArgs = @("-3", "-m", "http.server", "19100", "--bind", "127.0.0.1", "--directory", $BuildRoot)
    }
    if (-not $python) {
        throw "Python is required to serve exported world packs during smoke."
    }

    Write-Host "SMOKE_LAUNCH pack_server"
    $process = Start-Process -FilePath $python.Source -ArgumentList $pythonArgs -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:19100/world_packs/hub.pck" -Method Head -TimeoutSec 1 | Out-Null
            Write-Host "SMOKE_READY pack_server"
            return $process
        }
        catch {
            if ($process.HasExited) {
                if (Test-Path $err) {
                    Write-Host (Get-Content $err -Raw)
                }
                throw "Pack server exited before becoming ready"
            }
            Start-Sleep -Milliseconds 100
        }
    }
    throw "Timed out waiting for pack server"
}

function Get-WorldPackCachePath {
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        return $null
    }
    return Join-Path $env:APPDATA "Godot\app_userdata\multi-server-test\world_packs"
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

$worldKeys = if ($InitialOnly) { @("hub") } else { Get-WorldKeys }
if (-not ($worldKeys -contains "hub")) {
    throw "Smoke test requires discovered hub world"
}

$servers = @()
$clients = @()
$packServer = $null
$expectedChatMessages = 0
try {
    if ($ClearWorldPackCache) {
        $cachePath = Get-WorldPackCachePath
        if ([string]::IsNullOrWhiteSpace($cachePath)) {
            throw "Cannot locate Godot app userdata path because APPDATA is not set."
        }
        Remove-Item -Recurse -Force -LiteralPath $cachePath -ErrorAction SilentlyContinue
        Write-Host "SMOKE_WORLD_PACK_CACHE_CLEARED path=$cachePath"
    }

    if ($UseExported) {
        $packServer = Start-PackServer
    }

    $servers += Start-Scene "master" "res://server/master/master.tscn" @() -Headless
    Wait-LogMarker "master" "MASTER_READY"

    for ($i = 1; $i -le $ClientCount; $i++) {
        $clientName = if ($ClientCount -eq 1) { "client" } else { "client$i" }
        $clientArgs = if ($InitialOnly) { @("initial_world_smoke") } else { @("smoke_test") }
        $clients += @{
            Name = $clientName
            Process = Start-Scene $clientName "res://client/client.tscn" $clientArgs -Headless
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

        if ($UseExported -and $InitialOnly -and $WorldPackExpectation -ne "Any") {
            $downloaded = $clientLog.Contains("[WORLD_PACK] downloading")
            $cacheHit = $clientLog.Contains("[WORLD_PACK] cache hit")
            if ($WorldPackExpectation -eq "Download" -and -not $downloaded) {
                throw "Expected exported smoke to download a world pack, but no download marker was found in $clientName"
            }
            if ($WorldPackExpectation -eq "CacheHit" -and -not $cacheHit) {
                throw "Expected exported smoke to hit the world pack cache, but no cache-hit marker was found in $clientName"
            }
        }

        if (-not $InitialOnly) {
            $transferCount = (Select-String -Path $clientLogPath -SimpleMatch "SMOKE_STEP transfer ").Count
            $expectedChatMessages += 1 + $transferCount
        }
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
    $cleanupClientArgs = if ($InitialOnly) { @("initial_world_smoke") } else { @("smoke_test") }
    $cleanupClient = Start-Scene "client_cleanup" "res://client/client.tscn" $cleanupClientArgs -Headless
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
    if ($packServer -and -not $packServer.HasExited) {
        Stop-Process -Id $packServer.Id -Force
    }
}
