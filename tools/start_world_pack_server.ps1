param(
    [int]$Port = 19100,
    [string]$Directory = "builds"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ServeRoot = Resolve-Path (Join-Path $ProjectRoot $Directory)
$WorldPackRoot = Join-Path $ServeRoot "world_packs"

if (-not (Test-Path $WorldPackRoot)) {
    throw "Missing world packs at $WorldPackRoot. Run tools\export_world_packs.ps1 or tools\export_all.ps1 first."
}

Write-Host "WORLD_PACK_SERVER_ROOT $ServeRoot"
Write-Host "WORLD_PACK_SERVER_URL http://127.0.0.1:$Port/world_packs/hub.pck"
Write-Host "Press Ctrl+C to stop."

python -m http.server $Port --bind 127.0.0.1 --directory $ServeRoot
