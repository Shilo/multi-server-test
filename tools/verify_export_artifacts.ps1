param(
    [string]$BuildRoot = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "builds")
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Read-PckEntries($path, [int64]$packStart = 0) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing PCK: $path"
    }

    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $stream.Seek($packStart, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = [System.IO.BinaryReader]::new($stream)
        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne "GDPC") {
            throw "Not a Godot PCK file at offset ${packStart}: $path"
        }

        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt64()
        $directoryOffset = $reader.ReadUInt64()
        if ($directoryOffset -le 0 -or ($packStart + [int64]$directoryOffset) -ge $stream.Length) {
            throw "Invalid PCK directory offset ${directoryOffset} at offset ${packStart}: $path"
        }

        $stream.Seek($packStart + [int64]$directoryOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $fileCount = $reader.ReadUInt32()
        if ($fileCount -gt 10000) {
            throw "Unreasonable PCK file count ${fileCount} at offset ${packStart}: $path"
        }
        $entries = New-Object System.Collections.Generic.List[string]

        for ($i = 0; $i -lt $fileCount; $i++) {
            $pathLength = $reader.ReadUInt32()
            if ($pathLength -le 0 -or $pathLength -gt 4096) {
                throw "Invalid PCK path length ${pathLength} at offset ${packStart}: $path"
            }
            $pathBytes = $reader.ReadBytes([int]$pathLength)
            $entryPath = [System.Text.Encoding]::UTF8.GetString($pathBytes).TrimEnd([char]0)
            $entries.Add($entryPath)

            $null = $reader.ReadUInt64()
            $null = $reader.ReadUInt64()
            $null = $reader.ReadBytes(16)
            $null = $reader.ReadUInt32()
        }

        return $entries
    }
    finally {
        $stream.Dispose()
    }
}

function Find-PckOffsets($path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $offsets = New-Object System.Collections.Generic.List[int64]
    for ($i = 0; $i -le $bytes.Length - 4; $i++) {
        if ($bytes[$i] -eq 0x47 -and $bytes[$i + 1] -eq 0x44 -and $bytes[$i + 2] -eq 0x50 -and $bytes[$i + 3] -eq 0x43) {
            $offsets.Add([int64]$i)
        }
    }
    return $offsets
}

function Read-EmbeddedPckEntries($path) {
    $valid = @()
    foreach ($offset in Find-PckOffsets $path) {
        try {
            $entries = Read-PckEntries $path $offset
            $valid += @{
                Offset = $offset
                Entries = $entries
            }
        }
        catch {
            # Ignore GDPC byte sequences that appear in executable data.
        }
    }
    if ($valid.Count -ne 1) {
        throw "Expected exactly one embedded PCK in ${path}, found $($valid.Count)."
    }
    Write-Host "VERIFY_EMBEDDED_PCK_OK path=$path offset=$($valid[0].Offset) entries=$($valid[0].Entries.Count)"
    return $valid[0].Entries
}

function Assert-NoServerEntries($path) {
    $entries = Read-PckEntries $path
    $serverEntries = @($entries | Where-Object { ($_ -like "server/*") -or ($_ -like "res://server/*") })
    if ($serverEntries.Count -gt 0) {
        throw "Client export includes server files in ${path}: $($serverEntries -join ', ')"
    }
    Assert-NoEditorEntries $path $entries
    Write-Host "VERIFY_CLIENT_PACK_OK path=$path entries=$($entries.Count)"
}

function Assert-NoClientEntries($path, $entries = $null) {
    if ($null -eq $entries) {
        $entries = Read-PckEntries $path
    }
    $clientEntries = @($entries | Where-Object { ($_ -like "client/*") -or ($_ -like "res://client/*") })
    if ($clientEntries.Count -gt 0) {
        throw "Server export includes client files in ${path}: $($clientEntries -join ', ')"
    }
    Assert-NoEditorEntries $path $entries
    Write-Host "VERIFY_SERVER_PACK_OK path=$path entries=$($entries.Count)"
}

function Assert-NoEditorEntries($path, $entries = $null) {
    if ($null -eq $entries) {
        $entries = Read-PckEntries $path
    }
    $editorEntries = @($entries | Where-Object { ($_ -like "editor/*") -or ($_ -like "res://editor/*") })
    if ($editorEntries.Count -gt 0) {
        throw "Runtime export includes editor files in ${path}: $($editorEntries -join ', ')"
    }
    Write-Host "VERIFY_NO_EDITOR_ENTRIES_OK path=$path"
}

function Assert-NoServerSidecars($path) {
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }
    $sidecars = @(
        Get-ChildItem -LiteralPath $path -File -Recurse |
            Where-Object { $_.Name -like "*gdsqlite*" }
    )
    if ($sidecars.Count -gt 0) {
        throw "Client/Web export contains server-only SQLite sidecars: $($sidecars.FullName -join ', ')"
    }
    Write-Host "VERIFY_NO_SERVER_SIDECARS_OK path=$path"
}

function Assert-WorldPack($path, $worldKey) {
    $entries = Read-PckEntries $path
    Assert-NoEditorEntries $path $entries
    $normalizedEntries = @($entries | ForEach-Object {
            if ($_ -like "res://*") {
                $_.Substring(6)
            }
            else {
                $_
            }
        })
    $expectedScene = "server/worlds/$worldKey/$worldKey.tscn"
    $expectedRemap = "$expectedScene.remap"
    if (-not (($normalizedEntries -contains $expectedScene) -or ($normalizedEntries -contains $expectedRemap))) {
        throw "World pack $path is missing $expectedScene or $expectedRemap"
    }
    $wrongWorldEntries = @($normalizedEntries | Where-Object {
            $_ -like "server/worlds/*" -and
            $_ -notlike "server/worlds/$worldKey/*"
        })
    if ($wrongWorldEntries.Count -gt 0) {
        throw "World pack $path contains other world files: $($wrongWorldEntries -join ', ')"
    }

    $allowedMetadataEntries = @(
        ".godot/global_script_class_cache.cfg",
        ".godot/uid_cache.bin",
        "icon.svg",
        "project.binary"
    )
    $unexpectedEntries = @($normalizedEntries | Where-Object {
            $_ -notlike "server/worlds/$worldKey/*" -and
            $_ -notlike ".godot/exported/*" -and
            -not ($allowedMetadataEntries -contains $_)
        })
    if ($unexpectedEntries.Count -gt 0) {
        throw "World pack $path contains unexpected non-world entries: $($unexpectedEntries -join ', ')"
    }
    Write-Host "VERIFY_WORLD_PACK_OK key=$worldKey path=$path entries=$($entries.Count)"
}

$clientPack = Join-Path $BuildRoot "client\client.pck"
$webPack = Join-Path $BuildRoot "web\index.pck"
$serverExe = Join-Path $BuildRoot "server\server.exe"
Assert-NoServerEntries $clientPack
Assert-NoServerEntries $webPack
Assert-NoClientEntries $serverExe (Read-EmbeddedPckEntries $serverExe)
Assert-NoServerSidecars (Join-Path $BuildRoot "client")
Assert-NoServerSidecars (Join-Path $BuildRoot "web")

$worldKeys = @(
    Get-ChildItem -Path (Join-Path $ProjectRoot "server\worlds") -Directory |
        Sort-Object Name |
        ForEach-Object {
            $scenePath = Join-Path $_.FullName "$($_.Name).tscn"
            if (-not (Test-Path -LiteralPath $scenePath)) {
                throw "World folder '$($_.Name)' must contain $($_.Name).tscn"
            }
            $_.Name
        }
)
foreach ($worldKey in $worldKeys) {
    $sourcePath = Join-Path $BuildRoot "world_packs\$worldKey.pck"
    $mirrorPath = Join-Path $BuildRoot "web\world_packs\$worldKey.pck"
    Assert-WorldPack $sourcePath $worldKey
    Assert-WorldPack $mirrorPath $worldKey
}

Write-Host "VERIFY_EXPORT_ARTIFACTS_DONE"
