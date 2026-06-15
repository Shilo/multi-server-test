param(
    [string]$BuildRoot = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "builds")
)

$ErrorActionPreference = "Stop"

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

function Assert-WorldPack($path, $worldKey) {
    $entries = Read-PckEntries $path
    $expected = "server/worlds/$worldKey/$worldKey.tscn"
    if (-not ($entries -contains $expected)) {
        throw "World pack $path is missing $expected"
    }
    Write-Host "VERIFY_WORLD_PACK_OK key=$worldKey path=$path entries=$($entries.Count)"
}

function Assert-MirroredMetadata($sourcePath, $mirrorPath) {
    $source = Get-Item -LiteralPath $sourcePath
    $mirror = Get-Item -LiteralPath $mirrorPath
    if ($source.Length -ne $mirror.Length) {
        throw "Mirrored pack size mismatch: $sourcePath ($($source.Length)) != $mirrorPath ($($mirror.Length))"
    }
    if ([int64]($source.LastWriteTimeUtc - [datetime]'1970-01-01Z').TotalSeconds -ne [int64]($mirror.LastWriteTimeUtc - [datetime]'1970-01-01Z').TotalSeconds) {
        throw "Mirrored pack modified time mismatch: $sourcePath ($($source.LastWriteTimeUtc)) != $mirrorPath ($($mirror.LastWriteTimeUtc))"
    }
}

$clientPack = Join-Path $BuildRoot "client\client.pck"
$webPack = Join-Path $BuildRoot "web\index.pck"
Assert-NoServerEntries $clientPack
Assert-NoServerEntries $webPack

$worldKeys = @("hub", "left_world", "right_world", "top_world")
foreach ($worldKey in $worldKeys) {
    $sourcePath = Join-Path $BuildRoot "world_packs\$worldKey.pck"
    $mirrorPath = Join-Path $BuildRoot "web\world_packs\$worldKey.pck"
    Assert-WorldPack $sourcePath $worldKey
    Assert-WorldPack $mirrorPath $worldKey
    Assert-MirroredMetadata $sourcePath $mirrorPath
}

Write-Host "VERIFY_EXPORT_ARTIFACTS_DONE"
