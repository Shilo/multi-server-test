$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$Godot = $env:GODOT_BIN
if ([string]::IsNullOrWhiteSpace($Godot)) {
    $Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe"
}

if (-not (Test-Path -LiteralPath $Godot)) {
    throw "Godot binary not found. Set GODOT_BIN or update the default path: $Godot"
}

& $Godot --headless --path $ProjectRoot --script (Join-Path $PSScriptRoot "net_config_smoke.gd")
if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "NET_CONFIG_SMOKE failed with exit code $LASTEXITCODE"
}
