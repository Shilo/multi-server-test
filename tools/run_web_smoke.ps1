param(
    [string]$Godot = "C:\Programming_Files\Godot\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64.exe",
    [string]$Edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    [int]$StaticPort = 19200,
    [int]$TimeoutSeconds = 180,
    [switch]$SkipExport
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$LogRoot = Join-Path $ProjectRoot ".logs\web_smoke"
$BuildRoot = Join-Path $ProjectRoot "builds"
$PlaywrightRoot = Join-Path $env:TEMP "multi-server-test-playwright"
$staticProcess = $null
$masterProcess = $null

function Wait-LogMarker($path, $marker, $timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        if ((Test-Path -LiteralPath $path) -and ((Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue) -match $marker)) {
            return
        }
    } while ((Get-Date) -lt $deadline)

    if (Test-Path -LiteralPath $path) {
        Get-Content -LiteralPath $path
    }
    throw "Timed out waiting for log marker '$marker' in $path"
}

try {
    if (-not $SkipExport) {
        powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "export_all.ps1") -Godot $Godot
        python (Join-Path $PSScriptRoot "verify_export_artifacts.py")
    }

    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
    Remove-Item -Force -Path (Join-Path $LogRoot "*.log") -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Force -Path $PlaywrightRoot | Out-Null
    npm --prefix $PlaywrightRoot install playwright@1.61.0 --no-save --silent

    $staticProcess = Start-Process `
        -FilePath "python" `
        -ArgumentList @("-m", "http.server", "$StaticPort", "--bind", "127.0.0.1", "--directory", (Join-Path $BuildRoot "web")) `
        -RedirectStandardOutput (Join-Path $LogRoot "static.out.log") `
        -RedirectStandardError (Join-Path $LogRoot "static.err.log") `
        -WindowStyle Hidden `
        -PassThru

    $env:MULTI_SERVER_WORLD_PACK_DIR = Join-Path $BuildRoot "web\world_packs"
    $env:MULTI_SERVER_WORLD_PACK_BASE_URL = "http://127.0.0.1:$StaticPort/world_packs"

    $masterProcess = Start-Process `
        -FilePath (Join-Path $BuildRoot "server\server.exe") `
        -ArgumentList @("--headless") `
        -RedirectStandardOutput (Join-Path $LogRoot "master.out.log") `
        -RedirectStandardError (Join-Path $LogRoot "master.err.log") `
        -WindowStyle Hidden `
        -PassThru

    Wait-LogMarker (Join-Path $LogRoot "master.out.log") "MASTER_READY" 30

    $webUrl = "http://127.0.0.1:$StaticPort/index.html?args=smoke_test,force_packrat_world_packs&server_host=localhost&server_scheme=ws&run=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
    $nodeScript = @'
const { chromium } = require("playwright");
const url = "__WEB_URL__";
const edgePath = "__EDGE_PATH__";
const timeoutMs = __TIMEOUT_MS__;

(async () => {
  const browser = await chromium.launch({ executablePath: edgePath, headless: true });
  const page = await browser.newPage({ viewport: { width: 1024, height: 768 } });
  const messages = [];

  page.on("console", (msg) => {
    const text = `[${msg.type()}] ${msg.text()}`;
    messages.push(text);
    console.log(text);
  });

  page.on("pageerror", (error) => {
    const text = `[pageerror] ${error.message}`;
    messages.push(text);
    console.log(text);
  });

  await page.goto(url, { waitUntil: "load", timeout: 60000 });
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    if (messages.some((message) => message.includes("SMOKE_PASS"))) {
      await browser.close();
      process.exit(0);
    }
    if (messages.some((message) => message.includes("SMOKE_FAIL") || message.includes("WORLD_PACK_FAILED"))) {
      await browser.close();
      process.exit(2);
    }
    await page.waitForTimeout(500);
  }

  console.error("WEB_SMOKE_TIMEOUT");
  await browser.close();
  process.exit(3);
})();
'@
    $nodeScript = $nodeScript.Replace("__WEB_URL__", $webUrl)
    $nodeScript = $nodeScript.Replace("__EDGE_PATH__", $Edge.Replace("\", "/"))
    $nodeScript = $nodeScript.Replace("__TIMEOUT_MS__", [string]($TimeoutSeconds * 1000))

    $scriptPath = Join-Path $LogRoot "web_smoke_runner.js"
    Set-Content -LiteralPath $scriptPath -Value $nodeScript
    $env:NODE_PATH = Join-Path $PlaywrightRoot "node_modules"
    node $scriptPath
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Web smoke failed with exit code $exitCode"
    }

    Write-Host "WEB_SMOKE_PASS logs=$LogRoot"
}
finally {
    if ($masterProcess -and -not $masterProcess.HasExited) {
        Stop-Process -Id $masterProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($staticProcess -and -not $staticProcess.HasExited) {
        Stop-Process -Id $staticProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $ports = @(19080, 19081, 19082, 19083, 19084, $StaticPort)
    Get-NetTCPConnection -LocalPort $ports -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -gt 0 } |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object {
            Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
        }
}
