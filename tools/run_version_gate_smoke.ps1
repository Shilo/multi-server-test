param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$LogRoot = Join-Path $ProjectRoot ".logs\version_gate"
$ProjectFile = Join-Path $ProjectRoot "project.godot"

Remove-Item -Recurse -Force -Path $LogRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Set-ProjectVersion($version) {
    $safeVersion = $version -replace '[^a-zA-Z0-9_.-]', '_'
    $out = Join-Path $LogRoot "project_version_$safeVersion.out.log"
    $err = Join-Path $LogRoot "project_version_$safeVersion.err.log"
    $args = @("--headless", "--path", $ProjectRoot, "--script", (Join-Path $PSScriptRoot "project_version.gd"), "--", "--set", $version)
    $process = Start-Process -FilePath $Godot -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    $process.WaitForExit(30000) | Out-Null
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Project version command timed out while setting $version"
    }
    if (Test-Path $out) { Write-Host (Get-Content -LiteralPath $out -Raw) }
    if (Test-Path $err) { Write-Host (Get-Content -LiteralPath $err -Raw) }
    $exitCode = if ($null -eq $process.ExitCode) { 0 } else { $process.ExitCode }
    if ($exitCode -ne 0) {
        throw "Could not set project version to $version"
    }
}

function Refresh-ScriptClassCache {
    $cachePath = Join-Path $ProjectRoot ".godot\global_script_class_cache.cfg"
    if ((Test-Path $cachePath) -and (Select-String -Path $cachePath -SimpleMatch 'class": &"NetLog"' -Quiet)) {
        return
    }

    $out = Join-Path $LogRoot "script_cache_refresh.out.log"
    $err = Join-Path $LogRoot "script_cache_refresh.err.log"
    $args = @("--headless", "--path", $ProjectRoot, "--editor", "--quit")
    $process = Start-Process -FilePath $Godot -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    $process.WaitForExit(30000) | Out-Null
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Script class cache refresh timed out"
    }
    if (-not (Test-Path $cachePath) -or -not (Select-String -Path $cachePath -SimpleMatch 'class": &"NetLog"' -Quiet)) {
        if (Test-Path $out) { Write-Host (Get-Content $out -Raw) }
        if (Test-Path $err) { Write-Host (Get-Content $err -Raw) }
        throw "Script class cache refresh did not discover NetLog"
    }
}

function Start-Scene($name, $scenePath, $userArgs = @(), [switch]$Headless) {
    $out = Join-Path $LogRoot "$name.out.log"
    $err = Join-Path $LogRoot "$name.err.log"
    $args = @()
    if ($Headless) {
        $args += "--headless"
    }
    $args += @("--path", $ProjectRoot, "--scene", $scenePath)
    if ($userArgs.Count -gt 0) {
        $args += "--"
        $args += $userArgs
    }
    return Start-Process -FilePath $Godot -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
}

function Wait-LogMarker($name, $marker, $timeoutSeconds) {
    $out = Join-Path $LogRoot "$name.out.log"
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $out) -and (Select-String -Path $out -SimpleMatch $marker -Quiet)) {
            return
        }
        Start-Sleep -Milliseconds 100
    }

    if (Test-Path -LiteralPath $out) {
        Write-Host (Get-Content -LiteralPath $out -Raw)
    }
    $err = Join-Path $LogRoot "$name.err.log"
    if (Test-Path -LiteralPath $err) {
        Write-Host (Get-Content -LiteralPath $err -Raw)
    }
    throw "Timed out waiting for marker '$marker' in $name logs"
}

$originalProjectFile = Get-Content -LiteralPath $ProjectFile -Raw
$master = $null
$client = $null
try {
    Refresh-ScriptClassCache

    Set-ProjectVersion "8.8"
    $master = Start-Scene "master" "res://server/master/master.tscn" @() -Headless
    Wait-LogMarker "master" "MASTER_READY" 10

    Set-ProjectVersion "8.9"
    $client = Start-Scene "client" "res://client/client.tscn" @("smoke_test") -Headless
    $client.WaitForExit($TimeoutSeconds * 1000) | Out-Null
    $client.Refresh()
    if (-not $client.HasExited) {
        Stop-Process -Id $client.Id -Force
        throw "Version gate client timed out"
    }

    $clientLogPath = Join-Path $LogRoot "client.out.log"
    $clientLog = Get-Content -LiteralPath $clientLogPath -Raw
    if (-not $clientLog.Contains("PROJECT_VERSION_REJECTED client=8.9 server=8.8")) {
        Write-Host $clientLog
        throw "Version gate smoke did not log the expected client rejection"
    }
    if (-not $clientLog.Contains("SMOKE_FAIL bootstrap failed")) {
        Write-Host $clientLog
        throw "Version gate smoke did not fail bootstrap after rejection"
    }

    Set-ProjectVersion "8.8"
    $client = Start-Scene "client_bypass" "res://client/client.tscn" @("version_gate_bypass_test") -Headless
    $client.WaitForExit($TimeoutSeconds * 1000) | Out-Null
    $client.Refresh()
    if (-not $client.HasExited) {
        Stop-Process -Id $client.Id -Force
        throw "Version gate bypass client timed out"
    }

    $bypassLogPath = Join-Path $LogRoot "client_bypass.out.log"
    $bypassLog = Get-Content -LiteralPath $bypassLogPath -Raw
    if (-not $bypassLog.Contains("VERSION_GATE_BYPASS_PASS")) {
        Write-Host $bypassLog
        throw "Version gate smoke did not reject direct unvalidated RPCs"
    }

    $masterLog = Get-Content -LiteralPath (Join-Path $LogRoot "master.out.log") -Raw
    if ($masterLog.Contains("MASTER_WORLD_STARTED")) {
        Write-Host $masterLog
        throw "Version gate allowed a world to start for a mismatched client"
    }
    if ($masterLog.Contains("MASTER_LOGIN") -or $masterLog.Contains("[CHAT] received from peer")) {
        Write-Host $masterLog
        throw "Version gate allowed login or chat before route validation"
    }

    Write-Host "VERSION_GATE_SMOKE_PASS logs=$LogRoot"
}
finally {
    if ($client -and -not $client.HasExited) {
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
    }
    if ($master -and -not $master.HasExited) {
        Stop-Process -Id $master.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 200
    [System.IO.File]::WriteAllText($ProjectFile, $originalProjectFile, (New-Object System.Text.UTF8Encoding($false)))
}
