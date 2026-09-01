$ErrorActionPreference = "Stop"

$indexUrl = "https://ziglang.org/download/index.json"
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$zonPath = Join-Path $projectRoot "build.zig.zon"
$installRoot = Join-Path $env:RUNNER_TEMP "zig-setup"

if (Test-Path $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $installRoot | Out-Null

$index = Invoke-RestMethod -Uri $indexUrl
$zon = Get-Content -LiteralPath $zonPath -Raw
$versionMatch = [regex]::Match($zon, '\.minimum_zig_version\s*=\s*"([^"]+)"')
if (-not $versionMatch.Success) {
    throw "Failed to read '.minimum_zig_version' from $zonPath"
}

$zigVersion = $versionMatch.Groups[1].Value
$versionParts = $zigVersion -split '\.'
if ($versionParts.Count -lt 2) {
    throw "Unsupported Zig version format '$zigVersion'"
}
$versionLine = "$($versionParts[0]).$($versionParts[1])"

# Prefer the stable release for the same major/minor line. Only use a
# development build from that same line when no stable release is available.
$stableVersion = "$versionLine.0"
$versionEntryProperty = $index.PSObject.Properties[$stableVersion]
$resolvedVersion = $stableVersion

if ($null -eq $versionEntryProperty) {
    $devCandidates = @(
        $index.PSObject.Properties |
            Where-Object {
                $_.Name -match "^$([regex]::Escape($versionLine))\.\d+-dev\."
            } |
            Sort-Object { [datetime]$_.Value.date } -Descending
    )
    if ($devCandidates.Count -eq 0) {
        throw "No official Zig stable or development download entry for version line '$versionLine'"
    }
    $versionEntryProperty = $devCandidates[0]
    $resolvedVersion = $versionEntryProperty.Name
}

$versionEntry = $versionEntryProperty.Value

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
$entry = $versionEntry.$key
if ($null -eq $entry) {
    throw "No official Zig download entry for version '$resolvedVersion' and target '$key'"
}

$tarballUrl = $entry.tarball
if ([string]::IsNullOrWhiteSpace($tarballUrl)) {
    throw "Official Zig entry '$key' does not contain a tarball URL"
}

$archiveName = Split-Path -Leaf $tarballUrl
$archivePath = Join-Path $installRoot $archiveName
$extractDir = Join-Path $installRoot "extract"

Write-Host "Requested Zig $zigVersion; downloading Zig $resolvedVersion from official source: $tarballUrl"
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
