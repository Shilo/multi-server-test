param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ProjectFile = Join-Path $ProjectRoot "project.godot"
$LogRoot = Join-Path $ProjectRoot ".logs\packrat_version_cache"
$WorldPackServeRoot = Join-Path $LogRoot "pack_server"
$WorldPackRoot = Join-Path $WorldPackServeRoot "world_packs"
$WorldPackPort = 19110
$PackRatCacheRoot = Join-Path $env:APPDATA "Godot\app_userdata\multi-server-test\pack_rat"

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
    if ((Test-Path $cachePath) -and (Select-String -Path $cachePath -SimpleMatch 'class": &"PackRat"' -Quiet)) {
        return
    }

    $out = Join-Path $LogRoot "script_cache_refresh.out.log"
    $err = Join-Path $LogRoot "script_cache_refresh.err.log"
    $process = Start-Process -FilePath $Godot -ArgumentList @("--headless", "--path", $ProjectRoot, "--editor", "--quit") -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    $process.WaitForExit(30000) | Out-Null
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        throw "Script class cache refresh timed out"
    }
    if (-not (Test-Path $cachePath) -or -not (Select-String -Path $cachePath -SimpleMatch 'class": &"PackRat"' -Quiet)) {
        if (Test-Path $out) { Write-Host (Get-Content $out -Raw) }
        if (Test-Path $err) { Write-Host (Get-Content $err -Raw) }
        throw "Script class cache refresh did not discover PackRat"
    }
}

function Export-WorldPacksOnce {
    Refresh-ScriptClassCache
    New-Item -ItemType Directory -Force -Path $WorldPackRoot | Out-Null
    $out = Join-Path $LogRoot "world_pack_export.out.log"
    $err = Join-Path $LogRoot "world_pack_export.err.log"
    $args = @(
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "export_world_packs.ps1"),
        "-Godot", $Godot,
        "-OutputDir", $WorldPackRoot
    )
    $process = Start-Process -FilePath "powershell" -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    $process.WaitForExit(120000) | Out-Null
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        throw "World pack export timed out"
    }
    if ($null -ne $process.ExitCode -and $process.ExitCode -ne 0) {
        if (Test-Path $out) { Write-Host (Get-Content $out -Raw) }
        if (Test-Path $err) { Write-Host (Get-Content $err -Raw) }
        throw "World pack export failed with exit code $($process.ExitCode)"
    }
}

function Clear-PackRatHttpCache {
    if (-not (Test-Path $PackRatCacheRoot)) {
        return
    }
    Remove-Item -Force -Path (Join-Path $PackRatCacheRoot "cache.json") -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $PackRatCacheRoot -Recurse -File -Include "*.pck", "*.part" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "*\editor_exports\*" } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Start-PackServer {
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw "Python is required to serve world packs for this smoke test."
    }

    $out = Join-Path $LogRoot "world_pack_http.out.log"
    $err = Join-Path $LogRoot "world_pack_http.err.log"
    $args = @("-m", "http.server", "$WorldPackPort", "--bind", "127.0.0.1", "--directory", $WorldPackServeRoot)
    $process = Start-Process -FilePath "python" -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500
    if ($process.HasExited) {
        if (Test-Path $out) { Write-Host (Get-Content $out -Raw) }
        if (Test-Path $err) { Write-Host (Get-Content $err -Raw) }
        throw "World pack HTTP server exited early"
    }
    return $process
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

function Wait-LogMarker($name, $marker, $timeoutSeconds = 10) {
    $out = Join-Path $LogRoot "$name.out.log"
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $out) -and (Select-String -Path $out -SimpleMatch $marker -Quiet)) {
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

function Stop-RunProcesses($master, $client) {
    if ($client -and -not $client.HasExited) {
        Stop-Process -Id $client.Id -Force -ErrorAction SilentlyContinue
        $client.WaitForExit(5000) | Out-Null
    }
    if ($master -and -not $master.HasExited) {
        Stop-Process -Id $master.Id -Force -ErrorAction SilentlyContinue
        $master.WaitForExit(5000) | Out-Null
    }
}

function Run-PackRatSmokeForVersion($version, $label, [switch]$ExpectOnlyCacheHits) {
    Set-ProjectVersion $version
    $master = $null
    $client = $null
    try {
        $master = Start-Scene "master_$label" "res://server/master/master.tscn" @() -Headless
        Wait-LogMarker "master_$label" "MASTER_READY"

        $client = Start-Scene "client_$label" "res://client/client.tscn" @("smoke_test", "force_packrat_world_packs") -Headless
        $client.WaitForExit($TimeoutSeconds * 1000) | Out-Null
        $client.Refresh()
        if (-not $client.HasExited) {
            Stop-Process -Id $client.Id -Force
            throw "Client $label timed out"
        }

        $clientLogPath = Join-Path $LogRoot "client_$label.out.log"
        $clientLog = Get-Content -LiteralPath $clientLogPath -Raw
        if (-not $clientLog.Contains("SMOKE_PASS")) {
            Write-Host $clientLog
            throw "Client $label did not complete smoke"
        }
        if (-not $clientLog.Contains("?v=$version")) {
            Write-Host $clientLog
            throw "Client $label did not request world packs with ?v=$version"
        }

        if ($ExpectOnlyCacheHits) {
            if ($clientLog.Contains("status=downloaded")) {
                Write-Host $clientLog
                throw "Client $label redownloaded a pack after only the app version changed"
            }
            if (-not $clientLog.Contains("status=cache_hit cache=true")) {
                Write-Host $clientLog
                throw "Client $label did not cache-hit after only the app version changed"
            }
        }
        else {
            if (-not $clientLog.Contains("status=downloaded cache=false")) {
                Write-Host $clientLog
                throw "Client $label did not download packs into an empty cache"
            }
        }
    }
    finally {
        Stop-RunProcesses $master $client
    }
}

$originalProjectFile = Get-Content -LiteralPath $ProjectFile -Raw
$originalPackBaseUrl = $env:MULTI_SERVER_WORLD_PACK_BASE_URL
$originalPackDir = $env:MULTI_SERVER_WORLD_PACK_DIR
$packServer = $null
try {
    Clear-PackRatHttpCache
    Export-WorldPacksOnce
    $packServer = Start-PackServer

    $env:MULTI_SERVER_WORLD_PACK_BASE_URL = "http://127.0.0.1:$WorldPackPort/world_packs"
    $env:MULTI_SERVER_WORLD_PACK_DIR = $WorldPackRoot

    Run-PackRatSmokeForVersion "7.1" "previous"
    Run-PackRatSmokeForVersion "7.2" "current" -ExpectOnlyCacheHits

    Write-Host "PACKRAT_VERSION_CACHE_SMOKE_PASS logs=$LogRoot"
}
finally {
    if ($packServer -and -not $packServer.HasExited) {
        Stop-Process -Id $packServer.Id -Force -ErrorAction SilentlyContinue
        $packServer.WaitForExit(5000) | Out-Null
    }
    if ($null -eq $originalPackBaseUrl) {
        Remove-Item Env:\MULTI_SERVER_WORLD_PACK_BASE_URL -ErrorAction SilentlyContinue
    }
    else {
        $env:MULTI_SERVER_WORLD_PACK_BASE_URL = $originalPackBaseUrl
    }
    if ($null -eq $originalPackDir) {
        Remove-Item Env:\MULTI_SERVER_WORLD_PACK_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:MULTI_SERVER_WORLD_PACK_DIR = $originalPackDir
    }
    Clear-PackRatHttpCache
    [System.IO.File]::WriteAllText($ProjectFile, $originalProjectFile, (New-Object System.Text.UTF8Encoding($false)))
}
