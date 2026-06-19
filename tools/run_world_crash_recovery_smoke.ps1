param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$LogRoot = Join-Path $ProjectRoot ".logs\world_crash_recovery"

Remove-Item -Recurse -Force -Path $LogRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Start-Scene($name, $scenePath, $userArgs = @(), [switch]$Headless) {
    $args = @()
    if ($Headless) {
        $args += "--headless"
    }
    $args += @("--path", $ProjectRoot, "--scene", $scenePath)
    if ($userArgs.Count -gt 0) {
        $args += "--"
        $args += $userArgs
    }
    return Start-Process `
        -FilePath $Godot `
        -ArgumentList $args `
        -WorkingDirectory $ProjectRoot `
        -RedirectStandardOutput (Join-Path $LogRoot "$name.out.log") `
        -RedirectStandardError (Join-Path $LogRoot "$name.err.log") `
        -WindowStyle Hidden `
        -PassThru
}

function Wait-LogMarker($name, $marker, $timeoutSeconds = 10) {
    $path = Join-Path $LogRoot "$name.out.log"
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $path) -and (Select-String -Path $path -SimpleMatch $marker -Quiet)) {
            Write-Host "WORLD_CRASH_SMOKE_READY $name $marker"
            return
        }
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path $path) { Write-Host (Get-Content $path -Raw) }
    throw "Timed out waiting for marker '$marker' in $name logs"
}

function Wait-WorldPid($worldKey, $minimumStartedCount = 1, $timeoutSeconds = 10) {
    $path = Join-Path $LogRoot "master.out.log"
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            $matches = Select-String -Path $path -Pattern "MASTER_WORLD_STARTED key=$worldKey pid=(\d+)"
            if ($matches.Count -ge $minimumStartedCount) {
                $line = $matches[$matches.Count - 1].Line
                if ($line -match "pid=(\d+)") {
                    return [int]$Matches[1]
                }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Timed out waiting for world pid for '$worldKey'"
}

$master = $null
$client = $null
try {
    $master = Start-Scene "master" "res://server/master/master.tscn" @() -Headless
    Wait-LogMarker "master" "MASTER_READY" 10

    $client = Start-Scene "client" "res://client/client.tscn" @("world_crash_recovery_test", "use_bundled_world_scenes") -Headless
    Wait-LogMarker "client" "WORLD_CRASH_RECOVERY_READY world=left_world" 30

    $firstPid = Wait-WorldPid "left_world" 1 10
    Write-Host "WORLD_CRASH_SMOKE_KILL key=left_world pid=$firstPid"
    Stop-Process -Id $firstPid -Force

    $client.WaitForExit($TimeoutSeconds * 1000) | Out-Null
    if (-not $client.HasExited) {
        Stop-Process -Id $client.Id -Force
        throw "World crash recovery client timed out"
    }

    $clientLog = Get-Content (Join-Path $LogRoot "client.out.log") -Raw
    if (-not $clientLog.Contains("WORLD_CRASH_RECOVERY_PASS")) {
        Write-Host $clientLog
        throw "World crash recovery did not pass"
    }
    Wait-WorldPid "left_world" 2 10 | Out-Null
    Wait-LogMarker "master" "MASTER_WORLD_STOPPED key=left_world" 10
    Write-Host "WORLD_CRASH_RECOVERY_SMOKE_PASS logs=$LogRoot"
}
finally {
    if ($client -and -not $client.HasExited) {
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
    }
    if ($master -and -not $master.HasExited) {
        Stop-Process -Id $master.Id -Force -ErrorAction SilentlyContinue
    }
    Get-NetTCPConnection -LocalPort 19080,19081,19082,19083,19084 -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -gt 0 } |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
}
