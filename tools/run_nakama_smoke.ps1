param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [int]$TimeoutSeconds = 45,
    [int]$ClientCount = 1
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$LogRoot = Join-Path $ProjectRoot ".logs\nakama-smoke"

Remove-Item -Recurse -Force -Path $LogRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

& $Godot --headless --editor --path $ProjectRoot --quit

function Start-GodotRole($Name, $RoleArgs) {
    $out = Join-Path $LogRoot "$Name.out.log"
    $err = Join-Path $LogRoot "$Name.err.log"
    $args = @("--headless", "--path", $ProjectRoot, "--") + $RoleArgs
    Write-Host "NAKAMA_SMOKE_LAUNCH $Name"
    return Start-Process -FilePath $Godot -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
}

function Wait-LogMarker($Name, $Marker, $Timeout = 10) {
    $out = Join-Path $LogRoot "$Name.out.log"
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $out) -and (Select-String -Path $out -SimpleMatch $Marker -Quiet)) {
            Write-Host "NAKAMA_SMOKE_READY $Name $Marker"
            return
        }
        Start-Sleep -Milliseconds 100
    }
    if (Test-Path $out) { Write-Host (Get-Content $out -Raw) }
    $err = Join-Path $LogRoot "$Name.err.log"
    if (Test-Path $err) { Write-Host (Get-Content $err -Raw) }
    throw "Timed out waiting for '$Marker' in $Name logs"
}

$servers = @()
$clients = @()
try {
    $servers += Start-GodotRole "orchestrator" @(
        "--role", "orchestrator",
        "--spawn-godot", $Godot,
        "--project-root", $ProjectRoot,
        "--orchestrator-key", "localdev-secret"
    )
    Wait-LogMarker "orchestrator" "ORCHESTRATOR_READY"

    for ($i = 1; $i -le $ClientCount; $i++) {
        $clientName = if ($ClientCount -eq 1) { "client" } else { "client$i" }
        $clients += @{
            Name = $clientName
            Process = Start-GodotRole $clientName @(
                "--role", "client",
                "--smoke-test",
                "--device-id", "virtucade-smoke-$i-$(Get-Random)"
            )
        }
    }

    foreach ($clientEntry in $clients) {
        $clientName = $clientEntry.Name
        $clientProcess = $clientEntry.Process
        $clientProcess.WaitForExit($TimeoutSeconds * 1000) | Out-Null
        if (-not $clientProcess.HasExited) {
            Stop-Process -Id $clientProcess.Id -Force
            throw "Nakama smoke client $clientName timed out after $TimeoutSeconds seconds"
        }

        $clientLogPath = Join-Path $LogRoot "$clientName.out.log"
        $clientLog = Get-Content $clientLogPath -Raw
        if (-not $clientLog.Contains("SMOKE_PASS")) {
            Write-Host $clientLog
            $clientErrPath = Join-Path $LogRoot "$clientName.err.log"
            if (Test-Path $clientErrPath) {
                Write-Host (Get-Content $clientErrPath -Raw)
            }
            throw "Nakama smoke did not produce SMOKE_PASS for $clientName"
        }
    }

    Write-Host "NAKAMA_SMOKE_PASS clients=$ClientCount logs=$LogRoot"
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
