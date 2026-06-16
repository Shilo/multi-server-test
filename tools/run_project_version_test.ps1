$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ProjectFile = Join-Path $ProjectRoot "project.godot"
$VersionScript = Join-Path $PSScriptRoot "project_version.ps1"
$LogRoot = Join-Path $ProjectRoot ".logs\project_version_test"
$originalProjectFile = Get-Content -LiteralPath $ProjectFile -Raw

Remove-Item -Recurse -Force -Path $LogRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Invoke-ProjectVersion([string[]]$VersionArgs) {
    $output = & powershell -ExecutionPolicy Bypass -File $VersionScript @VersionArgs 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    return @{
        ExitCode = $exitCode
        Output = ($output -join "`n").Trim()
    }
}

function Read-ProjectVersion {
    $content = Get-Content -LiteralPath $ProjectFile -Raw
    if ($content -notmatch 'config/version="([0-9]+\.[0-9])"') {
        throw "Could not read application/config/version from $ProjectFile"
    }
    return $Matches[1]
}

function Assert-Version($expected) {
    $deadline = (Get-Date).AddSeconds(5)
    $actual = Read-ProjectVersion
    while ($actual -ne $expected -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $actual = Read-ProjectVersion
    }
    if ($actual -ne $expected) {
        throw "Expected project version $expected, got $actual"
    }
}

function Next-MinorVersion($version) {
    if ($version -notmatch '^([0-9]+)\.([0-9])$') {
        throw "Cannot bump invalid project version in test: $version"
    }

    $major = [int]$Matches[1]
    $minor = [int]$Matches[2] + 1
    if ($minor -gt 9) {
        $major += 1
        $minor = 0
    }
    return "$major.$minor"
}

function Write-StepResult($label, $result) {
    Write-Host "PROJECT_VERSION_TEST_STEP $label exit=$($result.ExitCode) output=$($result.Output)"
    Write-Host "PROJECT_VERSION_TEST_FILE $label version=$(Read-ProjectVersion)"
}

try {
    $selfTest = Invoke-ProjectVersion -VersionArgs @("-SelfTest")
    Write-StepResult "self-test" $selfTest
    if ($selfTest.ExitCode -ne 0) {
        throw "Project version self-test failed: $($selfTest.Output)"
    }

    $expectedBump = Next-MinorVersion (Read-ProjectVersion)
    $bump = Invoke-ProjectVersion -VersionArgs @("-BumpMinor")
    Write-StepResult "bump-minor" $bump
    if ($bump.ExitCode -ne 0) {
        throw "Bumping project version failed: $($bump.Output)"
    }
    Assert-Version $expectedBump

    [System.IO.File]::WriteAllText($ProjectFile, $originalProjectFile, (New-Object System.Text.UTF8Encoding($false)))

    $set = Invoke-ProjectVersion -VersionArgs @("-Set", "0.8")
    Write-StepResult "set-0.8" $set
    if ($set.ExitCode -ne 0) {
        throw "Setting 0.8 failed: $($set.Output)"
    }
    Assert-Version "0.8"

    Write-Host "PROJECT_VERSION_TEST_PASS"
}
finally {
    [System.IO.File]::WriteAllText($ProjectFile, $originalProjectFile, (New-Object System.Text.UTF8Encoding($false)))
}
