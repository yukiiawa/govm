$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

trap {
    Write-Error "e2e.ps1 failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    throw
}

$rootDir = Join-Path $env:RUNNER_TEMP "govm-e2e-root"
if (Test-Path $rootDir) {
    Remove-Item -LiteralPath $rootDir -Recurse -Force
}

$exe = if ($IsWindows) { ".\zig-out\bin\govm.exe" } else { "./zig-out/bin/govm" }
$listOutput = & $exe --root $rootDir list --stable-only --tail 5
$listText = ($listOutput | Out-String).TrimEnd()
Write-Host $listText

$versions = @($listOutput | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object {
    ($_ -split "\s+")[0]
})

if ($versions.Count -lt 1) {
    throw "failed to resolve versions from list output"
}

$latestVersion = $versions[-1]
$oldestTailVersion = $versions[0]

& $exe install $latestVersion
& $exe use $latestVersion

$currentOutput = & $exe current
$currentText = ($currentOutput | Out-String).TrimEnd()
Write-Host $currentText
if ($currentText -notmatch [regex]::Escape($latestVersion)) {
    throw "current output did not include expected version"
}

$whichOutput = & $exe which
$whichText = ($whichOutput | Out-String).TrimEnd()
Write-Host $whichText
if ($whichText -notmatch [regex]::Escape($latestVersion)) {
    throw "which output did not include expected version"
}
if (($whichText -replace "\\", "/") -match [regex]::Escape("/current/")) {
    throw "which should point to the real SDK path, not current"
}

try {
    & $exe remove $latestVersion
    throw "remove should fail for the current version"
} catch {
    if ($_.Exception.Message -match "remove should fail for the current version") {
        throw
    }
}

if ($oldestTailVersion -ne $latestVersion) {
    & $exe install $oldestTailVersion
    & $exe remove $oldestTailVersion
}
