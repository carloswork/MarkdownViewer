<#
.SYNOPSIS
  Builds the deployable web bundle with the strict release Content-Security-Policy.

.DESCRIPTION
  `web/index.html` ships the DEVELOPMENT CSP so that `flutter run -d chrome`
  works: the debug compiler (DDC) starts the app with an inline <script>, which a
  strict script-src blocks. Release (dart2js) emits a single external
  main.dart.js and needs no inline script, so it can run under a much tighter
  policy.

  This script performs the release build and then swaps the CSP block between the
  CSP:BEGIN / CSP:END markers for the strict policy, verifying the result.

  Always build with this script. A bare `flutter build web` produces a working
  bundle that still carries the looser development policy.

.PARAMETER BaseHref
  Base href for the deployment. GitHub Pages project sites need "/<repo>/".

.EXAMPLE
  .\tool\build_web.ps1
  .\tool\build_web.ps1 -BaseHref /
#>
param(
    [string]$BaseHref = '/MarkdownViewer/'
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot

try {
    # The strict policy. Differs from the development policy in web/index.html in
    # exactly two directives: no inline/eval script, and no localhost WebSockets.
    $releaseCsp = @'
  <!-- CSP:BEGIN -->
  <!-- Release policy, injected by tool/build_web.ps1. Every off-origin request is blocked. -->
  <!-- connect-src allows blob: so "Load from file" can read the picked file from
       the page's own blob URL. blob: is same-document and cannot address another
       origin, so no network egress is permitted. -->
  <meta http-equiv="Content-Security-Policy" content="
    default-src 'self';
    script-src 'self' 'wasm-unsafe-eval';
    style-src 'self' 'unsafe-inline';
    font-src 'self';
    img-src 'self' data: blob:;
    media-src 'self' data: blob:;
    connect-src 'self' blob:;
    worker-src 'self' blob:;
    child-src 'self' blob:;
    object-src 'none';
    base-uri 'self';
    form-action 'none';
  ">
  <!-- CSP:END -->
'@
    $releaseCsp = $releaseCsp -replace '\r\n?', "`n"

    Write-Host 'Building release web bundle...' -ForegroundColor Cyan
    # Windows PowerShell turns any native stderr output into a terminating error
    # while ErrorActionPreference is 'Stop', and `flutter build` writes advisory
    # notes to stderr. Relax it for the call and judge success by the exit code.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & flutter build web --release --no-web-resources-cdn --no-wasm-dry-run --base-href $BaseHref 2>&1 |
        ForEach-Object { Write-Host "  $_" }
    $buildExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    if ($buildExitCode -ne 0) { throw "flutter build web failed with exit code $buildExitCode" }

    $indexPath = Join-Path $projectRoot 'build\web\index.html'
    if (-not (Test-Path $indexPath)) { throw "Build output not found: $indexPath" }

    $html = Get-Content $indexPath -Raw

    # Swap the marked block. Fail loudly rather than deploying the dev policy.
    $pattern = '(?s)[ \t]*<!-- CSP:BEGIN -->.*?<!-- CSP:END -->\r?\n?'
    if ($html -notmatch $pattern) {
        throw 'CSP markers not found in build\web\index.html. Has web/index.html been edited? Expected <!-- CSP:BEGIN --> ... <!-- CSP:END -->.'
    }
    $html = [regex]::Replace($html, $pattern, ($releaseCsp -replace '\$', '$$$$'), 1)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
    [System.IO.File]::WriteAllText($indexPath, $html, $utf8NoBom)

    # Verify what actually landed on disk, not what we intended to write.
    $expectedBytes = $utf8NoBom.GetBytes($html)
    $actualBytes = [System.IO.File]::ReadAllBytes($indexPath)
    if ($actualBytes.Length -ge 3 -and
        $actualBytes[0] -eq 0xEF -and $actualBytes[1] -eq 0xBB -and $actualBytes[2] -eq 0xBF) {
        throw 'Release index.html unexpectedly contains a UTF-8 BOM (EF BB BF).'
    }
    if ($actualBytes.Length -ne $expectedBytes.Length) {
        throw "Release index.html byte length mismatch: expected $($expectedBytes.Length), actual $($actualBytes.Length)."
    }
    for ($byteOffset = 0; $byteOffset -lt $expectedBytes.Length; $byteOffset++) {
        if ($actualBytes[$byteOffset] -ne $expectedBytes[$byteOffset]) {
            throw ('Release index.html byte mismatch at offset {0}: expected 0x{1:X2}, actual 0x{2:X2}.' -f
                $byteOffset, $expectedBytes[$byteOffset], $actualBytes[$byteOffset])
        }
    }
    $result = $utf8NoBom.GetString($actualBytes)
    if (-not [string]::Equals($result, $html, [System.StringComparison]::Ordinal)) {
        throw 'Release index.html strict UTF-8 decode does not match the transformed HTML.'
    }
    # Match within a single directive only: [^;"] stops at the next directive and
    # at the end of the content attribute. Without that, script-src checks would
    # run on into style-src's entirely legitimate 'unsafe-inline'.
    # Note 'unsafe-eval' is quote-anchored so it does not match 'wasm-unsafe-eval'.
    $checks = @(
        @{ Name = 'strict script-src present'; Ok = $result -match "script-src 'self' 'wasm-unsafe-eval';" },
        @{ Name = "no 'unsafe-inline' script"; Ok = $result -notmatch "script-src[^;`"]*'unsafe-inline'" },
        @{ Name = "no 'unsafe-eval' script";   Ok = $result -notmatch "script-src[^;`"]*'unsafe-eval'" },
        @{ Name = 'no localhost connect-src';  Ok = $result -notmatch "connect-src[^;`"]*localhost" },
        @{ Name = 'no remote connect-src';     Ok = $result -notmatch "connect-src[^;`"]*(http|ws)s?://" },
        @{ Name = "connect-src self + blob";   Ok = $result -match "connect-src 'self' blob:;" },
        @{ Name = "font-src 'self'";           Ok = $result -match "font-src 'self';" },
        @{ Name = 'dev-only notes stripped';   Ok = $result -notmatch 'DDC' },
        @{ Name = 'base href applied';         Ok = $result -match ([regex]::Escape("<base href=`"$BaseHref`"")) }
    )

    $failed = $false
    foreach ($check in $checks) {
        if ($check.Ok) {
            Write-Host "  OK   $($check.Name)" -ForegroundColor Green
        } else {
            Write-Host "  FAIL $($check.Name)" -ForegroundColor Red
            $failed = $true
        }
    }
    if ($failed) { throw 'Release CSP verification failed. Do not deploy this build.' }

    # .nojekyll must survive into the output or GitHub Pages drops Flutter's
    # underscore-prefixed asset paths.
    if (-not (Test-Path (Join-Path $projectRoot 'build\web\.nojekyll'))) {
        throw 'build\web\.nojekyll is missing; GitHub Pages would 404 on assets.'
    }
    Write-Host '  OK   .nojekyll present' -ForegroundColor Green

    Write-Host ''
    Write-Host "Release bundle ready: build\web (base href $BaseHref)" -ForegroundColor Cyan
}
finally {
    Pop-Location
}
