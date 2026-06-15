param(
    [string]$BuildRoot = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "builds")
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Read-PckEntries($path) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing PCK: $path"
    }

    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne "GDPC") {
            throw "Not a Godot PCK file: $path"
        }

        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt32()
        $null = $reader.ReadUInt64()
        $directoryOffset = $reader.ReadUInt64()

        $stream.Seek([int64]$directoryOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $fileCount = $reader.ReadUInt32()
        $entries = New-Object System.Collections.Generic.List[string]

        for ($i = 0; $i -lt $fileCount; $i++) {
            $pathLength = $reader.ReadUInt32()
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

function Assert-NoServerEntries($path) {
    $entries = Read-PckEntries $path
    $serverEntries = @($entries | Where-Object { $_ -like "res://server/*" })
    if ($serverEntries.Count -gt 0) {
        throw "Client export includes server files in ${path}: $($serverEntries -join ', ')"
    }
    Write-Host "VERIFY_CLIENT_PACK_OK path=$path entries=$($entries.Count)"
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
    $expectedScene = "server/worlds/$worldKey/$worldKey.tscn"
    $expectedRemap = "$expectedScene.remap"
    if (-not (($entries -contains $expectedScene) -or ($entries -contains $expectedRemap))) {
        throw "World pack $path is missing $expectedScene or $expectedRemap"
    }
    $wrongWorldEntries = @($entries | Where-Object {
            $_ -like "server/worlds/*" -and
            $_ -notlike "server/worlds/$worldKey/*"
        })
    if ($wrongWorldEntries.Count -gt 0) {
        throw "World pack $path contains other world files: $($wrongWorldEntries -join ', ')"
    }
    Write-Host "VERIFY_WORLD_PACK_OK key=$worldKey path=$path entries=$($entries.Count)"
}

$clientPack = Join-Path $BuildRoot "client\client.pck"
$webPack = Join-Path $BuildRoot "web\index.pck"
Assert-NoServerEntries $clientPack
Assert-NoServerEntries $webPack
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
