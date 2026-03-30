$ErrorActionPreference = "Stop"

$indexUrl = "https://ziglang.org/download/index.json"
$installRoot = Join-Path $env:RUNNER_TEMP "zig-setup"

if (Test-Path $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $installRoot | Out-Null

$index = Invoke-RestMethod -Uri $indexUrl
$master = $index.master
if ($null -eq $master) {
    throw "Failed to resolve 'master' from official Zig index"
}

$zigOs = switch ($env:RUNNER_OS) {
    "Windows" { "windows" }
    "Linux" { "linux" }
    "macOS" { "macos" }
    default { throw "Unsupported RUNNER_OS: $($env:RUNNER_OS)" }
}

$zigArch = switch ($env:RUNNER_ARCH) {
    "X64" { "x86_64" }
    "ARM64" { "aarch64" }
    "X86" { "x86" }
    default { throw "Unsupported RUNNER_ARCH: $($env:RUNNER_ARCH)" }
}

$key = "$zigArch-$zigOs"
$entry = $master.$key
if ($null -eq $entry) {
    throw "No official Zig download entry for '$key'"
}

$tarballUrl = $entry.tarball
if ([string]::IsNullOrWhiteSpace($tarballUrl)) {
    throw "Official Zig entry '$key' does not contain a tarball URL"
}

$archiveName = Split-Path -Leaf $tarballUrl
$archivePath = Join-Path $installRoot $archiveName
$extractDir = Join-Path $installRoot "extract"

Write-Host "Downloading Zig from official source: $tarballUrl"
Invoke-WebRequest -Uri $tarballUrl -OutFile $archivePath

New-Item -ItemType Directory -Path $extractDir | Out-Null

if ($archivePath.EndsWith(".zip")) {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir
} else {
    tar -xf $archivePath -C $extractDir
}

$zigDir = Get-ChildItem -LiteralPath $extractDir -Directory | Select-Object -First 1
if ($null -eq $zigDir) {
    throw "Failed to locate extracted Zig directory"
}

$zigPath = $zigDir.FullName
$zigExe = if ($env:RUNNER_OS -eq "Windows") { Join-Path $zigPath "zig.exe" } else { Join-Path $zigPath "zig" }

Add-Content -LiteralPath $env:GITHUB_PATH -Value $zigPath
Write-Host "Installed Zig at $zigPath"
& $zigExe version
