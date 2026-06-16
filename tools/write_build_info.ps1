param(
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$BuildInfoPath = Join-Path $ProjectRoot "shared\build\build_info.gd"

function Get-DefaultBuildVersion {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
        return $env:GITHUB_SHA.Substring(0, [Math]::Min(12, $env:GITHUB_SHA.Length))
    }

    $gitVersion = (& git -C $ProjectRoot rev-parse --short=12 HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($gitVersion)) {
        $version = $gitVersion.Trim()
        $status = (& git -C $ProjectRoot status --porcelain 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($status)) {
            return "$version-dirty"
        }
        return $version
    }

    return "dev"
}

function Get-SafeBuildVersion($value) {
    $clean = "$value".Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) {
        $clean = Get-DefaultBuildVersion
    }

    $clean = $clean -replace '[^0-9A-Za-z._-]', '-'
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return "dev"
    }
    return $clean
}

$safeVersion = Get-SafeBuildVersion $Version
$content = @"
extends RefCounted

const BUILD_VERSION := "$safeVersion"


static func version() -> String:
	return BUILD_VERSION
"@

$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($BuildInfoPath, $content, $encoding)
Write-Host "BUILD_INFO_WRITTEN version=$safeVersion path=$BuildInfoPath"
