param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [string]$OutputDir = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "builds\world_packs"),
    [string]$PresetPrefix = "World Pack - ",
    [Alias("WorldKeys")]
    [string]$WorldKeyFilter = "all"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$WorldRoot = Join-Path $ProjectRoot "server\worlds"
$ExportPresetsFile = Join-Path $ProjectRoot "export_presets.cfg"

function Get-WorldKeys {
    $keys = @()
    foreach ($directory in Get-ChildItem -Path $WorldRoot -Directory | Sort-Object Name) {
        $scenePath = Join-Path $directory.FullName "$($directory.Name).tscn"
        if (-not (Test-Path -LiteralPath $scenePath)) {
            throw "World folder '$($directory.Name)' must contain $($directory.Name).tscn"
        }
        $keys += $directory.Name
    }
    return $keys
}

function Wait-FileStable($path, $timeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $lastLength = -1
    $stableChecks = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path
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

function Get-PresetNames {
    if (-not (Test-Path -LiteralPath $ExportPresetsFile)) {
        throw "Missing export presets file: $ExportPresetsFile"
    }

    $names = @{}
    foreach ($line in Get-Content -LiteralPath $ExportPresetsFile) {
        if ($line -match '^name="(.+)"$') {
            $names[$matches[1]] = $true
        }
    }
    return $names
}

function Assert-WorldPackPresets($worldKeys) {
    $presetNames = Get-PresetNames
    foreach ($worldKey in $worldKeys) {
        $preset = "$PresetPrefix$worldKey"
        if (-not $presetNames.ContainsKey($preset)) {
            throw "Missing export preset '$preset' for world '$worldKey'. Add it to export_presets.cfg."
        }
    }
}

function Export-WorldPack($worldKey) {
    $preset = "$PresetPrefix$worldKey"
    $tempPath = Join-Path $OutputDir "$worldKey.uploading.pck"
    $outputPath = Join-Path $OutputDir "$worldKey.pck"

    Remove-Item -Force -LiteralPath $tempPath, $outputPath -ErrorAction SilentlyContinue
    Write-Host "WORLD_PACK_EXPORT_START key=$worldKey preset=$preset path=$outputPath"
    & $Godot --headless --path $ProjectRoot --export-pack $preset $tempPath
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "World pack export failed for '$worldKey' with exit code $exitCode"
    }

    Wait-FileStable $tempPath 120
    Move-Item -Force -LiteralPath $tempPath -Destination $outputPath

    $item = Get-Item -LiteralPath $outputPath
    if ($item.Length -le 0) {
        throw "World pack export produced an empty file: $outputPath"
    }
    $modifiedTime = [int64]($item.LastWriteTimeUtc - [datetime]'1970-01-01Z').TotalSeconds
    Write-Host "WORLD_PACK_EXPORTED key=$worldKey path=$outputPath size=$($item.Length) modified_time=$modifiedTime preset=$preset"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
Remove-Item -Force -Path (Join-Path $OutputDir "*.uploading.pck") -ErrorAction SilentlyContinue

$worldKeys = Get-WorldKeys
if ($WorldKeyFilter -ne "all") {
    $requestedKeys = @(
        $WorldKeyFilter.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries) |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($requestedKeys.Count -eq 0) {
        Write-Host "WORLD_PACK_EXPORT_DONE count=0 dir=$OutputDir preset_prefix=$PresetPrefix"
        exit 0
    }
    foreach ($worldKey in $requestedKeys) {
        if (-not ($worldKeys -contains $worldKey)) {
            throw "Unknown world '$worldKey'. Valid worlds: $($worldKeys -join ', ')"
        }
    }
    $worldKeys = $requestedKeys
}
Assert-WorldPackPresets $worldKeys
foreach ($worldKey in $worldKeys) {
    Export-WorldPack $worldKey
}

Write-Host "WORLD_PACK_EXPORT_DONE count=$($worldKeys.Count) dir=$OutputDir preset_prefix=$PresetPrefix"
