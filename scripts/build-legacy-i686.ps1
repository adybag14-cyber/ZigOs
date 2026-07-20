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
$bootSector = Join-Path $output 'BOOTSECT.BIN'
$stage1 = Join-Path $output 'STAGE1.BIN'
$diskImage = Join-Path $output 'ZIGOS386.IMG'

Write-Host '[1/9] Checking i686 source formatting'
& $zig fmt --check (Join-Path $source 'kernel.zig')
if ($LASTEXITCODE -ne 0) { throw 'i686 formatting check failed.' }

Write-Host '[2/9] Assembling ELF32 entry'
& nasm -f elf32 (Join-Path $source 'entry.asm') -o $object
if ($LASTEXITCODE -ne 0) { throw 'i686 entry assembly failed.' }

Write-Host '[3/9] Linking freestanding i686 ELF'
$args = @(
    'build-exe', (Join-Path $source 'kernel.zig'), $object,
    '-target', 'x86-freestanding-none', '-mcpu', 'i686',
    '-O', $Optimize, '-fno-entry', '-fstrip',
    '-fno-omit-frame-pointer', '-fno-stack-check', '-fno-stack-protector',
    '-T', (Join-Path $source 'linker.ld'), "-femit-bin=$elf"
)
& $zig @args
if ($LASTEXITCODE -ne 0) { throw 'i686 ELF link failed.' }

Write-Host '[4/9] Extracting raw kernel'
& $zig objcopy --output-target=binary $elf $binary
if ($LASTEXITCODE -ne 0) { throw 'i686 raw extraction failed.' }

Write-Host '[5/9] Verifying legacy kernel contracts'
& (Join-Path $PSScriptRoot 'verify-legacy-i686.ps1') -ElfPath $elf -BinaryPath $binary
$kernelBytes = [IO.File]::ReadAllBytes($binary)
$kernelSectors = [int][Math]::Ceiling($kernelBytes.Length / 512.0)
if ($kernelSectors -lt 1 -or $kernelSectors -gt 127) { throw "Kernel sector count is outside 1..127: $kernelSectors" }

Write-Host "[6/9] Assembling the 8-sector stage1 for $kernelSectors kernel sector(s)"
& nasm -f bin "-DKERNEL_SECTORS=$kernelSectors" (Join-Path $source 'stage1.asm') -o $stage1
if ($LASTEXITCODE -ne 0) { throw 'BIOS stage1 assembly failed.' }

Write-Host '[7/9] Assembling the 512-byte BIOS stage0'
& nasm -f bin (Join-Path $source 'boot_sector.asm') -o $bootSector
if ($LASTEXITCODE -ne 0) { throw 'BIOS boot-sector assembly failed.' }

Write-Host '[8/9] Creating stage0/stage1/kernel disk layout'
$imageBytes = New-Object byte[] (1024 * 1024)
$bootBytes = [IO.File]::ReadAllBytes($bootSector)
$stage1Bytes = [IO.File]::ReadAllBytes($stage1)
[Array]::Copy($bootBytes, 0, $imageBytes, 0, $bootBytes.Length)
[Array]::Copy($stage1Bytes, 0, $imageBytes, 512, $stage1Bytes.Length)
[Array]::Copy($kernelBytes, 0, $imageBytes, 9 * 512, $kernelBytes.Length)
[IO.File]::WriteAllBytes($diskImage, $imageBytes)

Write-Host '[9/9] Verifying complete legacy BIOS image'
& (Join-Path $PSScriptRoot 'verify-legacy-bios.ps1') -BootSectorPath $bootSector -Stage1Path $stage1 -KernelPath $binary -DiskImagePath $diskImage
