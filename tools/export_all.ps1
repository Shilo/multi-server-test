param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [switch]$Release
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$BuildRoot = Join-Path $ProjectRoot "builds"
$ProjectFile = Join-Path $ProjectRoot "project.godot"

$targets = @(
    @{ Name = "client"; Preset = "Windows Client"; Path = "client\client.exe"; PckRequired = $true },
    @{ Name = "server"; Preset = "Windows Server"; Path = "server\server.exe"; PckRequired = $false },
    @{ Name = "web_client"; Preset = "Web Client"; Path = "web\index.html"; PckRequired = $true }
)
$exportMode = if ($Release) { "--export-release" } else { "--export-debug" }

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
Remove-Item -Recurse -Force -Path (Join-Path $BuildRoot "master_server"), (Join-Path $BuildRoot "world_server") -ErrorAction SilentlyContinue

function Remove-EditorAutoloadForExport {
    $content = Get-Content -LiteralPath $ProjectFile
    $filtered = $content | Where-Object { $_ -notmatch '^RunInstanceGrid=' }
    Set-Content -LiteralPath $ProjectFile -Value $filtered
}

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

function Remove-ClientServerSidecars($outputDir) {
    Get-ChildItem -LiteralPath $outputDir -File -Filter "*gdsqlite*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -Force -LiteralPath $_.FullName
            Write-Host "EXPORT_REMOVED_CLIENT_SIDECAR $($_.FullName)"
        }
}

function Export-WorldPacks($worldPackRoot, $presetPrefix) {
    Remove-Item -Recurse -Force -Path $worldPackRoot -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $worldPackRoot | Out-Null

    Write-Host "EXPORT_WORLD_PACKS_START $worldPackRoot preset_prefix=$presetPrefix"
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "export_world_packs.ps1") -Godot $Godot -OutputDir $worldPackRoot -PresetPrefix $presetPrefix
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "World pack export failed with exit code $exitCode"
    }
    Get-ChildItem -LiteralPath (Join-Path $ProjectRoot "server\worlds") -Directory |
        ForEach-Object {
            Wait-FileStable (Join-Path $worldPackRoot "$($_.Name).pck")
        }
    Write-Host "EXPORT_WORLD_PACKS_DONE"
}

$originalProjectFile = Get-Content -LiteralPath $ProjectFile -Raw
try {
    Remove-EditorAutoloadForExport

    foreach ($target in $targets) {
        $output = Join-Path $BuildRoot $target.Path
        $pckOutput = [System.IO.Path]::ChangeExtension($output, ".pck")
        New-Item -ItemType Directory -Force -Path (Split-Path $output -Parent) | Out-Null
        Remove-Item -Force -Path $output, $pckOutput -ErrorAction SilentlyContinue

        Write-Host "EXPORT_START $($target.Name) $output"
        & $Godot --headless --path $ProjectRoot $exportMode $target.Preset $output
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($exitCode -ne 0) {
            throw "Export failed for $($target.Name) with exit code $exitCode"
        }

        Wait-FileStable $output
        if ($target.PckRequired) {
            Wait-FileStable $pckOutput
        }
        if ($target.Name -eq "client" -or $target.Name -eq "web_client") {
            Remove-ClientServerSidecars (Split-Path $output -Parent)
        }
        Write-Host "EXPORT_DONE $($target.Name)"
    }

    Export-WorldPacks (Join-Path $BuildRoot "world_packs") "World Pack - "
    Export-WorldPacks (Join-Path $BuildRoot "web\world_packs") "Web World Pack - "
}
finally {
    Set-Content -LiteralPath $ProjectFile -Value $originalProjectFile -NoNewline
}

Write-Host "EXPORT_ALL_DONE"
