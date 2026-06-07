param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [string]$OrchestratorExe = "",
    [switch]$ClientOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$LogRoot = Join-Path $ProjectRoot ".logs\nakama-mvp"

New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

& $Godot --headless --editor --path $ProjectRoot --quit

function Get-OrchestratorExe {
    if ($OrchestratorExe) {
        return $OrchestratorExe
    }

    $go = Get-Command go -ErrorAction SilentlyContinue
    if (-not $go) {
        throw "Go is required to build the lightweight orchestrator. Install Go or pass -OrchestratorExe."
    }

    $exeName = if ($IsWindows -or $env:OS -eq "Windows_NT") { "virtucade-orchestrator.exe" } else { "virtucade-orchestrator" }
    $output = Join-Path $LogRoot $exeName
    & $go.Source build -o $output ./orchestrator
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build Go orchestrator"
    }
    return $output
}

function Start-Orchestrator {
    $exe = Get-OrchestratorExe
    $out = Join-Path $LogRoot "orchestrator.out.log"
    $err = Join-Path $LogRoot "orchestrator.err.log"
    $args = @(
        "--godot", $Godot,
        "--project-root", $ProjectRoot,
        "--key", "localdev-secret",
        "--log-root", (Join-Path $LogRoot "worlds")
    )
    Write-Host "NAKAMA_MVP_LAUNCH orchestrator"
    return Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
}

$orchestrator = $null
try {
    if (-not $ClientOnly) {
        $orchestrator = Start-Orchestrator
        Write-Host "NAKAMA_MVP_ORCHESTRATOR http://127.0.0.1:19100"
    }

    & $Godot --path $ProjectRoot -- --role client --nakama-mvp
}
finally {
    if ($orchestrator -and -not $orchestrator.HasExited) {
        Stop-Process -Id $orchestrator.Id -Force
    }
    Get-CimInstance Win32_Process -Filter "name = 'Godot_v4.6.3-stable_win64.exe'" |
        Where-Object {
            $_.CommandLine -like "*$ProjectRoot*" -and $_.CommandLine -like "*--role world*"
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
