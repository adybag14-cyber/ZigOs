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
$buildDir = Join-Path $repoRoot 'build'
$outputDir = Join-Path $repoRoot 'zig-out\EFI\BOOT'
$asmObject = Join-Path $buildDir 'cpu.obj'
$efiImage = Join-Path $outputDir 'BOOTX64.EFI'

if ($Clean) {
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $repoRoot 'zig-out') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $repoRoot '.zig-cache') -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $zigExe)) {
    & (Join-Path $PSScriptRoot 'bootstrap-toolchain.ps1')
}
if (-not (Get-Command nasm -ErrorAction SilentlyContinue)) {
    throw 'NASM is required and was not found in PATH.'
}

$actualVersion = (& $zigExe version).Trim()
if ($actualVersion -ne $version) {
    throw "Refusing to build with non-canonical Zig. Expected $version, got $actualVersion."
}

New-Item -ItemType Directory -Force -Path $buildDir, $outputDir | Out-Null

Write-Host "[1/3] Assembling x86-64 hardware layer with NASM"
& nasm -f win64 (Join-Path $repoRoot 'src\arch\x86_64\cpu.asm') -o $asmObject
if ($LASTEXITCODE -ne 0) { throw "NASM failed with exit code $LASTEXITCODE" }

Write-Host "[2/3] Compiling UEFI image with canonical Zig $actualVersion"
$zigArgs = @(
    'build-exe',
    (Join-Path $repoRoot 'src\main.zig'),
    $asmObject,
    '-target', 'x86_64-uefi-msvc',
    '-O', $Optimize,
    '-fstrip',
    '-fno-stack-check',
    '-fno-stack-protector',
    "-femit-bin=$efiImage"
)
& $zigExe @zigArgs
if ($LASTEXITCODE -ne 0) { throw "Canonical Zig failed with exit code $LASTEXITCODE" }

Write-Host '[3/3] Verifying PE/COFF UEFI image'
& (Join-Path $PSScriptRoot 'verify-efi.ps1') -Path $efiImage

Write-Host "USB layout ready at: $(Join-Path $repoRoot 'zig-out')"
