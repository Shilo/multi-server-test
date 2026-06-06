param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [string]$Preset = "Windows Desktop"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$BuildRoot = Join-Path $ProjectRoot "builds"
$SharedRoot = Join-Path $BuildRoot "_shared"
$SharedExe = Join-Path $SharedRoot "multi-server-test.exe"
$SharedPck = Join-Path $SharedRoot "multi-server-test.pck"

$targets = @(
    @{ Name = "client"; Path = "client\client.exe" },
    @{ Name = "master"; Path = "master\master.exe" },
    @{ Name = "chat"; Path = "chat\chat.exe" },
    @{ Name = "world1"; Path = "world1\world1.exe" },
    @{ Name = "world2"; Path = "world2\world2.exe" },
    @{ Name = "world3"; Path = "world3\world3.exe" }
)

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
New-Item -ItemType Directory -Force -Path $SharedRoot | Out-Null

function Wait-FileStable($path, $timeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $lastLength = -1
    $stableChecks = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            $item = Get-Item $path
            if ($item.Length -eq $lastLength -and $item.Length -gt 0) {
                $stableChecks += 1
                if ($stableChecks -ge 5) {
                    return
                }
            }
            else {
                $stableChecks = 0
                $lastLength = $item.Length
            }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "File did not become stable: $path"
}

Remove-Item -Force -Path $SharedExe, $SharedPck -ErrorAction SilentlyContinue
Write-Host "EXPORT_START shared $SharedExe"
& $Godot --headless --path $ProjectRoot --export-debug $Preset $SharedExe
$exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($exitCode -ne 0) {
    throw "Export failed for shared artifact with exit code $exitCode"
}
Wait-FileStable $SharedExe
Wait-FileStable $SharedPck
Write-Host "EXPORT_DONE shared"

foreach ($target in $targets) {
    $output = Join-Path $BuildRoot $target.Path
    $pckOutput = [System.IO.Path]::ChangeExtension($output, ".pck")
    New-Item -ItemType Directory -Force -Path (Split-Path $output -Parent) | Out-Null
    Copy-Item -Force -Path $SharedExe -Destination $output
    Copy-Item -Force -Path $SharedPck -Destination $pckOutput
    Write-Host "EXPORT_DONE $($target.Name)"
}

Write-Host "EXPORT_ALL_DONE"
