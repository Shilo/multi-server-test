param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [switch]$ClientOnly
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$LogRoot = Join-Path $ProjectRoot ".logs\nakama-mvp"

New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

& $Godot --headless --editor --path $ProjectRoot --quit

function Start-GodotRole($Name, $RoleArgs) {
    $out = Join-Path $LogRoot "$Name.out.log"
    $err = Join-Path $LogRoot "$Name.err.log"
    $args = @("--headless", "--path", $ProjectRoot, "--") + $RoleArgs
    Write-Host "NAKAMA_MVP_LAUNCH $Name"
    return Start-Process -FilePath $Godot -ArgumentList $args -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
}

$orchestrator = $null
try {
    if (-not $ClientOnly) {
        $orchestrator = Start-GodotRole "orchestrator" @(
            "--role", "orchestrator",
            "--spawn-godot", $Godot,
            "--project-root", $ProjectRoot,
            "--orchestrator-key", "localdev-secret"
        )
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
            $_.CommandLine -like "*$ProjectRoot*" -and
            ($_.CommandLine -like "*--role world*" -or $_.CommandLine -like "*--role orchestrator*")
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
