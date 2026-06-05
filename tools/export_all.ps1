param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [string]$Preset = "Windows Desktop"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$BuildRoot = Join-Path $ProjectRoot "builds"

$targets = @(
    @{ Name = "client"; Path = "client\client.exe" },
    @{ Name = "master"; Path = "master\master.exe" },
    @{ Name = "chat"; Path = "chat\chat.exe" },
    @{ Name = "world1"; Path = "world1\world1.exe" },
    @{ Name = "world2"; Path = "world2\world2.exe" },
    @{ Name = "world3"; Path = "world3\world3.exe" }
)

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

foreach ($target in $targets) {
    $output = Join-Path $BuildRoot $target.Path
    New-Item -ItemType Directory -Force -Path (Split-Path $output -Parent) | Out-Null
    Write-Host "EXPORT_START $($target.Name) $output"
    & $Godot --headless --path $ProjectRoot --export-debug $Preset $output
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Export failed for $($target.Name) with exit code $exitCode"
    }
    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path $output) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path $output)) {
        throw "Expected exported executable missing: $output"
    }
    Write-Host "EXPORT_DONE $($target.Name)"
}

Write-Host "EXPORT_ALL_DONE"
