param(
    [string]$Url = "https://virtucade.xyz/",
    [string]$MasterUrl = "wss://server.virtucade.xyz/",
    [string]$WorldUrlTemplate = "wss://server.virtucade.xyz/{world_key}",
    [int]$ClientCount = 8,
    [int]$TimeoutSeconds = 360,
    [int]$NavigationTimeoutSeconds = 180,
    [int]$LaunchDelayMilliseconds = 250,
    [string]$Label = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$PlaywrightRoot = Join-Path $env:TEMP "multi-server-test-playwright"
if ([string]::IsNullOrWhiteSpace($Label)) {
    $Label = "hosted-$ClientCount-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
}
$LogRoot = Join-Path $ProjectRoot ".logs\hosted_stress\$Label"

New-Item -ItemType Directory -Force -Path $PlaywrightRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
npm --prefix $PlaywrightRoot install playwright@1.61.0 --no-save --silent
Copy-Item -Force (Join-Path $PSScriptRoot "web_smoke.mjs") (Join-Path $PlaywrightRoot "web_smoke.mjs")

function Add-QueryValue([string]$baseUrl, [string]$key, [string]$value) {
    $separator = if ($baseUrl.Contains("?")) { "&" } else { "?" }
    return "$baseUrl$separator$key=$([uri]::EscapeDataString($value))"
}

$base = Add-QueryValue $Url "args" "smoke_test,force_packrat_world_packs"
$base = Add-QueryValue $base "master_url" $MasterUrl
$base = Add-QueryValue $base "world_url_template" $WorldUrlTemplate

Write-Host "HOSTED_STRESS_START clients=$ClientCount url=$Url logs=$LogRoot"
$jobs = @()
for ($i = 1; $i -le $ClientCount; $i++) {
    $clientUrl = Add-QueryValue $base "run" "$Label-client$i-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    $log = Join-Path $LogRoot "client$i.log"
    $jobs += Start-Job -ScriptBlock {
        param($root, $url, $index, $log, $timeoutSeconds, $navigationTimeoutSeconds)
        Set-Location $root
        node web_smoke.mjs `
            "--url=$url" `
            "--timeout_ms=$($timeoutSeconds * 1000)" `
            "--navigation_timeout_ms=$($navigationTimeoutSeconds * 1000)" *> $log
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        if ($exitCode -ne 0) {
            Add-Content -LiteralPath $log -Value "CLIENT_EXIT_FAILED index=$index exit=$exitCode"
            throw "client$index failed exit=$exitCode"
        }
    } -ArgumentList $PlaywrightRoot, $clientUrl, $i, $log, $TimeoutSeconds, $NavigationTimeoutSeconds
    Start-Sleep -Milliseconds $LaunchDelayMilliseconds
}

$failed = $false
foreach ($job in $jobs) {
    try {
        Receive-Job -Job $job -Wait -ErrorAction Stop | Out-Null
    }
    catch {
        $failed = $true
        Write-Host $_
    }
}
Remove-Job $jobs -Force

$patterns = "WEB_SMOKE_PASS|CLIENT_EXIT_FAILED|SMOKE_FAIL|WORLD_PACK_FAILED|Server Offline|Version Mismatch|WORLD_CONNECT_RETRY|MASTER_BOOTSTRAP_RETRY|portal use denied|TimeoutError|ERR_|failed exit|Fatal|error"
$passed = 0
foreach ($log in Get-ChildItem $LogRoot -Filter "*.log" | Sort-Object Name) {
    $text = Get-Content -LiteralPath $log.FullName -Raw
    if ($text.Contains("WEB_SMOKE_PASS")) {
        $passed += 1
    }

    Write-Host "==== $($log.BaseName) ===="
    $matches = Select-String -LiteralPath $log.FullName -Pattern $patterns -CaseSensitive:$false
    if ($matches) {
        $matches | Select-Object -First 24 | ForEach-Object { Write-Host $_.Line }
    }
    else {
        Write-Host "NO_SUMMARY_LINES"
    }
}

Write-Host "HOSTED_STRESS_RESULT passed=$passed failed=$($ClientCount - $passed) clients=$ClientCount logs=$LogRoot"
if ($failed -or $passed -ne $ClientCount) {
    throw "HOSTED_STRESS_FAIL clients=$ClientCount passed=$passed"
}
Write-Host "HOSTED_STRESS_PASS clients=$ClientCount"
