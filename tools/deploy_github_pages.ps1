param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [string]$Remote = "origin",
    [string]$Branch = "gh-pages",
    [string]$CommitMessage = "deploy: update github pages build",
    [switch]$Release,
    [switch]$SkipExport,
    [switch]$SkipPush,
    [switch]$KeepWorktree
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$BuildRoot = Join-Path $ProjectRoot "builds"
$WebRoot = Join-Path $BuildRoot "web"
$DeployRoot = Join-Path $ProjectRoot ".deploy\github_pages"

function Invoke-Git($arguments, $workdir = $ProjectRoot) {
    & git -C $workdir @arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "git $($arguments -join ' ') failed with exit code $exitCode"
    }
}

function Assert-DeployRootSafe {
    $deployParent = Join-Path $ProjectRoot ".deploy"
    $resolvedParent = [System.IO.Path]::GetFullPath($deployParent)
    $resolvedDeploy = [System.IO.Path]::GetFullPath($DeployRoot)
    if (-not $resolvedDeploy.StartsWith($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean deploy path outside .deploy: $DeployRoot"
    }
}

function Assert-WebArtifacts {
    $requiredFiles = @(
        "index.html",
        "index.js",
        "index.pck",
        "index.wasm"
    )
    foreach ($file in $requiredFiles) {
        $path = Join-Path $WebRoot $file
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Missing Web export artifact: $path"
        }
    }

    $worldPackRoot = Join-Path $WebRoot "world_packs"
    if (-not (Test-Path -LiteralPath $worldPackRoot)) {
        throw "Missing Web world pack folder: $worldPackRoot"
    }

    $worldPacks = @(Get-ChildItem -LiteralPath $worldPackRoot -File -Filter "*.pck")
    if ($worldPacks.Count -eq 0) {
        throw "No Web world packs found in $worldPackRoot"
    }
}

function Copy-WebArtifacts {
    Assert-DeployRootSafe
    if (Test-Path -LiteralPath $DeployRoot) {
        Invoke-Git -arguments @("worktree", "remove", "--force", $DeployRoot)
    }

    $remoteRef = (& git -C $ProjectRoot ls-remote --heads $Remote $Branch)
    $remoteExists = -not [string]::IsNullOrWhiteSpace($remoteRef)
    & git -C $ProjectRoot show-ref --verify --quiet "refs/heads/$Branch"
    $localExists = $LASTEXITCODE -eq 0
    if ($remoteExists) {
        Invoke-Git -arguments @("fetch", $Remote, $Branch)
        Invoke-Git -arguments @("worktree", "add", "-B", $Branch, $DeployRoot, "$Remote/$Branch")
    }
    elseif ($localExists) {
        Invoke-Git -arguments @("worktree", "add", $DeployRoot, $Branch)
    }
    else {
        Invoke-Git -arguments @("worktree", "add", "--detach", $DeployRoot, "HEAD")
        Invoke-Git -arguments @("checkout", "--orphan", $Branch) -workdir $DeployRoot
    }

    Get-ChildItem -LiteralPath $DeployRoot -Force |
        Where-Object { $_.Name -ne ".git" } |
        Remove-Item -Recurse -Force

    Get-ChildItem -LiteralPath $WebRoot -Force |
        Copy-Item -Destination $DeployRoot -Recurse -Force
    New-Item -ItemType File -Force -Path (Join-Path $DeployRoot ".nojekyll") | Out-Null
}

function Commit-And-Push {
    Invoke-Git -arguments @("add", "-A") -workdir $DeployRoot

    & git -C $DeployRoot diff --cached --quiet
    $hasChanges = $LASTEXITCODE -ne 0
    if (-not $hasChanges) {
        Write-Host "GITHUB_PAGES_DEPLOY_NO_CHANGES"
        return
    }

    Invoke-Git -arguments @("commit", "-m", $CommitMessage) -workdir $DeployRoot
    if ($SkipPush) {
        Write-Host "GITHUB_PAGES_DEPLOY_SKIP_PUSH branch=$Branch path=$DeployRoot"
        return
    }

    Invoke-Git -arguments @("push", $Remote, "$($Branch):$($Branch)") -workdir $DeployRoot
    Write-Host "GITHUB_PAGES_DEPLOY_PUSHED remote=$Remote branch=$Branch"
}

if (-not $SkipExport) {
    $exportArgs = @(
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "export_all.ps1"),
        "-Godot", $Godot
    )
    if ($Release) {
        $exportArgs += "-Release"
    }
    & powershell @exportArgs
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Export failed with exit code $exitCode"
    }
}

& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "verify_export_artifacts.ps1")
$verifyExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($verifyExitCode -ne 0) {
    throw "Export verification failed with exit code $verifyExitCode"
}

Assert-WebArtifacts
Copy-WebArtifacts
try {
    Commit-And-Push
}
finally {
    if (-not $KeepWorktree) {
        Invoke-Git -arguments @("worktree", "remove", "--force", $DeployRoot)
    }
}

Write-Host "GITHUB_PAGES_DEPLOY_DONE url=https://shilo.github.io/multi-server-test/"
