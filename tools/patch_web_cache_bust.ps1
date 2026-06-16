param(
    [string]$WebRoot,
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$BuildInfoPath = Join-Path $ProjectRoot "shared\build\build_info.gd"

function Get-BuildInfoVersion {
    $content = Get-Content -LiteralPath $BuildInfoPath -Raw
    if ($content -match 'BUILD_VERSION\s*:=\s*"([^"]+)"') {
        return $Matches[1]
    }
    throw "Could not read BUILD_VERSION from $BuildInfoPath"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Get-BuildInfoVersion
}

$encodedVersion = [System.Uri]::EscapeDataString($Version.Trim())
if ([string]::IsNullOrWhiteSpace($encodedVersion)) {
    throw "Cannot patch Web cache busting with an empty version"
}

$resolvedWebRoot = Resolve-Path $WebRoot
$indexHtml = Join-Path $resolvedWebRoot "index.html"
$indexJs = Join-Path $resolvedWebRoot "index.js"
foreach ($path in @($indexHtml, $indexJs)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing Web export file: $path"
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$html = Get-Content -LiteralPath $indexHtml -Raw
$html = [regex]::Replace($html, 'src="index\.js(?:\?v=[^"]*)?"', "src=`"index.js?v=$encodedVersion`"")
if (-not $html.Contains("index.js?v=$encodedVersion")) {
    throw "Could not patch Web HTML script tag with build version $Version"
}
[System.IO.File]::WriteAllText($indexHtml, $html, $utf8NoBom)

$js = Get-Content -LiteralPath $indexJs -Raw
$cacheBustLine = "const GODOT_CACHE_BUST = `"?v=$encodedVersion`";"
if ($js -match 'const GODOT_CACHE_BUST = "[^"]*";') {
    $js = [regex]::Replace($js, 'const GODOT_CACHE_BUST = "[^"]*";', $cacheBustLine, 1)
}
else {
    $js = [regex]::Replace($js, '^var Godot=', "$cacheBustLine`nvar Godot=", 1)
}
if (-not $js.Contains($cacheBustLine)) {
    throw "Could not patch Web loader cache-bust constant"
}

$replacements = @{
    'return `${loadPath}.audio.worklet.js`;' = 'return `${loadPath}.audio.worklet.js${GODOT_CACHE_BUST}`;'
    'return `${loadPath}.audio.position.worklet.js`;' = 'return `${loadPath}.audio.position.worklet.js${GODOT_CACHE_BUST}`;'
    'return `${loadPath}.js`;' = 'return `${loadPath}.js${GODOT_CACHE_BUST}`;'
    'return `${loadPath}.side.wasm`;' = 'return `${loadPath}.side.wasm${GODOT_CACHE_BUST}`;'
    'return `${loadPath}.wasm`;' = 'return `${loadPath}.wasm${GODOT_CACHE_BUST}`;'
    'loadPromise = preloader.loadPromise(`${loadPath}.wasm`, size, true);' = 'loadPromise = preloader.loadPromise(`${loadPath}.wasm${GODOT_CACHE_BUST}`, size, true);'
    'this.preloadFile(pack, pack),' = 'this.preloadFile(packUrl, pack),'
}

foreach ($key in $replacements.Keys) {
    if (-not $js.Contains($key) -and -not $js.Contains($replacements[$key])) {
        throw "Could not patch expected Web loader fragment: $key"
    }
    $js = $js.Replace($key, $replacements[$key])
}

$packPattern = 'const pack = this\.config\.mainPack \|\| `\$\{exe\}\.pck`;(\r?\n\s*const packUrl = `\$\{pack\}\$\{GODOT_CACHE_BUST\}`;)*'
$packReplacement = 'const pack = this.config.mainPack || `${exe}.pck`;' + "`n`t`t`t`t" + 'const packUrl = `${pack}${GODOT_CACHE_BUST}`;'
if (-not [regex]::IsMatch($js, $packPattern)) {
    throw "Could not patch expected Web loader pack fragment"
}
$js = [regex]::Replace(
    $js,
    $packPattern,
    [System.Text.RegularExpressions.MatchEvaluator] { param($match) $packReplacement },
    1
)
foreach ($fragment in @(
    'return `${loadPath}.wasm${GODOT_CACHE_BUST}`;',
    'loadPromise = preloader.loadPromise(`${loadPath}.wasm${GODOT_CACHE_BUST}`, size, true);',
    'const packUrl = `${pack}${GODOT_CACHE_BUST}`;',
    'this.preloadFile(packUrl, pack),'
)) {
    if (-not $js.Contains($fragment)) {
        throw "Web loader cache-bust fragment is missing after patch: $fragment"
    }
}

[System.IO.File]::WriteAllText($indexJs, $js, $utf8NoBom)

$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    & $node.Source --check $indexJs
    $nodeExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($nodeExitCode -ne 0) {
        throw "Patched Web loader failed JavaScript syntax check with exit code $nodeExitCode"
    }
}

Write-Host "WEB_CACHE_BUST_PATCHED version=$Version root=$resolvedWebRoot"
