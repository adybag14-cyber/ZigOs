[CmdletBinding()]
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$Optimize = 'ReleaseSmall',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $repoRoot '.toolchain-version') -Raw).Trim()
$zigExe = Join-Path $repoRoot ".toolchains\zig-canonical\zig-x86_64-windows-$version\zig.exe"

if ($Clean) {
    Remove-Item (Join-Path $repoRoot 'build') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $repoRoot 'zig-out') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $repoRoot '.zig-cache') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $repoRoot 'src\generated') -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $zigExe)) {
    & (Join-Path $PSScriptRoot 'bootstrap-toolchain.ps1')
}
if (-not (Get-Command nasm -ErrorAction SilentlyContinue)) {
    throw 'NASM is required and was not found in PATH.'
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python 3 is required and was not found in PATH.'
}

$actualVersion = (& $zigExe version).Trim()
if ($actualVersion -ne $version) {
    throw "Refusing to build with non-canonical Zig. Expected $version, got $actualVersion."
}

Push-Location $repoRoot
try {
    & $zigExe build "-Doptimize=$Optimize"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed with exit code $LASTEXITCODE"
    }

    & python scripts\verify-efi.py zig-out\EFI\BOOT\BOOTX64.EFI
    if ($LASTEXITCODE -ne 0) {
        throw "portable EFI verification failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

Write-Host "USB layout ready at: $(Join-Path $repoRoot 'zig-out')"
