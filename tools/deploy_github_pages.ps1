param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [string]$Remote = "origin",
    [string]$Branch = "gh-pages",
    [string]$CommitMessage = "deploy: update github pages build",
    [string]$WorldKeys = "all",
    [switch]$SkipClient,
    [switch]$Release,
    [switch]$SkipExport,
    [switch]$SkipPush,
    [switch]$KeepWorktree
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$BuildRoot = Join-Path $ProjectRoot "builds"
$WebRoot = Join-Path $BuildRoot "web"
$WebWorldPackRoot = Join-Path $WebRoot "world_packs"
$DeployRoot = Join-Path $ProjectRoot ".deploy\github_pages"
$ProjectFile = Join-Path $ProjectRoot "project.godot"
$exportMode = if ($Release) { "--export-release" } else { "--export-debug" }

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

function Get-WorldKeys {
    $worldRoot = Join-Path $ProjectRoot "server\worlds"
    $keys = @()
    foreach ($directory in Get-ChildItem -Path $worldRoot -Directory | Sort-Object Name) {
        $scenePath = Join-Path $directory.FullName "$($directory.Name).tscn"
        if (-not (Test-Path -LiteralPath $scenePath)) {
            throw "World folder '$($directory.Name)' must contain $($directory.Name).tscn"
        }
        $keys += $directory.Name
    }
    return $keys
}

function Get-RequestedWorldKeys($availableKeys) {
    if ($WorldKeys -eq "all") {
        return $availableKeys
    }
    if ($WorldKeys -eq "none") {
        return @()
    }

    $requestedKeys = @(
        $WorldKeys.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries) |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    foreach ($worldKey in $requestedKeys) {
        if (-not ($availableKeys -contains $worldKey)) {
            throw "Unknown world '$worldKey'. Valid worlds: $($availableKeys -join ', ')"
        }
    }
    return $requestedKeys
}

function Wait-FileStable($path, $timeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $lastLength = -1
    $stableChecks = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path
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

function Remove-EditorAutoloadForExport {
    $content = Get-Content -LiteralPath $ProjectFile
    $filtered = $content | Where-Object { $_ -notmatch '^RunInstanceGrid=' }
    Set-Content -LiteralPath $ProjectFile -Value $filtered
}

function Export-WebClient {
    New-Item -ItemType Directory -Force -Path $WebRoot | Out-Null
    $output = Join-Path $WebRoot "index.html"
    $pckOutput = Join-Path $WebRoot "index.pck"
    Remove-Item -Force -Path $output, $pckOutput -ErrorAction SilentlyContinue

    Write-Host "GITHUB_PAGES_EXPORT_WEB_CLIENT_START path=$output"
    $originalProjectFile = Get-Content -LiteralPath $ProjectFile -Raw
    try {
        Remove-EditorAutoloadForExport
        & $Godot --headless --path $ProjectRoot $exportMode "Web Client" $output
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($exitCode -ne 0) {
            throw "Web client export failed with exit code $exitCode"
        }
    }
    finally {
        Set-Content -LiteralPath $ProjectFile -Value $originalProjectFile -NoNewline
    }

    Wait-FileStable $output
    Wait-FileStable $pckOutput
    Write-Host "GITHUB_PAGES_EXPORT_WEB_CLIENT_DONE"
}

function Export-WebWorldPacks($requestedKeys) {
    if ($requestedKeys.Count -eq 0) {
        Write-Host "GITHUB_PAGES_EXPORT_WORLD_PACKS_SKIP"
        return
    }

    New-Item -ItemType Directory -Force -Path $WebWorldPackRoot | Out-Null
    $worldCsv = $requestedKeys -join ","
    Write-Host "GITHUB_PAGES_EXPORT_WORLD_PACKS_START worlds=$worldCsv"
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "export_world_packs.ps1") `
        -Godot $Godot `
        -OutputDir $WebWorldPackRoot `
        -PresetPrefix "Web World Pack - " `
        -WorldKeys $worldCsv
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Web world pack export failed with exit code $exitCode"
    }
    foreach ($worldKey in $requestedKeys) {
        Wait-FileStable (Join-Path $WebWorldPackRoot "$worldKey.pck")
    }
    Write-Host "GITHUB_PAGES_EXPORT_WORLD_PACKS_DONE"
}

function Prepare-DeployWorktree {
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

    New-Item -ItemType File -Force -Path (Join-Path $DeployRoot ".nojekyll") | Out-Null
}

function Copy-WebClientToDeploy {
    $requiredFiles = @("index.html", "index.js", "index.pck", "index.wasm")
    foreach ($file in $requiredFiles) {
        $path = Join-Path $WebRoot $file
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Missing Web export artifact: $path"
        }
    }

    Get-ChildItem -LiteralPath $DeployRoot -Force |
        Where-Object { $_.Name -ne ".git" -and $_.Name -ne ".nojekyll" -and $_.Name -ne "world_packs" } |
        Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $WebRoot -Force |
        Where-Object { $_.Name -ne "world_packs" } |
        Copy-Item -Destination $DeployRoot -Recurse -Force
    Write-Host "GITHUB_PAGES_STAGE_WEB_CLIENT_DONE"
}

function Copy-WorldPacksToDeploy($requestedKeys, $availableKeys) {
    $deployWorldPackRoot = Join-Path $DeployRoot "world_packs"
    New-Item -ItemType Directory -Force -Path $deployWorldPackRoot | Out-Null

    foreach ($worldKey in $requestedKeys) {
        $source = Join-Path $WebWorldPackRoot "$worldKey.pck"
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Missing Web world pack for '$worldKey': $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $deployWorldPackRoot "$worldKey.pck") -Force
    }

    foreach ($pack in Get-ChildItem -LiteralPath $deployWorldPackRoot -File -Filter "*.pck" -ErrorAction SilentlyContinue) {
        $worldKey = [System.IO.Path]::GetFileNameWithoutExtension($pack.Name)
        if (-not ($availableKeys -contains $worldKey)) {
            Remove-Item -Force -LiteralPath $pack.FullName
            Write-Host "GITHUB_PAGES_REMOVED_DELETED_WORLD_PACK key=$worldKey"
        }
    }
    Write-Host "GITHUB_PAGES_STAGE_WORLD_PACKS_DONE worlds=$($requestedKeys -join ',')"
}

function Assert-FinalDeploySite($availableKeys) {
    foreach ($file in @("index.html", "index.js", "index.pck", "index.wasm")) {
        $path = Join-Path $DeployRoot $file
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Final GitHub Pages site is missing $file. Run with client deploy enabled."
        }
    }

    foreach ($worldKey in $availableKeys) {
        $path = Join-Path $DeployRoot "world_packs\$worldKey.pck"
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Final GitHub Pages site is missing world pack '$worldKey'. Run with -WorldKeys all."
        }
    }
}

function Commit-And-Push {
    Invoke-Git -arguments @("add", "-A") -workdir $DeployRoot

    & git -C $DeployRoot diff --cached --quiet
    $hasChanges = $LASTEXITCODE -ne 0
    if (-not $hasChanges) {
        Write-Host "GITHUB_PAGES_DEPLOY_NO_CHANGES"
        return
    }

    if ($SkipPush) {
        Write-Host "GITHUB_PAGES_DEPLOY_SKIP_PUSH branch=$Branch path=$DeployRoot changes_pending=true"
        return
    }

    Invoke-Git -arguments @("commit", "-m", $CommitMessage) -workdir $DeployRoot
    Invoke-Git -arguments @("push", $Remote, "$($Branch):$($Branch)") -workdir $DeployRoot
    Write-Host "GITHUB_PAGES_DEPLOY_PUSHED remote=$Remote branch=$Branch"
}

$availableWorldKeys = Get-WorldKeys
$requestedWorldKeys = Get-RequestedWorldKeys $availableWorldKeys

if (-not $SkipExport) {
    if (-not $SkipClient) {
        Export-WebClient
    }
    Export-WebWorldPacks $requestedWorldKeys
}

$verifyWorldKeys = if ($requestedWorldKeys.Count -eq 0) { "none" } else { $requestedWorldKeys -join "," }
$verifyArgs = @(
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "verify_export_artifacts.ps1"),
    "-WebOnly",
    "-WorldKeys", $verifyWorldKeys
)
if ($SkipClient) {
    $verifyArgs += "-SkipWebClient"
}
& powershell @verifyArgs
$verifyExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($verifyExitCode -ne 0) {
    throw "Web export verification failed with exit code $verifyExitCode"
}

Prepare-DeployWorktree
try {
    if (-not $SkipClient) {
        Copy-WebClientToDeploy
    }
    Copy-WorldPacksToDeploy $requestedWorldKeys $availableWorldKeys
    Assert-FinalDeploySite $availableWorldKeys
    Commit-And-Push
}
finally {
    if (-not $KeepWorktree) {
        Invoke-Git -arguments @("worktree", "remove", "--force", $DeployRoot)
    }
}

Write-Host "GITHUB_PAGES_DEPLOY_DONE url=https://shilo.github.io/multi-server-test/"
