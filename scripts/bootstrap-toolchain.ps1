[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $repoRoot '.toolchain-version') -Raw).Trim()
$tag = 'upstream-5d08e47160ad'
$asset = "zig-x86_64-windows-$version.zip"
$expectedSha256 = 'e8019bd8762564a62ffc209a90a82541c0c22dbdebceeb9e1d21bf2c2def71ab'
$toolchainRoot = Join-Path $repoRoot '.toolchains\zig-canonical'
$installDir = Join-Path $toolchainRoot "zig-x86_64-windows-$version"
$zigExe = Join-Path $installDir 'zig.exe'

if (Test-Path $zigExe) {
    $actualVersion = (& $zigExe version).Trim()
    if ($actualVersion -ne $version) {
        throw "Canonical Zig version mismatch. Expected $version, got $actualVersion."
    }
    Write-Host "Canonical Zig already installed: $zigExe"
    exit 0
}

New-Item -ItemType Directory -Force -Path $toolchainRoot | Out-Null
$archive = Join-Path $toolchainRoot $asset
$url = "https://github.com/adybag14-cyber/zig/releases/download/$tag/$asset"

Write-Host "Downloading canonical Zig from $url"
Invoke-WebRequest -Uri $url -OutFile $archive

$actualSha256 = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $expectedSha256) {
    Remove-Item $archive -Force
    throw "Canonical Zig archive checksum mismatch. Expected $expectedSha256, got $actualSha256."
}

Expand-Archive -Path $archive -DestinationPath $toolchainRoot -Force
Remove-Item $archive -Force

if (-not (Test-Path $zigExe)) {
    throw "Canonical Zig extraction did not produce $zigExe"
}

$installedVersion = (& $zigExe version).Trim()
if ($installedVersion -ne $version) {
    throw "Canonical Zig version mismatch after extraction. Expected $version, got $installedVersion."
}

Write-Host "Installed canonical Zig $installedVersion"
