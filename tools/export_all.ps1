param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$BuildRoot = Join-Path $ProjectRoot "builds"
$ProjectFile = Join-Path $ProjectRoot "project.godot"

$targets = @(
    @{ Name = "client"; Preset = "Windows Client"; Path = "client\client.exe"; PckRequired = $true },
    @{ Name = "server"; Preset = "Windows Server"; Path = "server\server.exe"; PckRequired = $false }
)

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
Remove-Item -Recurse -Force -Path (Join-Path $BuildRoot "master_server"), (Join-Path $BuildRoot "world_server") -ErrorAction SilentlyContinue

function Remove-EditorAutoloadForExport() {
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

$originalProjectFile = Get-Content -LiteralPath $ProjectFile -Raw
try {
    Remove-EditorAutoloadForExport

    foreach ($target in $targets) {
        $output = Join-Path $BuildRoot $target.Path
        $pckOutput = [System.IO.Path]::ChangeExtension($output, ".pck")
        New-Item -ItemType Directory -Force -Path (Split-Path $output -Parent) | Out-Null
        Remove-Item -Force -Path $output, $pckOutput -ErrorAction SilentlyContinue

        Write-Host "EXPORT_START $($target.Name) $output"
        & $Godot --headless --path $ProjectRoot --export-debug $target.Preset $output
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($exitCode -ne 0) {
            throw "Export failed for $($target.Name) with exit code $exitCode"
        }

        Wait-FileStable $output
        if ($target.PckRequired) {
            Wait-FileStable $pckOutput
        }
        Write-Host "EXPORT_DONE $($target.Name)"
    }
}
finally {
    Set-Content -LiteralPath $ProjectFile -Value $originalProjectFile -NoNewline
}

Write-Host "EXPORT_ALL_DONE"
