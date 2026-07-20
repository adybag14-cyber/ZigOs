[CmdletBinding()]
param(
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')]
    [string]$Optimize = 'ReleaseSmall'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $root '.toolchain-version') -Raw).Trim()
$zig = Join-Path $root ".toolchains\zig-canonical\zig-x86_64-windows-$version\zig.exe"
$source = Join-Path $root 'src\legacy\i686'
$build = Join-Path $root 'build\legacy-i686'
$output = Join-Path $root 'zig-out\legacy\i686'
New-Item -ItemType Directory -Force -Path $build, $output | Out-Null

$object = Join-Path $build 'entry.o'
$elf = Join-Path $output 'ZIGOS386.ELF'
$binary = Join-Path $output 'ZIGOS386.BIN'

Write-Host '[1/5] Checking i686 source formatting'
& $zig fmt --check (Join-Path $source 'kernel.zig')
if ($LASTEXITCODE -ne 0) { throw 'i686 formatting check failed.' }

Write-Host '[2/5] Assembling ELF32 entry'
& nasm -f elf32 (Join-Path $source 'entry.asm') -o $object
if ($LASTEXITCODE -ne 0) { throw 'i686 entry assembly failed.' }

Write-Host '[3/5] Linking freestanding i686 ELF'
$args = @(
    'build-exe', (Join-Path $source 'kernel.zig'), $object,
    '-target', 'x86-freestanding-none', '-mcpu', 'i686',
    '-O', $Optimize, '-fno-entry', '-fstrip',
    '-fno-omit-frame-pointer', '-fno-stack-check', '-fno-stack-protector',
    '-T', (Join-Path $source 'linker.ld'), "-femit-bin=$elf"
)
& $zig @args
if ($LASTEXITCODE -ne 0) { throw 'i686 ELF link failed.' }

Write-Host '[4/5] Extracting raw kernel'
& $zig objcopy --output-target=binary $elf $binary
if ($LASTEXITCODE -ne 0) { throw 'i686 raw extraction failed.' }

Write-Host '[5/5] Verifying legacy contracts'
& (Join-Path $PSScriptRoot 'verify-legacy-i686.ps1') -ElfPath $elf -BinaryPath $binary
