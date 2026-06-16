param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ProjectFile = Join-Path $ProjectRoot "project.godot"
$VersionScript = Join-Path $PSScriptRoot "project_version.gd"
$LogRoot = Join-Path $ProjectRoot ".logs\project_version_test"
$originalProjectFile = Get-Content -LiteralPath $ProjectFile -Raw
$script:ProjectVersionInvokeIndex = 0

Remove-Item -Recurse -Force -Path $LogRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Invoke-ProjectVersion([string[]]$VersionArgs) {
    $script:ProjectVersionInvokeIndex += 1
    $label = $VersionArgs -join "_"
    $safeLabel = $label -replace '[^a-zA-Z0-9_.-]', '_'
    $out = Join-Path $LogRoot "$($script:ProjectVersionInvokeIndex)_$safeLabel.out.log"
    $err = Join-Path $LogRoot "$($script:ProjectVersionInvokeIndex)_$safeLabel.err.log"
    $commandArgs = @("--headless", "--path", $ProjectRoot, "--script", $VersionScript, "--") + $VersionArgs
    $process = Start-Process -FilePath $Godot -ArgumentList $commandArgs -WorkingDirectory $ProjectRoot -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
    $process.WaitForExit(30000) | Out-Null
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Project version command timed out: $($VersionArgs -join ' ')"
    }

    $outputParts = @()
    if (Test-Path $out) {
        $outputParts += Get-Content -LiteralPath $out -Raw
    }
    if (Test-Path $err) {
        $outputParts += Get-Content -LiteralPath $err -Raw
    }
    $exitCode = if ($null -eq $process.ExitCode) { 0 } else { $process.ExitCode }
    return @{
        ExitCode = $exitCode
        Output = ($outputParts -join "`n").Trim()
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
    $selfTest = Invoke-ProjectVersion -VersionArgs @("--self-test")
    Write-StepResult "self-test" $selfTest
    if ($selfTest.ExitCode -ne 0) {
        throw "Project version self-test failed: $($selfTest.Output)"
    }

    $expectedBump = Next-MinorVersion (Read-ProjectVersion)
    $bump = Invoke-ProjectVersion -VersionArgs @("--bump-minor")
    Write-StepResult "bump-minor" $bump
    if ($bump.ExitCode -ne 0) {
        throw "Bumping project version failed: $($bump.Output)"
    }
    Assert-Version $expectedBump

    [System.IO.File]::WriteAllText($ProjectFile, $originalProjectFile, (New-Object System.Text.UTF8Encoding($false)))

    $set = Invoke-ProjectVersion -VersionArgs @("--set", "0.8")
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
