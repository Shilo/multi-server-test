param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ProjectFile = Join-Path $ProjectRoot "project.godot"
$VersionScript = Join-Path $PSScriptRoot "project_version.gd"
$originalProjectFile = Get-Content -LiteralPath $ProjectFile -Raw

function Invoke-ProjectVersion([string[]]$VersionArgs) {
    $commandArgs = @("--headless", "--path", $ProjectRoot, "--script", $VersionScript, "--") + $VersionArgs
    $output = & $Godot @commandArgs
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    return @{
        ExitCode = $exitCode
        Output = ($output -join "`n")
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

try {
    $selfTest = Invoke-ProjectVersion -VersionArgs @("--self-test")
    if ($selfTest.ExitCode -ne 0) {
        throw "Project version self-test failed: $($selfTest.Output)"
    }

    $set = Invoke-ProjectVersion -VersionArgs @("--set", "0.8")
    if ($set.ExitCode -ne 0) {
        throw "Setting 0.8 failed: $($set.Output)"
    }
    Assert-Version "0.8"

    $bump = Invoke-ProjectVersion -VersionArgs @("--bump-minor")
    if ($bump.ExitCode -ne 0) {
        throw "Bumping 0.8 failed: $($bump.Output)"
    }
    Assert-Version "0.9"

    Write-Host "PROJECT_VERSION_TEST_PASS"
}
finally {
    [System.IO.File]::WriteAllText($ProjectFile, $originalProjectFile, (New-Object System.Text.UTF8Encoding($false)))
}
