param(
    [switch]$Print,
    [string]$Set = "",
    [switch]$BumpMinor,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ProjectFile = Join-Path $ProjectRoot "project.godot"
$VersionPattern = '(?m)^config/version="([^"]+)"$'

function Test-ProjectVersion([string]$Version) {
    return $Version -match '^(0|[1-9][0-9]*)\.[0-9]$'
}

function Read-ProjectVersion {
    $content = Get-Content -LiteralPath $ProjectFile -Raw
    $matches = [regex]::Matches($content, $VersionPattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one application config/version entry in $ProjectFile, found $($matches.Count)."
    }

    $version = $matches[0].Groups[1].Value
    if (-not (Test-ProjectVersion $version)) {
        throw "Project version must be canonical MAJOR.MINOR with no leading zeroes and MINOR from 0 to 9, got: $version"
    }
    return $version
}

function Get-NextMinorVersion([string]$Version) {
    if (-not (Test-ProjectVersion $Version)) {
        throw "Cannot bump invalid project version: $Version"
    }

    $parts = $Version.Split(".")
    $major = [int]$parts[0]
    $minor = [int]$parts[1] + 1
    if ($minor -gt 9) {
        $major += 1
        $minor = 0
    }
    return "$major.$minor"
}

function Set-ProjectVersion([string]$Version) {
    $cleanVersion = $Version.Trim()
    if (-not (Test-ProjectVersion $cleanVersion)) {
        throw "Version must be canonical MAJOR.MINOR with no leading zeroes and MINOR from 0 to 9, got: $Version"
    }

    $content = Get-Content -LiteralPath $ProjectFile -Raw
    $matches = [regex]::Matches($content, $VersionPattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one application config/version entry in $ProjectFile, found $($matches.Count)."
    }

    $updated = [regex]::Replace($content, $VersionPattern, "config/version=`"$cleanVersion`"", 1)
    [System.IO.File]::WriteAllText($ProjectFile, $updated, (New-Object System.Text.UTF8Encoding($false)))

    $savedVersion = Read-ProjectVersion
    if ($savedVersion -ne $cleanVersion) {
        throw "Project version write did not persist. Expected $cleanVersion, got $savedVersion."
    }

    Write-Host "PROJECT_VERSION_SET version=$cleanVersion"
}

function Invoke-SelfTest {
    $valid = @("0.1", "1.0", "9.9", "10.0")
    foreach ($version in $valid) {
        if (-not (Test-ProjectVersion $version)) {
            throw "Expected $version to be valid."
        }
    }

    $invalid = @("1.10", "v1.0", "abc", "00.5", "01.2", "1.09", "-1.0", "1")
    foreach ($version in $invalid) {
        if (Test-ProjectVersion $version) {
            throw "Expected $version to be invalid."
        }
    }

    if ((Get-NextMinorVersion "0.8") -ne "0.9") {
        throw "Expected 0.8 to bump to 0.9."
    }
    if ((Get-NextMinorVersion "0.9") -ne "1.0") {
        throw "Expected 0.9 to bump to 1.0."
    }
    if ((Get-NextMinorVersion "1.9") -ne "2.0") {
        throw "Expected 1.9 to bump to 2.0."
    }

    Write-Host "PROJECT_VERSION_SELF_TEST_PASS"
}

$operationCount = 0
if ($Print) { $operationCount += 1 }
if (-not [string]::IsNullOrWhiteSpace($Set)) { $operationCount += 1 }
if ($BumpMinor) { $operationCount += 1 }
if ($SelfTest) { $operationCount += 1 }
if ($operationCount -ne 1) {
    throw "Usage: project_version.ps1 -Print | -Set MAJOR.MINOR | -BumpMinor | -SelfTest"
}

if ($Print) {
    Write-Host "PROJECT_VERSION version=$(Read-ProjectVersion)"
    exit 0
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if ($BumpMinor) {
    Set-ProjectVersion (Get-NextMinorVersion (Read-ProjectVersion))
    exit 0
}

Set-ProjectVersion $Set
