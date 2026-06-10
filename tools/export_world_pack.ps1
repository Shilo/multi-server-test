param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [string]$WorldKey = "hub",
    [string]$Preset = "Hub World Pack",
    [string]$OutputRoot = "",
    [string]$PackBaseUrl = "http://127.0.0.1:19100/world_packs",
    [switch]$UpdateProjectManifest,
    [switch]$UsePckPackerFallback
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ProjectFile = Join-Path $ProjectRoot "project.godot"
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $ProjectRoot "builds\world_packs"
}
else {
    $OutputRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
}

$packOutput = Join-Path $OutputRoot "$WorldKey.pck"
$manifestOutput = Join-Path $OutputRoot "worlds.json"

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

function Export-WithPreset {
    Write-Host "WORLD_PACK_EXPORT_START preset=$Preset world=$WorldKey output=$packOutput"
    & $Godot --headless --path $ProjectRoot --export-pack $Preset $packOutput
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "World pack export failed for $WorldKey with exit code $exitCode"
    }
}

function Export-WithPckPackerFallback {
    Write-Host "WORLD_PACK_FALLBACK_START world=$WorldKey output=$packOutput"
    & $Godot --headless --path $ProjectRoot -s res://tools/pack_world_pck.gd -- $WorldKey $packOutput
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Fallback world pack export failed for $WorldKey with exit code $exitCode"
    }
}

function Update-ManifestFile($path, $metadata) {
    if (Test-Path $path) {
        $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    else {
        $manifest = [pscustomobject]@{
            schema_version = 1
            asset_base_url = $PackBaseUrl
            worlds = [pscustomobject]@{}
        }
    }

    if (-not $manifest.PSObject.Properties["schema_version"]) {
        $manifest | Add-Member -MemberType NoteProperty -Name "schema_version" -Value 1
    }
    if ($manifest.PSObject.Properties["asset_base_url"]) {
        $manifest.asset_base_url = $PackBaseUrl
    }
    else {
        $manifest | Add-Member -MemberType NoteProperty -Name "asset_base_url" -Value $PackBaseUrl
    }
    if (-not $manifest.PSObject.Properties["worlds"]) {
        $manifest | Add-Member -MemberType NoteProperty -Name "worlds" -Value ([pscustomobject]@{})
    }

    $worlds = $manifest.worlds
    if (-not $worlds.PSObject.Properties[$WorldKey]) {
        $worlds | Add-Member -MemberType NoteProperty -Name $WorldKey -Value ([pscustomobject]@{})
    }

    $world = $worlds.$WorldKey
    $displayName = (Get-Culture).TextInfo.ToTitleCase($WorldKey.Replace("_", " "))
    foreach ($property in @(
        @{ Name = "display_name"; Value = $displayName },
        @{ Name = "scene"; Value = "res://server/worlds/$WorldKey/$WorldKey.tscn" }
    )) {
        if ($world.PSObject.Properties[$property.Name]) {
            $world.$($property.Name) = $property.Value
        }
        else {
            $world | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
    }

    $packObject = ($metadata | ConvertTo-Json -Depth 8) | ConvertFrom-Json
    if ($world.PSObject.Properties["pack"]) {
        $world.pack = $packObject
    }
    else {
        $world | Add-Member -MemberType NoteProperty -Name "pack" -Value $packObject
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path
}

function Update-ProjectManifestFile($path, $metadata) {
    if (Test-Path $path) {
        $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    else {
        $manifest = [pscustomobject]@{
            schema_version = 1
            asset_base_url = $PackBaseUrl
            worlds = [pscustomobject]@{}
        }
    }

    if (-not $manifest.PSObject.Properties["schema_version"]) {
        $manifest | Add-Member -MemberType NoteProperty -Name "schema_version" -Value 1
    }
    if ($manifest.PSObject.Properties["asset_base_url"]) {
        $manifest.asset_base_url = $PackBaseUrl
    }
    else {
        $manifest | Add-Member -MemberType NoteProperty -Name "asset_base_url" -Value $PackBaseUrl
    }
    if (-not $manifest.PSObject.Properties["worlds"]) {
        $manifest | Add-Member -MemberType NoteProperty -Name "worlds" -Value ([pscustomobject]@{})
    }

    $worlds = $manifest.worlds
    if (-not $worlds.PSObject.Properties[$WorldKey]) {
        $worlds | Add-Member -MemberType NoteProperty -Name $WorldKey -Value ([pscustomobject]@{})
    }

    $world = $worlds.$WorldKey
    $displayName = (Get-Culture).TextInfo.ToTitleCase($WorldKey.Replace("_", " "))
    foreach ($property in @(
        @{ Name = "display_name"; Value = $displayName },
        @{ Name = "scene"; Value = "res://server/worlds/$WorldKey/$WorldKey.tscn" }
    )) {
        if ($world.PSObject.Properties[$property.Name]) {
            $world.$($property.Name) = $property.Value
        }
        else {
            $world | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
    }

    $packObject = ($metadata | ConvertTo-Json -Depth 8) | ConvertFrom-Json
    if ($world.PSObject.Properties["pack"]) {
        $world.pack = $packObject
    }
    else {
        $world | Add-Member -MemberType NoteProperty -Name "pack" -Value $packObject
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
Remove-Item -Force -Path $packOutput -ErrorAction SilentlyContinue

$originalProjectFile = Get-Content -LiteralPath $ProjectFile -Raw
try {
    Remove-EditorAutoloadForExport
    if ($UsePckPackerFallback) {
        Export-WithPckPackerFallback
    }
    else {
        Export-WithPreset
    }
}
finally {
    Set-Content -LiteralPath $ProjectFile -Value $originalProjectFile -NoNewline
}

Wait-FileStable $packOutput

$packItem = Get-Item -LiteralPath $packOutput
$sha256 = (Get-FileHash -LiteralPath $packOutput -Algorithm SHA256).Hash.ToLowerInvariant()
$metadata = [ordered]@{
    enabled = $true
    file = $packItem.Name
    url = ("{0}/{1}" -f $PackBaseUrl.TrimEnd("/"), $packItem.Name)
    version = $sha256.Substring(0, 12)
    sha256 = $sha256
    size = $packItem.Length
}

Update-ManifestFile $manifestOutput $metadata

if ($UpdateProjectManifest) {
    Update-ProjectManifestFile (Join-Path $ProjectRoot "server\worlds\world_manifest.json") $metadata
}

Write-Host "WORLD_PACK_EXPORT_DONE world=$WorldKey pck=$packOutput sha256=$sha256 manifest=$manifestOutput"
